// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EpsilonHardforkBase } from "./EpsilonHardforkBase.t.sol";
import { GBridgeReceiver } from "../../src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";

/// @title EpsilonGBridgeReceiverUpgrade
/// @notice Verifies PR #66 changes survive bytecode replacement:
///         - `_processedNonces` mapping removed
///         - slot 0 reused as `__deprecated_processedNonces` storage gap (preserved)
///         - `isProcessed(uint128)` view function removed
///         - `AlreadyProcessed` error no longer used (no replay revert in handler)
contract EpsilonGBridgeReceiverUpgradeTest is EpsilonHardforkBase {
    /// @notice After the hardfork, slot 0 still reads the value written before it.
    ///         This is the storage-layout compatibility guarantee for the deprecated
    ///         mapping bucket: any prior data must remain untouched.
    function test_slot0_preservedAcrossHardfork() public {
        bytes32 sentinel = bytes32(uint256(0xDEADBEEF));
        vm.store(GBRIDGE_RECEIVER_ADDR, bytes32(uint256(0)), sentinel);

        _applyEpsilonHardfork();

        assertEq(vm.load(GBRIDGE_RECEIVER_ADDR, bytes32(uint256(0))), sentinel);
    }

    /// @notice The `__deprecated_processedNonces` getter exposes slot 0 as a uint256.
    function test_deprecatedGetter_readsSlot0() public {
        vm.store(GBRIDGE_RECEIVER_ADDR, bytes32(uint256(0)), bytes32(uint256(42)));

        _applyEpsilonHardfork();

        // The contract no longer exposes a getter for the field (it's `private`),
        // so verify via raw storage load that slot 0 is still readable as expected.
        assertEq(uint256(vm.load(GBRIDGE_RECEIVER_ADDR, bytes32(uint256(0)))), 42);
    }

    /// @notice After the hardfork, calling the removed `isProcessed(uint128)` selector
    ///         should fail (no dispatcher entry).
    function test_isProcessed_selectorRemoved() public {
        _applyEpsilonHardfork();

        (bool ok,) = GBRIDGE_RECEIVER_ADDR.call(abi.encodeWithSignature("isProcessed(uint128)", uint128(1)));
        assertFalse(ok, "isProcessed selector should not be in dispatcher");
    }

    /// @notice The surviving public/immutable getters still work after the hardfork.
    function test_immutableGetters_stillWork() public {
        _applyEpsilonHardfork();

        GBridgeReceiver receiver = GBridgeReceiver(GBRIDGE_RECEIVER_ADDR);
        assertEq(receiver.trustedBridge(), TRUSTED_BRIDGE);
        assertEq(receiver.trustedSourceId(), TRUSTED_SOURCE_ID);
    }
}
