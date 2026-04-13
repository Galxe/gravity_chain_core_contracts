// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EpsilonHardforkBase } from "./EpsilonHardforkBase.t.sol";
import { ValidatorManagement } from "../../src/staking/ValidatorManagement.sol";
import { IValidatorManagement } from "../../src/staking/IValidatorManagement.sol";
import { IValidatorPerformanceTracker } from "../../src/blocker/IValidatorPerformanceTracker.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { ValidatorStatus } from "../../src/foundation/Types.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";

/// @title EpsilonValidatorManagementUpgrade
/// @notice Verifies PR #56 (D3-2 underbonded eviction + percentage threshold) behavior
///         survives bytecode replacement.
///
///         Comprehensive D3-2 unit coverage already exists in
///         test/unit/staking/ValidatorManagement.t.sol. The hardfork-specific value
///         these tests add is verifying that:
///         (a) validator state created BEFORE the hardfork is correctly read by the
///             new evict logic AFTER the hardfork (no storage layout drift),
///         (b) the epoch-1 skip rule still applies post-etch,
///         (c) the new ValidatorUnderbondedEvicted event fires correctly post-etch.
contract EpsilonValidatorManagementUpgradeTest is EpsilonHardforkBase {
    /// @notice Validators created pre-hardfork must remain in ACTIVE state after the
    ///         bytecode replacement. ValidatorManagement uses several mappings + arrays
    ///         (`_validators`, `_activeValidators`, `_pendingActive`, ...) so any
    ///         storage layout drift would scramble them.
    function test_existingValidators_preservedThroughHardfork() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND * 2, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND * 3, "bob");
        _processEpoch();

        uint256 countBefore = validatorManager.getActiveValidatorCount();
        uint8 statusAliceBefore = uint8(validatorManager.getValidatorStatus(pool1));
        uint8 statusBobBefore = uint8(validatorManager.getValidatorStatus(pool2));

        _applyEpsilonHardfork();

        assertEq(validatorManager.getActiveValidatorCount(), countBefore);
        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), statusAliceBefore);
        assertEq(uint8(validatorManager.getValidatorStatus(pool2)), statusBobBefore);
    }

    /// @notice Epoch 1 must skip eviction even if a validator is underbonded.
    ///         The skip is `closingEpoch <= 1`. Reconfiguration.initialize() sets
    ///         currentEpoch=1, so to stay at epoch 1 we activate validators via the
    ///         lightweight _processEpoch() (which only calls onNewEpoch, doesn't bump
    ///         currentEpoch) instead of a full _completeEpochTransition().
    function test_evict_skipsEpoch1_postHardfork() public {
        address poolUnder = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address poolOk = _createRegisterAndJoin(bob, MIN_BOND * 5, "bob");
        _processEpoch(); // activate validators, currentEpoch stays at 1

        // Raise minimumBond so alice becomes underbonded
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND * 3, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
        );
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        _applyEpsilonHardfork();

        // currentEpoch is still 1 → eviction should be skipped
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorManager.evictUnderperformingValidators();

        assertEq(uint8(validatorManager.getValidatorStatus(poolUnder)), uint8(ValidatorStatus.ACTIVE));
        assertEq(uint8(validatorManager.getValidatorStatus(poolOk)), uint8(ValidatorStatus.ACTIVE));
    }

    /// @notice From epoch 2 onward, an underbonded validator gets evicted and the
    ///         new ValidatorUnderbondedEvicted event fires.
    function test_evict_underbondedAtEpoch2_postHardfork() public {
        address poolUnder = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address poolOk = _createRegisterAndJoin(bob, MIN_BOND * 5, "bob");
        _completeEpochTransition(); // currentEpoch → 1
        _completeEpochTransition(); // currentEpoch → 2

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND * 3, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
        );
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        _applyEpsilonHardfork();

        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ValidatorUnderbondedEvicted(poolUnder, MIN_BOND, MIN_BOND * 3);

        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorManager.evictUnderperformingValidators();

        assertEq(uint8(validatorManager.getValidatorStatus(poolUnder)), uint8(ValidatorStatus.PENDING_INACTIVE));
        assertEq(uint8(validatorManager.getValidatorStatus(poolOk)), uint8(ValidatorStatus.ACTIVE));
    }

    /// @notice The percentage-based Phase 2 path also works post-hardfork.
    function test_evict_percentageThreshold_postHardfork() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND * 5, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND * 5, "bob");
        _completeEpochTransition(); // currentEpoch → 1
        _completeEpochTransition(); // currentEpoch → 2

        // Enable autoEvict with 50% threshold
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, true, 50
        );
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        _applyEpsilonHardfork();
        assertEq(validatorConfig.autoEvictThresholdPct(), 50);

        // Mock the performance tracker so alice has 0% success and bob has 100%
        uint256 len = validatorManager.getActiveValidatorCount();
        IValidatorPerformanceTracker.IndividualPerformance[] memory perfs =
            new IValidatorPerformanceTracker.IndividualPerformance[](len);
        for (uint64 i = 0; i < len; i++) {
            address v = validatorManager.getActiveValidatorByIndex(i).validator;
            if (v == pool1) {
                perfs[i] = IValidatorPerformanceTracker.IndividualPerformance(0, 10);
            } else {
                perfs[i] = IValidatorPerformanceTracker.IndividualPerformance(10, 0);
            }
        }
        vm.mockCall(
            SystemAddresses.PERFORMANCE_TRACKER,
            abi.encodeWithSelector(IValidatorPerformanceTracker.getAllPerformances.selector),
            abi.encode(perfs)
        );

        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorManager.evictUnderperformingValidators();

        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.PENDING_INACTIVE));
        assertEq(uint8(validatorManager.getValidatorStatus(pool2)), uint8(ValidatorStatus.ACTIVE));
    }
}
