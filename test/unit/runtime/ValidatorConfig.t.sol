// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ValidatorConfig } from "../../../src/runtime/ValidatorConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title ValidatorConfigTest
/// @notice Unit tests for ValidatorConfig contract
contract ValidatorConfigTest is Test {
    ValidatorConfig public config;

    // Common test values (microseconds for time values)
    uint256 constant MIN_BOND = 100 ether;
    uint256 constant MAX_BOND = 1000 ether;
    uint64 constant UNBONDING_DELAY = 14 days * 1_000_000; // 14 days in microseconds
    bool constant ALLOW_CHANGES = true;
    uint64 constant VOTING_POWER_LIMIT = 10; // 10%
    uint256 constant MAX_VALIDATORS = 100;

    function setUp() public {
        config = new ValidatorConfig();
    }

    // ========================================================================
    // CONSTANTS TESTS
    // ========================================================================

    function test_Constants() public view {
        assertEq(config.MAX_VOTING_POWER_INCREASE_LIMIT(), 50);
        assertEq(config.MAX_VALIDATOR_SET_SIZE(), 65536);
    }

    // ========================================================================
    // INITIAL STATE TESTS
    // ========================================================================

    function test_InitialState() public view {
        assertEq(config.minimumBond(), 0);
        assertEq(config.maximumBond(), 0);
        assertEq(config.unbondingDelayMicros(), 0);
        assertEq(config.allowValidatorSetChange(), false);
        assertEq(config.votingPowerIncreaseLimitPct(), 0);
        assertEq(config.maxValidatorSetSize(), 0);
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);

        assertEq(config.minimumBond(), MIN_BOND);
        assertEq(config.maximumBond(), MAX_BOND);
        assertEq(config.unbondingDelayMicros(), UNBONDING_DELAY);
        assertEq(config.allowValidatorSetChange(), ALLOW_CHANGES);
        assertEq(config.votingPowerIncreaseLimitPct(), VOTING_POWER_LIMIT);
        assertEq(config.maxValidatorSetSize(), MAX_VALIDATORS);
    }

    function test_Initialize_MinEqualsMax() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MIN_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);

        assertEq(config.minimumBond(), MIN_BOND);
        assertEq(config.maximumBond(), MIN_BOND);
    }

    function test_Initialize_MaxVotingPowerLimit() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, 50, MAX_VALIDATORS);

        assertEq(config.votingPowerIncreaseLimitPct(), 50);
    }

    function test_Initialize_MaxValidatorSetSize() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, 65536);

        assertEq(config.maxValidatorSetSize(), 65536);
    }

    function test_RevertWhen_Initialize_ZeroMinimumBond() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidMinimumBond.selector);
        config.initialize(0, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }

    function test_RevertWhen_Initialize_MaxLessThanMin() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.MinimumBondExceedsMaximum.selector, MIN_BOND, MIN_BOND - 1));
        config.initialize(MIN_BOND, MIN_BOND - 1, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }

    function test_RevertWhen_Initialize_ZeroUnbondingDelay() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidUnbondingDelay.selector);
        config.initialize(MIN_BOND, MAX_BOND, 0, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }

    function test_RevertWhen_Initialize_ZeroVotingPowerLimit() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVotingPowerIncreaseLimit.selector, 0));
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, 0, MAX_VALIDATORS);
    }

    function test_RevertWhen_Initialize_VotingPowerLimitTooHigh() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVotingPowerIncreaseLimit.selector, 51));
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, 51, MAX_VALIDATORS);
    }

    function test_RevertWhen_Initialize_ZeroMaxValidatorSetSize() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidValidatorSetSize.selector, 0));
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, 0);
    }

    function test_RevertWhen_Initialize_MaxValidatorSetSizeTooHigh() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidValidatorSetSize.selector, 65537));
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, 65537);
    }

    function test_RevertWhen_Initialize_AlreadyInitialized() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }

    function test_RevertWhen_Initialize_NotGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }

    // ========================================================================
    // SETTER TESTS - setMinimumBond
    // ========================================================================

    function test_SetMinimumBond() public {
        _initializeConfig();

        uint256 newMinBond = 200 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumBond(newMinBond);

        assertEq(config.minimumBond(), newMinBond);
    }

    function test_SetMinimumBond_EqualToMax() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumBond(MAX_BOND);

        assertEq(config.minimumBond(), MAX_BOND);
    }

    function test_RevertWhen_SetMinimumBond_Zero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidMinimumBond.selector);
        config.setMinimumBond(0);
    }

    function test_RevertWhen_SetMinimumBond_ExceedsMax() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.MinimumBondExceedsMaximum.selector, MAX_BOND + 1, MAX_BOND));
        config.setMinimumBond(MAX_BOND + 1);
    }

    function test_RevertWhen_SetMinimumBond_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setMinimumBond(200 ether);
    }

    function test_Event_SetMinimumBond() public {
        _initializeConfig();

        uint256 newMinBond = 200 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit ValidatorConfig.ConfigUpdated("minimumBond", MIN_BOND, newMinBond);
        config.setMinimumBond(newMinBond);
    }

    // ========================================================================
    // SETTER TESTS - setMaximumBond
    // ========================================================================

    function test_SetMaximumBond() public {
        _initializeConfig();

        uint256 newMaxBond = 2000 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMaximumBond(newMaxBond);

        assertEq(config.maximumBond(), newMaxBond);
    }

    function test_SetMaximumBond_EqualToMin() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMaximumBond(MIN_BOND);

        assertEq(config.maximumBond(), MIN_BOND);
    }

    function test_RevertWhen_SetMaximumBond_LessThanMin() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.MinimumBondExceedsMaximum.selector, MIN_BOND, MIN_BOND - 1));
        config.setMaximumBond(MIN_BOND - 1);
    }

    function test_RevertWhen_SetMaximumBond_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setMaximumBond(2000 ether);
    }

    function test_Event_SetMaximumBond() public {
        _initializeConfig();

        uint256 newMaxBond = 2000 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit ValidatorConfig.ConfigUpdated("maximumBond", MAX_BOND, newMaxBond);
        config.setMaximumBond(newMaxBond);
    }

    // ========================================================================
    // SETTER TESTS - setUnbondingDelayMicros
    // ========================================================================

    function test_SetUnbondingDelayMicros() public {
        _initializeConfig();

        uint64 newDelay = 28 days * 1_000_000;
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
        config.setUnbondingDelayMicros(28 days * 1_000_000);
    }

    function test_Event_SetUnbondingDelayMicros() public {
        _initializeConfig();

        uint64 newDelay = 28 days * 1_000_000;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit ValidatorConfig.ConfigUpdated("unbondingDelayMicros", UNBONDING_DELAY, newDelay);
        config.setUnbondingDelayMicros(newDelay);
    }

    // ========================================================================
    // SETTER TESTS - setAllowValidatorSetChange
    // ========================================================================

    function test_SetAllowValidatorSetChange_ToFalse() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setAllowValidatorSetChange(false);

        assertEq(config.allowValidatorSetChange(), false);
    }

    function test_SetAllowValidatorSetChange_ToTrue() public {
        _initializeConfig();

        // First set to false
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setAllowValidatorSetChange(false);

        // Then set back to true
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setAllowValidatorSetChange(true);

        assertEq(config.allowValidatorSetChange(), true);
    }

    function test_RevertWhen_SetAllowValidatorSetChange_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setAllowValidatorSetChange(false);
    }

    function test_Event_SetAllowValidatorSetChange() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit ValidatorConfig.ValidatorSetChangeAllowedUpdated(true, false);
        config.setAllowValidatorSetChange(false);
    }

    // ========================================================================
    // SETTER TESTS - setVotingPowerIncreaseLimitPct
    // ========================================================================

    function test_SetVotingPowerIncreaseLimitPct() public {
        _initializeConfig();

        uint64 newLimit = 25;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setVotingPowerIncreaseLimitPct(newLimit);

        assertEq(config.votingPowerIncreaseLimitPct(), newLimit);
    }

    function test_SetVotingPowerIncreaseLimitPct_Min() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setVotingPowerIncreaseLimitPct(1);

        assertEq(config.votingPowerIncreaseLimitPct(), 1);
    }

    function test_SetVotingPowerIncreaseLimitPct_Max() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setVotingPowerIncreaseLimitPct(50);

        assertEq(config.votingPowerIncreaseLimitPct(), 50);
    }

    function test_RevertWhen_SetVotingPowerIncreaseLimitPct_Zero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVotingPowerIncreaseLimit.selector, 0));
        config.setVotingPowerIncreaseLimitPct(0);
    }

    function test_RevertWhen_SetVotingPowerIncreaseLimitPct_TooHigh() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVotingPowerIncreaseLimit.selector, 51));
        config.setVotingPowerIncreaseLimitPct(51);
    }

    function test_RevertWhen_SetVotingPowerIncreaseLimitPct_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setVotingPowerIncreaseLimitPct(25);
    }

    function test_Event_SetVotingPowerIncreaseLimitPct() public {
        _initializeConfig();

        uint64 newLimit = 25;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit ValidatorConfig.ConfigUpdated("votingPowerIncreaseLimitPct", VOTING_POWER_LIMIT, newLimit);
        config.setVotingPowerIncreaseLimitPct(newLimit);
    }

    // ========================================================================
    // SETTER TESTS - setMaxValidatorSetSize
    // ========================================================================

    function test_SetMaxValidatorSetSize() public {
        _initializeConfig();

        uint256 newMax = 200;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMaxValidatorSetSize(newMax);

        assertEq(config.maxValidatorSetSize(), newMax);
    }

    function test_SetMaxValidatorSetSize_Min() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMaxValidatorSetSize(1);

        assertEq(config.maxValidatorSetSize(), 1);
    }

    function test_SetMaxValidatorSetSize_Max() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMaxValidatorSetSize(65536);

        assertEq(config.maxValidatorSetSize(), 65536);
    }

    function test_RevertWhen_SetMaxValidatorSetSize_Zero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidValidatorSetSize.selector, 0));
        config.setMaxValidatorSetSize(0);
    }

    function test_RevertWhen_SetMaxValidatorSetSize_TooHigh() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidValidatorSetSize.selector, 65537));
        config.setMaxValidatorSetSize(65537);
    }

    function test_RevertWhen_SetMaxValidatorSetSize_NotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setMaxValidatorSetSize(200);
    }

    function test_Event_SetMaxValidatorSetSize() public {
        _initializeConfig();

        uint256 newMax = 200;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, true);
        emit ValidatorConfig.ConfigUpdated("maxValidatorSetSize", MAX_VALIDATORS, newMax);
        config.setMaxValidatorSetSize(newMax);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Initialize(
        uint256 minBond,
        uint256 maxBond,
        uint64 unbondingDelay,
        bool allowChanges,
        uint64 votingPowerLimit,
        uint256 maxValidators
    ) public {
        // Bound inputs to valid ranges
        minBond = bound(minBond, 1, type(uint128).max);
        maxBond = bound(maxBond, minBond, type(uint128).max);
        vm.assume(unbondingDelay > 0);
        votingPowerLimit = uint64(bound(votingPowerLimit, 1, 50));
        maxValidators = bound(maxValidators, 1, 65536);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(minBond, maxBond, unbondingDelay, allowChanges, votingPowerLimit, maxValidators);

        assertEq(config.minimumBond(), minBond);
        assertEq(config.maximumBond(), maxBond);
        assertEq(config.unbondingDelayMicros(), unbondingDelay);
        assertEq(config.allowValidatorSetChange(), allowChanges);
        assertEq(config.votingPowerIncreaseLimitPct(), votingPowerLimit);
        assertEq(config.maxValidatorSetSize(), maxValidators);
    }

    function testFuzz_SetMinimumBond(
        uint256 newMin
    ) public {
        _initializeConfig();

        // Bound to valid range
        newMin = bound(newMin, 1, MAX_BOND);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMinimumBond(newMin);

        assertEq(config.minimumBond(), newMin);
    }

    function testFuzz_SetMaximumBond(
        uint256 newMax
    ) public {
        _initializeConfig();

        // Bound to valid range
        newMax = bound(newMax, MIN_BOND, type(uint128).max);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMaximumBond(newMax);

        assertEq(config.maximumBond(), newMax);
    }

    function testFuzz_SetUnbondingDelayMicros(
        uint64 newDelay
    ) public {
        vm.assume(newDelay > 0);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setUnbondingDelayMicros(newDelay);

        assertEq(config.unbondingDelayMicros(), newDelay);
    }

    function testFuzz_SetVotingPowerIncreaseLimitPct(
        uint64 newLimit
    ) public {
        newLimit = uint64(bound(newLimit, 1, 50));
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setVotingPowerIncreaseLimitPct(newLimit);

        assertEq(config.votingPowerIncreaseLimitPct(), newLimit);
    }

    function testFuzz_SetMaxValidatorSetSize(
        uint256 newMax
    ) public {
        newMax = bound(newMax, 1, 65536);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMaxValidatorSetSize(newMax);

        assertEq(config.maxValidatorSetSize(), newMax);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }
}

