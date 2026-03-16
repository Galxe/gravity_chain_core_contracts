// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { HardforkTestBase } from "./HardforkTestBase.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";

/// @title GammaHardforkBase
/// @notice Gamma-specific hardfork test base.
///         Extends HardforkTestBase with Gamma-specific setup:
///         - Uses current bytecodes for initial deployment (simulating pre-hardfork state)
///         - Provides `_applyGammaHardfork()` using HardforkRegistry definition
///
///         For true v1.0.0→current migration tests, see GammaHardforkMigration.t.sol
///         which uses `_deployFromFixtures("gravity-testnet-v1.0.0")`.
abstract contract GammaHardforkBase is HardforkTestBase {
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
    // GAMMA HARDFORK APPLICATION
    // ========================================================================

    /// @notice Apply Gamma hardfork using the registry definition
    function _applyGammaHardfork() internal {
        HardforkRegistry.HardforkDef memory def = HardforkRegistry.gamma();
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
