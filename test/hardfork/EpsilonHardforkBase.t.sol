// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { HardforkTestBase } from "./HardforkTestBase.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { GBridgeReceiver } from "../../src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";

/// @title EpsilonHardforkBase
/// @notice Epsilon-specific hardfork test base.
///
///         Epsilon (gravity-testnet-v1.3 → v1.4) replaces the bytecode of:
///           - ValidatorManagement   (PR #56 D3-2 underbonded eviction)
///           - Reconfiguration       (PR #63 eviction call site moved)
///           - ValidatorConfig       (PR #63 autoEvictThresholdPct)
///           - GBridgeReceiver       (PR #66 _processedNonces removed)
///
///         GBridgeReceiver is *not* a fixed system address — it's deployed by
///         Genesis at runtime. Tests therefore deploy a fresh receiver in setUp
///         at a deterministic address and pass it to HardforkRegistry.epsilon().
abstract contract EpsilonHardforkBase is HardforkTestBase {
    /// @notice Fixed address used for the GBridgeReceiver under test
    address public constant GBRIDGE_RECEIVER_ADDR = address(0xBEEF1234);

    /// @notice Trusted Ethereum bridge address used in receiver constructor.
    /// @dev MUST match the value baked into HardforkTestBase._compileNewBytecode("GBridgeReceiver"),
    ///      otherwise re-etching during _applyHardfork() changes the immutable bytes and
    ///      the post-hardfork getters return a different address.
    address public constant TRUSTED_BRIDGE = address(0xBEEF);

    /// @notice Trusted source chain id used in receiver constructor.
    /// @dev MUST match HardforkTestBase._compileNewBytecode("GBridgeReceiver").
    uint256 public constant TRUSTED_SOURCE_ID = 1;

    function setUp() public virtual {
        _deployFromCurrentBytecodes();
        _deployGBridgeReceiver();
        _initializeAllConfigs();
        // Blocker.initialize() calls updateGlobalTime(SYSTEM_CALLER, 0) which
        // requires timestamp==0, so it must run BEFORE _setInitialTimestamp().
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();
        _fundTestAccounts();
    }

    /// @notice Etch a GBridgeReceiver instance at GBRIDGE_RECEIVER_ADDR.
    /// @dev `trustedBridge` and `trustedSourceId` are *immutables* baked into the
    ///      bytecode at construction, so etching `address(tmp).code` is sufficient —
    ///      the etched contract's getters return the constructor values.
    ///      Slot 0 holds `__deprecated_processedNonces` (uint256), defaults to 0.
    function _deployGBridgeReceiver() internal {
        GBridgeReceiver tmp = new GBridgeReceiver(TRUSTED_BRIDGE, TRUSTED_SOURCE_ID);
        vm.etch(GBRIDGE_RECEIVER_ADDR, address(tmp).code);
    }

    /// @notice Apply Epsilon hardfork using the registry definition
    function _applyEpsilonHardfork() internal {
        HardforkRegistry.HardforkDef memory def = HardforkRegistry.epsilon(GBRIDGE_RECEIVER_ADDR);
        _applyHardfork(def);
    }
}
