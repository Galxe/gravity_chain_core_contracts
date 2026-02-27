// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { StakingConfig } from "../../../src/runtime/StakingConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title StakingConfigTest
/// @notice Unit tests for StakingConfig contract
contract StakingConfigTest is Test {
    StakingConfig public config;

    // Common test values (microseconds)
    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant LOCKUP_DURATION = 30 days * 1_000_000; // 30 days in microseconds
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000; // 7 days in microseconds
    uint256 constant MIN_PROPOSAL_STAKE = 10 ether;

    function setUp() public {
        config = new StakingConfig();
    }

    // ========================================================================
    // INITIAL STATE TESTS
    // ========================================================================

    function test_InitialState() public view {
        assertEq(config.minimumStake(), 0);
        assertEq(config.lockupDurationMicros(), 0);
        assertEq(config.unbondingDelayMicros(), 0);
        assertEq(config.minimumProposalStake(), 0);
        assertFalse(config.isInitialized());
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);

        assertEq(config.minimumStake(), MIN_STAKE);
        assertEq(config.lockupDurationMicros(), LOCKUP_DURATION);
        assertEq(config.unbondingDelayMicros(), UNBONDING_DELAY);
        assertEq(config.minimumProposalStake(), MIN_PROPOSAL_STAKE);
        assertTrue(config.isInitialized());
    }

    function test_RevertWhen_Initialize_ZeroMinimumStake() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidMinimumStake.selector);
        config.initialize(0, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_Initialize_ZeroMinimumProposalStake() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidMinimumProposalStake.selector);
        config.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 0);
    }

    function test_RevertWhen_Initialize_ZeroLockupDuration() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidLockupDuration.selector);
        config.initialize(MIN_STAKE, 0, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_Initialize_ZeroUnbondingDelay() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidUnbondingDelay.selector);
        config.initialize(MIN_STAKE, LOCKUP_DURATION, 0, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_Initialize_AlreadyInitialized() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        config.initialize(MIN_STAKE * 2, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_Initialize_NotGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        config.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    // ========================================================================
    // SET FOR NEXT EPOCH TESTS
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeConfig();

        uint256 newMinStake = 5 ether;
        uint64 newLockup = 60 days * 1_000_000;
        uint64 newUnbonding = 14 days * 1_000_000;
        uint256 newProposalStake = 20 ether;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newMinStake, newLockup, newUnbonding, newProposalStake);

        assertTrue(config.hasPendingConfig());

        // Active config should NOT change yet
        assertEq(config.minimumStake(), MIN_STAKE);
        assertEq(config.lockupDurationMicros(), LOCKUP_DURATION);
        assertEq(config.unbondingDelayMicros(), UNBONDING_DELAY);
        assertEq(config.minimumProposalStake(), MIN_PROPOSAL_STAKE);

        // Pending config should be set
        (bool hasPending, StakingConfig.PendingConfig memory pending) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pending.minimumStake, newMinStake);
        assertEq(pending.lockupDurationMicros, newLockup);
        assertEq(pending.unbondingDelayMicros, newUnbonding);
        assertEq(pending.minimumProposalStake, newProposalStake);
    }

    function test_RevertWhen_SetForNextEpoch_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.StakingConfigNotInitialized.selector);
        config.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_SetForNextEpoch_ZeroMinimumStake() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidMinimumStake.selector);
        config.setForNextEpoch(0, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_SetForNextEpoch_ZeroLockupDuration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidLockupDuration.selector);
        config.setForNextEpoch(MIN_STAKE, 0, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_SetForNextEpoch_ZeroUnbondingDelay() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidUnbondingDelay.selector);
        config.setForNextEpoch(MIN_STAKE, LOCKUP_DURATION, 0, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_SetForNextEpoch_ZeroMinimumProposalStake() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidMinimumProposalStake.selector);
        config.setForNextEpoch(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 0);
    }

    function test_Event_SetForNextEpoch() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, false);
        emit StakingConfig.PendingStakingConfigSet();
        config.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeConfig();

        uint256 newMinStake = 5 ether;
        uint64 newLockup = 60 days * 1_000_000;
        uint64 newUnbonding = 14 days * 1_000_000;
        uint256 newProposalStake = 20 ether;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newMinStake, newLockup, newUnbonding, newProposalStake);

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        // Active config should now be updated
        assertEq(config.minimumStake(), newMinStake);
        assertEq(config.lockupDurationMicros(), newLockup);
        assertEq(config.unbondingDelayMicros(), newUnbonding);
        assertEq(config.minimumProposalStake(), newProposalStake);
        assertFalse(config.hasPendingConfig());
    }

    function test_ApplyPendingConfig_NoPending() public {
        _initializeConfig();

        // Should be a no-op when no pending config
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        // Config should remain unchanged
        assertEq(config.minimumStake(), MIN_STAKE);
        assertEq(config.lockupDurationMicros(), LOCKUP_DURATION);
    }

    function test_RevertWhen_ApplyPendingConfig_NotReconfiguration() public {
        _initializeConfig();

        address notReconfig = address(0x1234);
        vm.prank(notReconfig);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notReconfig, SystemAddresses.RECONFIGURATION));
        config.applyPendingConfig();
    }

    function test_RevertWhen_ApplyPendingConfig_NotInitialized() public {
        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(Errors.StakingConfigNotInitialized.selector);
        config.applyPendingConfig();
    }

    function test_Event_ApplyPendingConfig() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, false);
        emit StakingConfig.StakingConfigUpdated();
        config.applyPendingConfig();
    }

    // ========================================================================
    // GET PENDING CONFIG TESTS
    // ========================================================================

    function test_GetPendingConfig_NoPending() public {
        _initializeConfig();

        (bool hasPending, StakingConfig.PendingConfig memory pending) = config.getPendingConfig();
        assertFalse(hasPending);
        assertEq(pending.minimumStake, 0);
    }

    function test_RevertWhen_GetPendingConfig_NotInitialized() public {
        vm.expectRevert(Errors.StakingConfigNotInitialized.selector);
        config.getPendingConfig();
    }

    // ========================================================================
    // ACCESS CONTROL TESTS
    // ========================================================================

    function test_RevertWhen_SetForNextEpoch_CalledByGenesis() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GENESIS, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_SetForNextEpoch_CalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_SetForNextEpoch_CalledByReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.RECONFIGURATION, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(5 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Initialize(
        uint256 minStake,
        uint64 lockupDuration,
        uint64 unbondingDelay,
        uint256 minProposalStake
    ) public {
        vm.assume(minStake > 0);
        vm.assume(lockupDuration > 0 && lockupDuration <= config.MAX_LOCKUP_DURATION());
        vm.assume(unbondingDelay > 0 && unbondingDelay <= config.MAX_UNBONDING_DELAY());
        vm.assume(minProposalStake > 0);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(minStake, lockupDuration, unbondingDelay, minProposalStake);

        assertEq(config.minimumStake(), minStake);
        assertEq(config.lockupDurationMicros(), lockupDuration);
        assertEq(config.unbondingDelayMicros(), unbondingDelay);
        assertEq(config.minimumProposalStake(), minProposalStake);
    }

    function testFuzz_SetForNextEpoch(
        uint256 newMinStake,
        uint64 newLockup,
        uint64 newUnbonding,
        uint256 newProposalStake
    ) public {
        vm.assume(newMinStake > 0);
        vm.assume(newLockup > 0 && newLockup <= config.MAX_LOCKUP_DURATION());
        vm.assume(newUnbonding > 0 && newUnbonding <= config.MAX_UNBONDING_DELAY());
        vm.assume(newProposalStake > 0);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newMinStake, newLockup, newUnbonding, newProposalStake);

        assertTrue(config.hasPendingConfig());
        (bool hasPending, StakingConfig.PendingConfig memory pending) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pending.minimumStake, newMinStake);
        assertEq(pending.lockupDurationMicros, newLockup);
        assertEq(pending.unbondingDelayMicros, newUnbonding);
        assertEq(pending.minimumProposalStake, newProposalStake);
    }

    function test_RevertWhen_Initialize_ExcessiveLockupDuration() public {
        uint64 maxLockup = config.MAX_LOCKUP_DURATION();
        uint64 excessiveLockup = maxLockup + 1;
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExcessiveDuration.selector, excessiveLockup, maxLockup));
        config.initialize(MIN_STAKE, excessiveLockup, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }

    function test_RevertWhen_Initialize_ExcessiveUnbondingDelay() public {
        uint64 maxUnbonding = config.MAX_UNBONDING_DELAY();
        uint64 excessiveUnbonding = maxUnbonding + 1;
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExcessiveDuration.selector, excessiveUnbonding, maxUnbonding));
        config.initialize(MIN_STAKE, LOCKUP_DURATION, excessiveUnbonding, MIN_PROPOSAL_STAKE);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }
}
