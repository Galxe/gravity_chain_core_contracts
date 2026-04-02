// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { HardforkTestBase } from "./HardforkTestBase.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";

/// @title DeltaHardforkBase
/// @notice Delta-specific hardfork test base.
///         Extends HardforkTestBase with Delta-specific setup:
///         - Uses current bytecodes for initial deployment (simulating pre-hardfork state)
///         - Provides `_applyDeltaHardfork()` using HardforkRegistry definition
///
///         For true v1.2.0→current migration tests, see DeltaHardforkMigration.t.sol
///         which uses `_deployFromFixtures("gravity-testnet-v1.2.0")`.
abstract contract DeltaHardforkBase is HardforkTestBase {
    // ========================================================================
    // SETUP
    // ========================================================================

    function setUp() public virtual {
        _deployFromCurrentBytecodes();
        _initializeAllConfigs();
        // Blocker.initialize() calls updateGlobalTime(SYSTEM_CALLER, 0) which
        // requires timestamp==0, so must be called BEFORE _setInitialTimestamp()
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();
        _fundTestAccounts();
    }

    // ========================================================================
    // DELTA HARDFORK APPLICATION
    // ========================================================================

    /// @notice Apply Delta hardfork using the registry definition
    /// @dev Storage gap pattern means no storage migration is needed — just bytecode replacement.
    function _applyDeltaHardfork() internal {
        HardforkRegistry.HardforkDef memory def = HardforkRegistry.delta();
        _applyHardfork(def);
    }

    // ========================================================================
    // CONVENIENCE HELPERS
    // ========================================================================

    /// @notice Set up a basic running chain with 2 active validators
    function _setupRunningChainWith2Validators() internal returns (address pool1, address pool2) {
        pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND * 2, "bob");
        _processEpoch();
    }
}
