// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { GammaHardforkBase } from "./GammaHardforkBase.t.sol";
import { StakingConfig } from "../../src/runtime/StakingConfig.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title StakingConfigUpgradeTest
/// @notice Tests for StakingConfig after Gamma hardfork bytecode replacement.
///         Key concerns:
///         - _initialized remains in slot 3 (storage compatibility)
///         - hasPendingConfig is initialized to false (slot 7)
///         - New pending config pattern (setForNextEpoch + applyPendingConfig) works
///         - MAX_LOCKUP_DURATION / MAX_UNBONDING_DELAY validation works
contract StakingConfigUpgradeTest is GammaHardforkBase {
    function setUp() public override {
        super.setUp();
        // Apply hardfork after initial state is established
        _applyGammaHardfork();
    }

    // ========================================================================
    // STORAGE LAYOUT VERIFICATION
    // ========================================================================

    /// @notice Verify _initialized is still in slot 3 after bytecode replacement
    function test_storageLayout_initializedInSlot3() public view {
        bytes32 slot3 = vm.load(SystemAddresses.STAKE_CONFIG, bytes32(uint256(3)));
        // _initialized is a bool at offset 0 in slot 3
        assertTrue(uint256(slot3) != 0, "_initialized should be true in slot 3");
        assertTrue(stakingConfig.isInitialized(), "isInitialized() should return true");
    }

    /// @notice Verify hasPendingConfig is false initially (slot 7)
    function test_storageLayout_hasPendingConfigSlot7() public view {
        bytes32 slot7 = vm.load(SystemAddresses.STAKE_CONFIG, bytes32(uint256(7)));
        assertEq(uint256(slot7), 0, "hasPendingConfig should be false (0) initially");
        assertFalse(stakingConfig.hasPendingConfig(), "hasPendingConfig() should return false");
    }

    /// @notice Verify existing config values are preserved after bytecode replacement
    function test_storageLayout_existingValuesPreserved() public view {
        assertEq(stakingConfig.minimumStake(), MIN_STAKE, "minimumStake should be preserved");
        assertEq(stakingConfig.lockupDurationMicros(), LOCKUP_DURATION, "lockupDuration should be preserved");
        assertEq(stakingConfig.unbondingDelayMicros(), UNBONDING_DELAY, "unbondingDelay should be preserved");
        assertEq(stakingConfig.minimumProposalStake(), MIN_PROPOSAL_STAKE, "minimumProposalStake should be preserved");
    }

    // ========================================================================
    // PENDING CONFIG PATTERN
    // ========================================================================

    /// @notice Test the full pending config lifecycle: set → apply at epoch boundary
    function test_pendingConfig_fullLifecycle() public {
        uint256 newMinStake = 5 ether;
        uint64 newLockup = 7 days * 1_000_000;
        uint64 newUnbonding = 3 days * 1_000_000;
        uint256 newProposalStake = 50 ether;

        // Set pending config via GOVERNANCE
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(newMinStake, newLockup, newUnbonding, newProposalStake);

        // Verify pending state
        assertTrue(stakingConfig.hasPendingConfig(), "hasPendingConfig should be true");
        (bool hasPending, StakingConfig.PendingConfig memory pending) = stakingConfig.getPendingConfig();
        assertTrue(hasPending, "getPendingConfig should indicate pending");
        assertEq(pending.minimumStake, newMinStake, "pending minimumStake");
        assertEq(pending.lockupDurationMicros, newLockup, "pending lockupDuration");

        // Current values should NOT have changed yet
        assertEq(stakingConfig.minimumStake(), MIN_STAKE, "current minimumStake unchanged");

        // Apply via RECONFIGURATION (epoch boundary)
        vm.prank(SystemAddresses.RECONFIGURATION);
        stakingConfig.applyPendingConfig();

        // Now values should be updated
        assertEq(stakingConfig.minimumStake(), newMinStake, "new minimumStake applied");
        assertEq(stakingConfig.lockupDurationMicros(), newLockup, "new lockupDuration applied");
        assertEq(stakingConfig.unbondingDelayMicros(), newUnbonding, "new unbondingDelay applied");
        assertEq(stakingConfig.minimumProposalStake(), newProposalStake, "new proposalStake applied");
        assertFalse(stakingConfig.hasPendingConfig(), "hasPendingConfig cleared");
    }

    /// @notice Test that applyPendingConfig is a no-op when there's no pending config
    function test_pendingConfig_noopWhenNoPending() public {
        uint256 stakeBefore = stakingConfig.minimumStake();

        vm.prank(SystemAddresses.RECONFIGURATION);
        stakingConfig.applyPendingConfig();

        assertEq(stakingConfig.minimumStake(), stakeBefore, "should be unchanged");
    }

    /// @notice Test that only GOVERNANCE can call setForNextEpoch
    function test_pendingConfig_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        stakingConfig.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, 50 ether);
    }

    /// @notice Test that only RECONFIGURATION can call applyPendingConfig
    function test_pendingConfig_onlyReconfiguration() public {
        vm.prank(alice);
        vm.expectRevert();
        stakingConfig.applyPendingConfig();
    }

    // ========================================================================
    // VALIDATION
    // ========================================================================

    /// @notice Test MAX_LOCKUP_DURATION validation
    function test_validation_excessiveLockupDuration() public {
        uint64 maxLockup = stakingConfig.MAX_LOCKUP_DURATION();
        uint64 tooLong = maxLockup + 1;

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExcessiveDuration.selector, tooLong, maxLockup));
        stakingConfig.setForNextEpoch(MIN_STAKE, tooLong, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    /// @notice Test MAX_UNBONDING_DELAY validation
    function test_validation_excessiveUnbondingDelay() public {
        uint64 maxUnbonding = stakingConfig.MAX_UNBONDING_DELAY();
        uint64 tooLong = maxUnbonding + 1;

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExcessiveDuration.selector, tooLong, maxUnbonding));
        stakingConfig.setForNextEpoch(MIN_STAKE, LOCKUP_DURATION, tooLong, MIN_PROPOSAL_STAKE);
    }

    /// @notice Test zero value validation
    function test_validation_zeroMinimumStake() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidMinimumStake.selector);
        stakingConfig.setForNextEpoch(0, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    /// @notice Test zero lockup duration validation
    function test_validation_zeroLockupDuration() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidLockupDuration.selector);
        stakingConfig.setForNextEpoch(MIN_STAKE, 0, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    /// @notice Test zero unbonding delay validation
    function test_validation_zeroUnbondingDelay() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidUnbondingDelay.selector);
        stakingConfig.setForNextEpoch(MIN_STAKE, LOCKUP_DURATION, 0, MIN_PROPOSAL_STAKE);
    }

    /// @notice Test zero proposal stake validation
    function test_validation_zeroProposalStake() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidMinimumProposalStake.selector);
        stakingConfig.setForNextEpoch(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 0);
    }

    // ========================================================================
    // INTEGRATION WITH EPOCH TRANSITION
    // ========================================================================

    /// @notice Test pending config applied during full epoch transition
    function test_epochTransition_appliesPendingConfig() public {
        // Setup running chain
        _setupRunningChainWith2Validators();

        // Queue a config change
        uint256 newMinStake = 5 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(newMinStake, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);

        assertTrue(stakingConfig.hasPendingConfig(), "should have pending config");

        // Complete epoch transition (which calls applyPendingConfig via Reconfiguration)
        _completeEpochTransition();

        // Verify config was applied
        assertEq(stakingConfig.minimumStake(), newMinStake, "config should be applied after epoch");
        assertFalse(stakingConfig.hasPendingConfig(), "pending should be cleared");
    }
}
