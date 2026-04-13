// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EpsilonHardforkBase } from "./EpsilonHardforkBase.t.sol";
import { ValidatorManagement } from "../../src/staking/ValidatorManagement.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";

/// @title EpsilonReconfigurationUpgrade
/// @notice Verifies PR #63 moves the auto-eviction hook from `_applyReconfiguration`
///         (where it was called AFTER `applyPendingConfig` and AFTER the DKG target
///         set was already chosen) to `checkAndStartTransition` and
///         `governanceReconfigure` (where it runs BEFORE the DKG target set is
///         finalized). This eliminates the consensus-halt scenario where DKG nodes
///         disagreed on the validator set because some saw the eviction and others
///         didn't.
///
///         The tests use `vm.expectCall` to assert that
///         `evictUnderperformingValidators()` is invoked from the new sites.
contract EpsilonReconfigurationUpgradeTest is EpsilonHardforkBase {
    bytes internal constant EVICT_SELECTOR = abi.encodeWithSelector(ValidatorManagement.evictUnderperformingValidators.selector);

    /// @notice After the hardfork, `governanceReconfigure` must call
    ///         `evictUnderperformingValidators()` before any DKG / epoch logic.
    function test_governanceReconfigure_callsEvict() public {
        _applyEpsilonHardfork();

        vm.expectCall(SystemAddresses.VALIDATOR_MANAGER, EVICT_SELECTOR);
        vm.prank(SystemAddresses.GOVERNANCE);
        reconfig.governanceReconfigure();
    }

    /// @notice After the hardfork, `checkAndStartTransition` must call
    ///         `evictUnderperformingValidators()` once the epoch deadline has elapsed
    ///         (not as part of `_applyReconfiguration`).
    function test_checkAndStartTransition_callsEvict_whenEpochMatured() public {
        _applyEpsilonHardfork();

        // Advance time past the epoch deadline so checkAndStartTransition does not
        // early-return on `_canTransition()`. _setInitialTimestamp() in setUp set the
        // baseline; epoch length is TWO_HOURS.
        _advanceTime(TWO_HOURS + 1);

        vm.expectCall(SystemAddresses.VALIDATOR_MANAGER, EVICT_SELECTOR);
        vm.prank(SystemAddresses.BLOCK);
        bool started = reconfig.checkAndStartTransition();
        assertTrue(started, "transition should have started after epoch deadline");
    }

    /// @notice `_applyReconfiguration` (reached via `finishTransition`) must NOT call
    ///         evict — that's the whole point of the call-site move. We can't reach
    ///         _applyReconfiguration directly without a DKG flow, so assert via
    ///         governanceReconfigure → finishTransition path with DKG off.
    /// @dev The Epsilon base sets up RandomnessConfig with V2 (DKG enabled). For this
    ///      test, governanceReconfigure with DKG enabled goes through _startDkgSession,
    ///      then finishTransition is needed. Easier proxy: count total invocations
    ///      from a single governanceReconfigure → finishTransition cycle is exactly 1.
    function test_singleGovernanceCycle_evictsExactlyOnce() public {
        _applyEpsilonHardfork();

        // expectCall with count=1 asserts evict() runs exactly once for the whole
        // governance reconfigure cycle (NOT a second time inside _applyReconfiguration).
        vm.expectCall(SystemAddresses.VALIDATOR_MANAGER, EVICT_SELECTOR, 1);

        vm.prank(SystemAddresses.GOVERNANCE);
        reconfig.governanceReconfigure();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        reconfig.finishTransition(SAMPLE_DKG_TRANSCRIPT);
    }
}
