// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ValidatorConfig } from "../../../src/runtime/ValidatorConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title ValidatorConfigTest
/// @notice Unit tests for ValidatorConfig contract with pending pattern
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
        assertFalse(config.hasPendingConfig());
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
        assertTrue(config.isInitialized());
    }

    function test_Initialize_MinEqualsMax() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MIN_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);

        assertEq(config.minimumBond(), MIN_BOND);
        assertEq(config.maximumBond(), MIN_BOND);
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
    // SETTER TESTS - setForNextEpoch
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeConfig();

        uint256 newMinBond = 200 ether;
        uint256 newMaxBond = 2000 ether;
        uint64 newUnbondingDelay = 28 days * 1_000_000;
        bool newAllowChanges = false;
        uint64 newVotingPowerLimit = 25;
        uint256 newMaxValidators = 200;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(
            newMinBond, newMaxBond, newUnbondingDelay, newAllowChanges, newVotingPowerLimit, newMaxValidators
        );

        // Should not change current values, only set pending
        assertEq(config.minimumBond(), MIN_BOND);
        assertEq(config.maximumBond(), MAX_BOND);
        assertTrue(config.hasPendingConfig());

        (bool hasPending, ValidatorConfig.PendingConfig memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingConfig.minimumBond, newMinBond);
        assertEq(pendingConfig.maximumBond, newMaxBond);
        assertEq(pendingConfig.unbondingDelayMicros, newUnbondingDelay);
        assertEq(pendingConfig.allowValidatorSetChange, newAllowChanges);
        assertEq(pendingConfig.votingPowerIncreaseLimitPct, newVotingPowerLimit);
        assertEq(pendingConfig.maxValidatorSetSize, newMaxValidators);
    }

    function test_RevertWhen_SetForNextEpoch_ZeroMinBond() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidMinimumBond.selector);
        config.setForNextEpoch(0, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }

    function test_RevertWhen_SetForNextEpoch_MaxLessThanMin() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.MinimumBondExceedsMaximum.selector, MIN_BOND, MIN_BOND - 1));
        config.setForNextEpoch(
            MIN_BOND, MIN_BOND - 1, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.ValidatorConfigNotInitialized.selector);
        config.setForNextEpoch(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }

    function test_RevertWhen_SetForNextEpoch_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );
    }

    function test_Event_SetForNextEpoch() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit ValidatorConfig.PendingValidatorConfigSet();
        config.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeConfig();

        uint256 newMinBond = 200 ether;
        uint256 newMaxBond = 2000 ether;
        uint64 newUnbondingDelay = 28 days * 1_000_000;
        bool newAllowChanges = false;
        uint64 newVotingPowerLimit = 25;
        uint256 newMaxValidators = 200;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(
            newMinBond, newMaxBond, newUnbondingDelay, newAllowChanges, newVotingPowerLimit, newMaxValidators
        );

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minimumBond(), newMinBond);
        assertEq(config.maximumBond(), newMaxBond);
        assertEq(config.unbondingDelayMicros(), newUnbondingDelay);
        assertEq(config.allowValidatorSetChange(), newAllowChanges);
        assertEq(config.votingPowerIncreaseLimitPct(), newVotingPowerLimit);
        assertEq(config.maxValidatorSetSize(), newMaxValidators);
        assertFalse(config.hasPendingConfig());
    }

    function test_ApplyPendingConfig_NoPending() public {
        _initializeConfig();

        // Should be no-op when no pending config
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minimumBond(), MIN_BOND);
        assertFalse(config.hasPendingConfig());
    }

    function test_RevertWhen_ApplyPendingConfig_NotReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );

        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        config.applyPendingConfig();
    }

    function test_Event_ApplyPendingConfig() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, true);
        emit ValidatorConfig.ValidatorConfigUpdated();
        config.applyPendingConfig();
    }

    // ========================================================================
    // GOVERNANCE-ONLY ACCESS CONTROL TESTS
    // ========================================================================

    function test_RevertWhen_SetterCalledByGenesis() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GENESIS, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );
    }

    function test_RevertWhen_SetterCalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );
    }

    function test_RevertWhen_SetterCalledByReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.RECONFIGURATION, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS
        );
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

    function testFuzz_SetForNextEpochAndApply(
        uint256 minBond,
        uint256 maxBond,
        uint64 unbondingDelay,
        bool allowChanges,
        uint64 votingPowerLimit,
        uint256 maxValidators
    ) public {
        _initializeConfig();

        // Bound inputs to valid ranges
        minBond = bound(minBond, 1, type(uint128).max);
        maxBond = bound(maxBond, minBond, type(uint128).max);
        vm.assume(unbondingDelay > 0);
        votingPowerLimit = uint64(bound(votingPowerLimit, 1, 50));
        maxValidators = bound(maxValidators, 1, 65536);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(minBond, maxBond, unbondingDelay, allowChanges, votingPowerLimit, maxValidators);

        assertTrue(config.hasPendingConfig());

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minimumBond(), minBond);
        assertEq(config.maximumBond(), maxBond);
        assertEq(config.unbondingDelayMicros(), unbondingDelay);
        assertEq(config.allowValidatorSetChange(), allowChanges);
        assertEq(config.votingPowerIncreaseLimitPct(), votingPowerLimit);
        assertEq(config.maxValidatorSetSize(), maxValidators);
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_BOND, MAX_BOND, UNBONDING_DELAY, ALLOW_CHANGES, VOTING_POWER_LIMIT, MAX_VALIDATORS);
    }
}
