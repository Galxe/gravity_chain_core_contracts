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
    }

    function test_Initialize_ZeroMinimumStake() public {
        // minimumStake can be 0
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(0, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);

        assertEq(config.minimumStake(), 0);
    }

    function test_Initialize_ZeroMinimumProposalStake() public {
        // minimumProposalStake can be 0
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 0);

        assertEq(config.minimumProposalStake(), 0);
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
    // SETTER TESTS - setMinimumStake
    // ========================================================================

    function test_SetMinimumStake() public {
        _initializeConfig();

        uint256 newMinStake = 5 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumStake(newMinStake);

        assertEq(config.minimumStake(), newMinStake);
    }

    function test_SetMinimumStake_ToZero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumStake(0);

        assertEq(config.minimumStake(), 0);
    }

    function test_RevertWhen_SetMinimumStake_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setMinimumStake(5 ether);
    }

    function test_Event_SetMinimumStake() public {
        _initializeConfig();

        uint256 newMinStake = 5 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit StakingConfig.ConfigUpdated("minimumStake", MIN_STAKE, newMinStake);
        config.setMinimumStake(newMinStake);
    }

    // ========================================================================
    // SETTER TESTS - setLockupDurationMicros
    // ========================================================================

    function test_SetLockupDurationMicros() public {
        _initializeConfig();

        uint64 newDuration = 60 days * 1_000_000; // 60 days in microseconds
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setLockupDurationMicros(newDuration);

        assertEq(config.lockupDurationMicros(), newDuration);
    }

    function test_RevertWhen_SetLockupDurationMicros_Zero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidLockupDuration.selector);
        config.setLockupDurationMicros(0);
    }

    function test_RevertWhen_SetLockupDurationMicros_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setLockupDurationMicros(60 days * 1_000_000);
    }

    function test_Event_SetLockupDurationMicros() public {
        _initializeConfig();

        uint64 newDuration = 60 days * 1_000_000;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit StakingConfig.ConfigUpdated("lockupDurationMicros", LOCKUP_DURATION, newDuration);
        config.setLockupDurationMicros(newDuration);
    }

    // ========================================================================
    // SETTER TESTS - setUnbondingDelayMicros
    // ========================================================================

    function test_SetUnbondingDelayMicros() public {
        _initializeConfig();

        uint64 newDelay = 14 days * 1_000_000; // 14 days in microseconds
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setUnbondingDelayMicros(newDelay);

        assertEq(config.unbondingDelayMicros(), newDelay);
    }

    function test_RevertWhen_SetUnbondingDelayMicros_Zero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidUnbondingDelay.selector);
        config.setUnbondingDelayMicros(0);
    }

    function test_RevertWhen_SetUnbondingDelayMicros_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setUnbondingDelayMicros(14 days * 1_000_000);
    }

    function test_Event_SetUnbondingDelayMicros() public {
        _initializeConfig();

        uint64 newDelay = 14 days * 1_000_000;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit StakingConfig.ConfigUpdated("unbondingDelayMicros", UNBONDING_DELAY, newDelay);
        config.setUnbondingDelayMicros(newDelay);
    }

    // ========================================================================
    // SETTER TESTS - setMinimumProposalStake
    // ========================================================================

    function test_SetMinimumProposalStake() public {
        _initializeConfig();

        uint256 newMinProposalStake = 20 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumProposalStake(newMinProposalStake);

        assertEq(config.minimumProposalStake(), newMinProposalStake);
    }

    function test_SetMinimumProposalStake_ToZero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumProposalStake(0);

        assertEq(config.minimumProposalStake(), 0);
    }

    function test_SetMinimumProposalStake_BelowMinimumStake() public {
        _initializeConfig();

        // Can set minimumProposalStake below minimumStake (governance decision)
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumProposalStake(MIN_STAKE / 2);

        assertEq(config.minimumProposalStake(), MIN_STAKE / 2);
    }

    function test_RevertWhen_SetMinimumProposalStake_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setMinimumProposalStake(20 ether);
    }

    function test_Event_SetMinimumProposalStake() public {
        _initializeConfig();

        uint256 newMinProposalStake = 20 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit StakingConfig.ConfigUpdated("minimumProposalStake", MIN_PROPOSAL_STAKE, newMinProposalStake);
        config.setMinimumProposalStake(newMinProposalStake);
    }

    // ========================================================================
    // ACCESS CONTROL TESTS
    // ========================================================================

    function test_RevertWhen_SetterCalledByGenesis() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GENESIS, SystemAddresses.GOVERNANCE)
        );
        config.setMinimumStake(5 ether);
    }

    function test_RevertWhen_SetterCalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setMinimumStake(5 ether);
    }

    function test_RevertWhen_SetterCalledByReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.RECONFIGURATION, SystemAddresses.GOVERNANCE)
        );
        config.setMinimumStake(5 ether);
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
        vm.assume(lockupDuration > 0);
        vm.assume(unbondingDelay > 0);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(minStake, lockupDuration, unbondingDelay, minProposalStake);

        assertEq(config.minimumStake(), minStake);
        assertEq(config.lockupDurationMicros(), lockupDuration);
        assertEq(config.unbondingDelayMicros(), unbondingDelay);
        assertEq(config.minimumProposalStake(), minProposalStake);
    }

    function testFuzz_SetMinimumStake(
        uint256 newValue
    ) public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumStake(newValue);

        assertEq(config.minimumStake(), newValue);
    }

    function testFuzz_SetLockupDurationMicros(
        uint64 newValue
    ) public {
        vm.assume(newValue > 0);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setLockupDurationMicros(newValue);

        assertEq(config.lockupDurationMicros(), newValue);
    }

    function testFuzz_SetUnbondingDelayMicros(
        uint64 newValue
    ) public {
        vm.assume(newValue > 0);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setUnbondingDelayMicros(newValue);

        assertEq(config.unbondingDelayMicros(), newValue);
    }

    function testFuzz_SetMinimumProposalStake(
        uint256 newValue
    ) public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumProposalStake(newValue);

        assertEq(config.minimumProposalStake(), newValue);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
    }
}

