// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DeltaHardforkBase } from "./DeltaHardforkBase.t.sol";
import { NativeOracle } from "../../src/oracle/NativeOracle.sol";
import { INativeOracle } from "../../src/oracle/INativeOracle.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title DeltaNativeOracleUpgradeTest
/// @notice Tests for NativeOracle after Delta hardfork bytecode replacement.
///         Key concerns from PR #58:
///         - Callback invocation refactored: gasLimit=0 now emits CallbackSkipped
///           instead of silently skipping callback entirely
///         - Sequential nonce validation still works
///         - Batch recording still works
contract DeltaNativeOracleUpgradeTest is DeltaHardforkBase {
    uint32 constant SOURCE_TYPE_JWK = 1;
    uint256 constant SOURCE_ID = 100;

    function setUp() public override {
        super.setUp();
        _applyDeltaHardfork();
    }

    // ========================================================================
    // CALLBACK GAS LIMIT = 0 BEHAVIOR (PR #58)
    // ========================================================================

    /// @notice Test that gasLimit=0 emits CallbackSkipped and stores record
    /// @dev Previously: gasLimit=0 would skip callback silently and store.
    ///      Now: gasLimit=0 explicitly emits CallbackSkipped event and stores.
    function test_callbackGasLimitZero_emitsEvent() public {
        // Record with gasLimit=0 — should emit CallbackSkipped for JWKManager callback
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(true, true, true, true);
        emit INativeOracle.CallbackSkipped(SOURCE_TYPE_JWK, SOURCE_ID, 1, SystemAddresses.JWK_MANAGER);
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 1, block.number, hex"aabb", 0);

        // Data should still be stored (callback was skipped, not failed)
        assertEq(
            nativeOracle.getLatestNonce(SOURCE_TYPE_JWK, SOURCE_ID), 1, "nonce should be recorded even with gasLimit=0"
        );
    }

    /// @notice Test that gasLimit > 0 invokes callback normally
    function test_callbackGasLimitNonZero_invokesCallback() public {
        // Record with gasLimit > 0 — callback should be invoked
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 1, block.number, hex"aabb", 100_000);

        assertEq(nativeOracle.getLatestNonce(SOURCE_TYPE_JWK, SOURCE_ID), 1, "nonce should be recorded");
    }

    // ========================================================================
    // NONCE SEQUENTIAL VALIDATION (preserved from Gamma)
    // ========================================================================

    /// @notice Test that sequential nonces work correctly (1, 2, 3)
    function test_nonce_sequentialWorks() public {
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 1);
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 2);
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 3);
        assertEq(nativeOracle.getLatestNonce(SOURCE_TYPE_JWK, SOURCE_ID), 3, "latest nonce should be 3");
    }

    /// @notice Test that skipping nonces reverts
    function test_nonce_skipReverts() public {
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 1);

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_JWK, SOURCE_ID, 2, 3));
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 3, block.number, hex"aabb", 0);
    }

    /// @notice Test that duplicate nonce reverts
    function test_nonce_duplicateReverts() public {
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 1);

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_JWK, SOURCE_ID, 2, 1));
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 1, block.number, hex"aabb", 0);
    }

    // ========================================================================
    // ACCESS CONTROL
    // ========================================================================

    /// @notice Test that only SYSTEM_CALLER can record data
    function test_access_onlySystemCaller() public {
        vm.prank(alice);
        vm.expectRevert();
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 1, block.number, hex"aabb", 0);
    }

    // ========================================================================
    // BATCH RECORDING
    // ========================================================================

    /// @notice Test recordBatch with sequential nonces
    function test_batch_sequentialWorks() public {
        uint128[] memory nonces = new uint128[](3);
        nonces[0] = 1;
        nonces[1] = 2;
        nonces[2] = 3;

        uint256[] memory blockNumbers = new uint256[](3);
        blockNumbers[0] = block.number;
        blockNumbers[1] = block.number;
        blockNumbers[2] = block.number;

        bytes[] memory payloads = new bytes[](3);
        payloads[0] = hex"aa";
        payloads[1] = hex"bb";
        payloads[2] = hex"cc";

        uint256[] memory gasLimits = new uint256[](3);
        gasLimits[0] = 0;
        gasLimits[1] = 0;
        gasLimits[2] = 0;

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.recordBatch(SOURCE_TYPE_JWK, SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);

        assertEq(nativeOracle.getLatestNonce(SOURCE_TYPE_JWK, SOURCE_ID), 3, "latest nonce should be 3");
    }

    /// @notice Test isSyncedPast works after recording
    function test_isSyncedPast() public {
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 1);
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 2);

        assertTrue(nativeOracle.isSyncedPast(SOURCE_TYPE_JWK, SOURCE_ID, 1), "should be synced past 1");
        assertTrue(nativeOracle.isSyncedPast(SOURCE_TYPE_JWK, SOURCE_ID, 2), "should be synced past 2");
        assertFalse(nativeOracle.isSyncedPast(SOURCE_TYPE_JWK, SOURCE_ID, 3), "should not be synced past 3");
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _recordData(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.record(sourceType, sourceId, nonce, block.number, abi.encodePacked("payload_", nonce), 0);
    }
}
