// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { GammaHardforkBase } from "./GammaHardforkBase.t.sol";
import { NativeOracle } from "../../src/oracle/NativeOracle.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title NativeOracleUpgradeTest
/// @notice Tests for NativeOracle after Gamma hardfork bytecode replacement.
///         Key concern: nonce validation changed from `>` (strictly increasing, allows gaps)
///         to `== current + 1` (strictly sequential, no gaps allowed).
contract NativeOracleUpgradeTest is GammaHardforkBase {
    uint32 constant SOURCE_TYPE_JWK = 1;
    uint256 constant SOURCE_ID = 100;

    function setUp() public override {
        super.setUp();
        _applyGammaHardfork();
    }

    // ========================================================================
    // NONCE SEQUENTIAL VALIDATION
    // ========================================================================

    /// @notice Test that sequential nonces work correctly (1, 2, 3)
    function test_nonce_sequentialWorks() public {
        // Record with nonce 1 (first nonce should be 1 since current starts at 0)
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 1);

        // Nonce 2
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 2);

        // Nonce 3
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 3);

        // Verify latest nonce
        assertEq(nativeOracle.getLatestNonce(SOURCE_TYPE_JWK, SOURCE_ID), 3, "latest nonce should be 3");
    }

    /// @notice Test that skipping nonces reverts (was allowed pre-hardfork)
    function test_nonce_skipReverts() public {
        // Record nonce 1
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 1);

        // Try nonce 3 (skip 2) — should revert with NonceNotSequential
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_JWK, SOURCE_ID, 2, 3)
        );
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 3, block.number, hex"aabb", 0);
    }

    /// @notice Test that duplicate nonce reverts
    function test_nonce_duplicateReverts() public {
        _recordData(SOURCE_TYPE_JWK, SOURCE_ID, 1);

        // Try nonce 1 again — should revert (expected nonce is 2)
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_JWK, SOURCE_ID, 2, 1)
        );
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 1, block.number, hex"aabb", 0);
    }

    /// @notice Test that nonce 0 reverts (first valid nonce is 1)
    function test_nonce_zeroReverts() public {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_JWK, SOURCE_ID, 1, 0)
        );
        nativeOracle.record(SOURCE_TYPE_JWK, SOURCE_ID, 0, block.number, hex"aabb", 0);
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

    function _recordData(uint32 sourceType, uint256 sourceId, uint128 nonce) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.record(sourceType, sourceId, nonce, block.number, abi.encodePacked("payload_", nonce), 0);
    }
}
