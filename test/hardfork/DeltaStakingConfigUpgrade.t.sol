// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DeltaHardforkBase } from "./DeltaHardforkBase.t.sol";
import { StakingConfig } from "../../src/runtime/StakingConfig.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title DeltaStakingConfigUpgradeTest
/// @notice Tests for StakingConfig after Delta hardfork bytecode replacement.
///         Key concerns:
///         - Storage layout shifted: minimumProposalStake removed, _initialized moves to slot 2
///         - New 3-arg setForNextEpoch() works correctly (minimumProposalStake param removed)
///         - _initialized reads correctly from shifted slot
///         - hasPendingConfig reads correctly from shifted slot
///         - Validation (MAX_LOCKUP_DURATION, MAX_UNBONDING_DELAY) still works
contract DeltaStakingConfigUpgradeTest is DeltaHardforkBase {
    function setUp() public override {
        super.setUp();
        // Apply hardfork after initial state is established
        _applyDeltaHardfork();
    }

    // ========================================================================
    // STORAGE LAYOUT VERIFICATION (POST-SHIFT)
    // ========================================================================

    /// @notice Verify _initialized is true after bytecode replacement
    /// @dev In v1.2.0: _initialized was in slot 3.
    ///      In main: _initialized moved to slot 2 (reads old minimumProposalStake which was non-zero → true)
    function test_storageLayout_initializedAfterShift() public view {
        assertTrue(stakingConfig.isInitialized(), "isInitialized() should return true");
    }

    /// @notice Verify hasPendingConfig is false initially
    /// @dev In v1.2.0: hasPendingConfig was in slot 7.
    ///      In main: hasPendingConfig moved to slot 5 (reads old _pendingConfig packed field = 0 → false)
    function test_storageLayout_hasPendingConfigAfterShift() public view {
        assertFalse(stakingConfig.hasPendingConfig(), "hasPendingConfig() should return false");
    }

    /// @notice Verify existing config values are preserved after bytecode replacement
    /// @dev Slots 0 and 1 are unchanged between versions
    function test_storageLayout_existingValuesPreserved() public view {
        assertEq(stakingConfig.minimumStake(), MIN_STAKE, "minimumStake should be preserved");
        assertEq(stakingConfig.lockupDurationMicros(), LOCKUP_DURATION, "lockupDuration should be preserved");
        assertEq(stakingConfig.unbondingDelayMicros(), UNBONDING_DELAY, "unbondingDelay should be preserved");
    }

    /// @notice Verify minimumProposalStake getter no longer exists
    /// @dev Calling the old 4-arg selector should revert since function was removed
    function test_storageLayout_minimumProposalStakeRemoved() public {
        (bool ok,) = SystemAddresses.STAKE_CONFIG.staticcall(abi.encodeWithSignature("minimumProposalStake()"));
        assertFalse(ok, "minimumProposalStake() should not exist");
    }

    // ========================================================================
    // NEW 3-ARG PENDING CONFIG PATTERN
    // ========================================================================

    /// @notice Test the full pending config lifecycle with new 3-arg signature
    function test_pendingConfig_fullLifecycle() public {
        uint256 newMinStake = 5 ether;
        uint64 newLockup = 7 days * 1_000_000;
        uint64 newUnbonding = 3 days * 1_000_000;

        // Set pending config via GOVERNANCE (3-arg signature, no minimumProposalStake)
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(newMinStake, newLockup, newUnbonding);

        // Verify pending state
        assertTrue(stakingConfig.hasPendingConfig(), "hasPendingConfig should be true");
        (bool hasPending, StakingConfig.PendingConfig memory pending) = stakingConfig.getPendingConfig();
        assertTrue(hasPending, "getPendingConfig should indicate pending");
        assertEq(pending.minimumStake, newMinStake, "pending minimumStake");
        assertEq(pending.lockupDurationMicros, newLockup, "pending lockupDuration");
        assertEq(pending.unbondingDelayMicros, newUnbonding, "pending unbondingDelay");

        // Current values should NOT have changed yet
        assertEq(stakingConfig.minimumStake(), MIN_STAKE, "current minimumStake unchanged");

        // Apply via RECONFIGURATION (epoch boundary)
        vm.prank(SystemAddresses.RECONFIGURATION);
        stakingConfig.applyPendingConfig();

        // Now values should be updated
        assertEq(stakingConfig.minimumStake(), newMinStake, "new minimumStake applied");
        assertEq(stakingConfig.lockupDurationMicros(), newLockup, "new lockupDuration applied");
        assertEq(stakingConfig.unbondingDelayMicros(), newUnbonding, "new unbondingDelay applied");
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
        stakingConfig.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY);
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
        stakingConfig.setForNextEpoch(MIN_STAKE, tooLong, UNBONDING_DELAY);
    }

    /// @notice Test MAX_UNBONDING_DELAY validation
    function test_validation_excessiveUnbondingDelay() public {
        uint64 maxUnbonding = stakingConfig.MAX_UNBONDING_DELAY();
        uint64 tooLong = maxUnbonding + 1;

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExcessiveDuration.selector, tooLong, maxUnbonding));
        stakingConfig.setForNextEpoch(MIN_STAKE, LOCKUP_DURATION, tooLong);
    }

    /// @notice Test zero value validation
    function test_validation_zeroMinimumStake() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidMinimumStake.selector);
        stakingConfig.setForNextEpoch(0, LOCKUP_DURATION, UNBONDING_DELAY);
    }

    /// @notice Test zero lockup duration validation
    function test_validation_zeroLockupDuration() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidLockupDuration.selector);
        stakingConfig.setForNextEpoch(MIN_STAKE, 0, UNBONDING_DELAY);
    }

    /// @notice Test zero unbonding delay validation
    function test_validation_zeroUnbondingDelay() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidUnbondingDelay.selector);
        stakingConfig.setForNextEpoch(MIN_STAKE, LOCKUP_DURATION, 0);
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
        stakingConfig.setForNextEpoch(newMinStake, LOCKUP_DURATION, UNBONDING_DELAY);

        assertTrue(stakingConfig.hasPendingConfig(), "should have pending config");

        // Complete epoch transition (which calls applyPendingConfig via Reconfiguration)
        _completeEpochTransition();

        // Verify config was applied
        assertEq(stakingConfig.minimumStake(), newMinStake, "config should be applied after epoch");
        assertFalse(stakingConfig.hasPendingConfig(), "pending should be cleared");
    }
}
