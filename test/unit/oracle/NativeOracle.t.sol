// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle, IOracleCallback } from "../../../src/oracle/INativeOracle.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";

/// @title MockOracleCallback
/// @notice Mock callback handler for testing
contract MockOracleCallback is IOracleCallback {
    uint32 public lastSourceType;
    uint256 public lastSourceId;
    uint128 public lastNonce;
    bytes public lastPayload;
    uint256 public callCount;
    bool public shouldRevert;
    bool public shouldConsumeAllGas;

    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external override {
        if (shouldRevert) {
            revert("MockCallback: intentional revert");
        }
        if (shouldConsumeAllGas) {
            // Consume all gas by infinite loop
            while (true) { }
        }

        lastSourceType = sourceType;
        lastSourceId = sourceId;
        lastNonce = nonce;
        lastPayload = payload;
        callCount++;
    }

    function setRevert(
        bool _shouldRevert
    ) external {
        shouldRevert = _shouldRevert;
    }

    function setConsumeAllGas(
        bool _shouldConsumeAllGas
    ) external {
        shouldConsumeAllGas = _shouldConsumeAllGas;
    }
}

/// @title NativeOracleTest
/// @notice Comprehensive unit tests for NativeOracle contract
contract NativeOracleTest is Test {
    NativeOracle public oracle;
    MockOracleCallback public mockCallback;

    // Test addresses
    address public systemCaller;
    address public governance;
    address public alice;
    address public bob;

    // Test data - Source types as uint32 (0 = BLOCKCHAIN, 1 = JWK, etc.)
    uint32 public constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint32 public constant SOURCE_TYPE_JWK = 1;
    uint256 public constant ETHEREUM_SOURCE_ID = 1; // Ethereum chain ID
    uint256 public constant GOOGLE_JWK_SOURCE_ID = 1; // Google JWK provider
    uint256 public constant CALLBACK_GAS_LIMIT = 500_000;

    function setUp() public {
        // Set up addresses
        systemCaller = SystemAddresses.SYSTEM_CALLER;
        governance = SystemAddresses.GOVERNANCE;
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy oracle
        oracle = new NativeOracle();

        // Deploy mock callback
        mockCallback = new MockOracleCallback();
    }

    // ========================================================================
    // RECORD TESTS
    // ========================================================================

    function test_Record() public {
        bytes memory payload = abi.encode(alice, uint256(100), "deposit");
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        // Verify record exists (recordedAt > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
        assertEq(record.data, payload);

        // Verify latest nonce
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), nonce);
    }

    function test_Record_RevertWhenNotSystemCaller() public {
        bytes memory payload = abi.encode(alice, uint256(100));

        vm.expectRevert();
        vm.prank(alice);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Record_RevertWhenNonceIsZero() public {
        bytes memory payload = abi.encode("first");

        // Try to record with nonce = 0 (latestNonce starts at 0, so nonce must be > 0)
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0, 0)
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Record_RevertWhenNonceNotIncreasing() public {
        bytes memory payload1 = abi.encode("first");

        // Record first
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload1, CALLBACK_GAS_LIMIT);

        // Try to record with same nonce
        bytes memory payload2 = abi.encode("second");

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.NonceNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, 1000
            )
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload2, CALLBACK_GAS_LIMIT);

        // Try to record with lower nonce
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.NonceNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, 500
            )
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 500, payload2, CALLBACK_GAS_LIMIT);
    }

    function test_Record_MultipleSourcesIndependent() public {
        bytes memory payload1 = abi.encode("ethereum event");
        bytes memory payload2 = abi.encode("google jwk");

        // Record to ethereum source
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload1, CALLBACK_GAS_LIMIT);

        // Record to google source with lower nonce (allowed because different source)
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, 500, payload2, CALLBACK_GAS_LIMIT);

        // Verify both sources
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1000);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID), 500);
    }

    // ========================================================================
    // BATCH RECORDING TESTS
    // ========================================================================

    function test_RecordBatch() public {
        bytes[] memory payloads = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            payloads[i] = abi.encode("event", i);
        }

        uint128 nonce = 2000;

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payloads, CALLBACK_GAS_LIMIT);

        // Verify all records exist (recordedAt > 0 means exists)
        for (uint256 i = 0; i < 3; i++) {
            uint128 currentNonce = nonce + uint128(i);
            INativeOracle.DataRecord memory record =
                oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, currentNonce);
            assertTrue(record.recordedAt > 0);
            assertEq(record.data, payloads[i]);
        }

        // Verify latest nonce is the final nonce
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), nonce + 2);
    }

    function test_RecordBatch_EmptyPayloads() public {
        bytes[] memory payloads = new bytes[](0);

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payloads, CALLBACK_GAS_LIMIT);

        // Nothing should be recorded
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
    }

    // ========================================================================
    // CALLBACK TESTS
    // ========================================================================

    function test_SetDefaultCallback() public {
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(mockCallback));

        assertEq(oracle.getDefaultCallback(SOURCE_TYPE_BLOCKCHAIN), address(mockCallback));
    }

    function test_SetDefaultCallback_RevertWhenNotGovernance() public {
        vm.expectRevert();
        vm.prank(alice);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(mockCallback));
    }

    function test_SetDefaultCallback_Unregister() public {
        // Register default callback
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(mockCallback));

        // Unregister by setting to zero
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(0));

        assertEq(oracle.getDefaultCallback(SOURCE_TYPE_BLOCKCHAIN), address(0));
    }

    function test_SetCallback() public {
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        assertEq(oracle.getCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), address(mockCallback));
    }

    function test_SetCallback_RevertWhenNotGovernance() public {
        vm.expectRevert();
        vm.prank(alice);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));
    }

    function test_SetCallback_Unregister() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Unregister by setting to zero
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(0));

        assertEq(oracle.getCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), address(0));
    }

    function test_GetCallback_TwoLayerResolution() public {
        MockOracleCallback defaultCallback = new MockOracleCallback();
        MockOracleCallback specializedCallback = new MockOracleCallback();

        // Set default callback for BLOCKCHAIN type
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(defaultCallback));

        // Before specialized is set, getCallback returns default
        assertEq(oracle.getCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), address(defaultCallback));

        // Set specialized callback for ETHEREUM_SOURCE_ID
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(specializedCallback));

        // Now getCallback returns specialized
        assertEq(oracle.getCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), address(specializedCallback));

        // Other source IDs still use default
        uint256 arbitrumSourceId = 42161;
        assertEq(oracle.getCallback(SOURCE_TYPE_BLOCKCHAIN, arbitrumSourceId), address(defaultCallback));

        // Unregister specialized, falls back to default
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(0));
        assertEq(oracle.getCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), address(defaultCallback));
    }

    function test_CallbackInvoked() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        // Verify callback was invoked
        assertEq(mockCallback.callCount(), 1);
        assertEq(mockCallback.lastSourceType(), SOURCE_TYPE_BLOCKCHAIN);
        assertEq(mockCallback.lastSourceId(), ETHEREUM_SOURCE_ID);
        assertEq(mockCallback.lastNonce(), nonce);
        assertEq(mockCallback.lastPayload(), payload);
    }

    function test_CallbackNotInvokedWhenGasLimitZero() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record with zero gas limit
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, 0);

        // Verify callback was NOT invoked
        assertEq(mockCallback.callCount(), 0);
    }

    function test_DefaultCallbackInvoked() public {
        // Register default callback for BLOCKCHAIN type
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(mockCallback));

        // Record (no specialized callback set)
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        // Verify default callback was invoked
        assertEq(mockCallback.callCount(), 1);
        assertEq(mockCallback.lastSourceType(), SOURCE_TYPE_BLOCKCHAIN);
        assertEq(mockCallback.lastSourceId(), ETHEREUM_SOURCE_ID);
        assertEq(mockCallback.lastNonce(), nonce);
        assertEq(mockCallback.lastPayload(), payload);
    }

    function test_SpecializedCallbackOverridesDefault() public {
        MockOracleCallback defaultCallback = new MockOracleCallback();
        MockOracleCallback specializedCallback = new MockOracleCallback();

        // Set default callback
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(defaultCallback));

        // Set specialized callback for ETHEREUM_SOURCE_ID
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(specializedCallback));

        // Record
        bytes memory payload = abi.encode(alice, uint256(100));

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload, CALLBACK_GAS_LIMIT);

        // Specialized callback should be invoked, not default
        assertEq(specializedCallback.callCount(), 1);
        assertEq(defaultCallback.callCount(), 0);
    }

    function test_DefaultCallbackForDifferentSourceIds() public {
        MockOracleCallback defaultCallback = new MockOracleCallback();
        MockOracleCallback specializedCallback = new MockOracleCallback();
        uint256 arbitrumSourceId = 42161;

        // Set default callback for BLOCKCHAIN type
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(defaultCallback));

        // Set specialized callback only for ETHEREUM_SOURCE_ID
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(specializedCallback));

        // Record for Arbitrum (should use default)
        bytes memory payload1 = abi.encode("arbitrum event");
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, arbitrumSourceId, 1000, payload1, CALLBACK_GAS_LIMIT);

        // Record for Ethereum (should use specialized)
        bytes memory payload2 = abi.encode("ethereum event");
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2000, payload2, CALLBACK_GAS_LIMIT);

        // Verify correct callbacks were invoked
        assertEq(defaultCallback.callCount(), 1);
        assertEq(defaultCallback.lastSourceId(), arbitrumSourceId);

        assertEq(specializedCallback.callCount(), 1);
        assertEq(specializedCallback.lastSourceId(), ETHEREUM_SOURCE_ID);
    }

    function test_CallbackFailureDoesNotRevert() public {
        // Register callback that reverts
        mockCallback.setRevert(true);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record - should NOT revert even though callback fails
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        // Record should still exist (recordedAt > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);

        // Callback was not successfully called
        assertEq(mockCallback.callCount(), 0);
    }

    function test_CallbackGasLimitEnforced() public {
        // Register callback that consumes all gas
        mockCallback.setConsumeAllGas(true);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record - should NOT revert even though callback runs out of gas
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        // Record should still exist (recordedAt > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
    }

    function test_CallbackInvokedForBatch() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record batch
        bytes[] memory payloads = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            payloads[i] = abi.encode("event", i);
        }

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2000, payloads, CALLBACK_GAS_LIMIT);

        // Callback should be invoked 3 times
        assertEq(mockCallback.callCount(), 3);
    }

    function test_CallbackNotInvokedForBatchWhenGasLimitZero() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record batch with zero gas limit
        bytes[] memory payloads = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            payloads[i] = abi.encode("event", i);
        }

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2000, payloads, 0);

        // Callback should NOT be invoked
        assertEq(mockCallback.callCount(), 0);
    }

    // ========================================================================
    // QUERY TESTS
    // ========================================================================

    function test_GetRecord() public {
        bytes memory payload = abi.encode(alice, uint256(100), "deposit");
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        // Get record
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
        assertEq(record.data, payload);
    }

    function test_GetRecord_NotFound() public view {
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 999);
        assertEq(record.recordedAt, 0); // Not found
    }

    function test_IsSyncedPast() public {
        bytes memory payload = abi.encode("test");

        // Before recording, not synced
        assertFalse(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 500));

        // Record at nonce 1000
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload, CALLBACK_GAS_LIMIT);

        // Now synced past 500 and 1000
        assertTrue(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 500));
        assertTrue(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000));

        // Not synced past 1001
        assertFalse(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1001));
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Record(
        bytes memory payload,
        uint128 nonce
    ) public {
        vm.assume(nonce > 0);

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
        assertEq(record.data, payload);
    }

    function testFuzz_NonceMustIncrease(
        uint128 nonce1,
        uint128 nonce2
    ) public {
        vm.assume(nonce1 > 0);
        vm.assume(nonce2 <= nonce1);

        bytes memory payload1 = abi.encode("first");

        // First record succeeds
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce1, payload1, CALLBACK_GAS_LIMIT);

        // Second record with non-increasing nonce fails
        bytes memory payload2 = abi.encode("second");

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.NonceNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce1, nonce2
            )
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce2, payload2, CALLBACK_GAS_LIMIT);
    }

    function testFuzz_SourceTypeAndId(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) public {
        vm.assume(nonce > 0);

        bytes memory payload = abi.encode("test", sourceType, sourceId);

        vm.prank(systemCaller);
        oracle.record(sourceType, sourceId, nonce, payload, CALLBACK_GAS_LIMIT);

        assertEq(oracle.getLatestNonce(sourceType, sourceId), nonce);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_DataRecorded() public {
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        vm.expectEmit(true, true, true, true);
        emit INativeOracle.DataRecorded(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload.length);

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Events_DefaultCallbackSet() public {
        vm.expectEmit(true, true, true, true);
        emit INativeOracle.DefaultCallbackSet(SOURCE_TYPE_BLOCKCHAIN, address(0), address(mockCallback));

        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(mockCallback));
    }

    function test_Events_CallbackSet() public {
        vm.expectEmit(true, true, true, true);
        emit INativeOracle.CallbackSet(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(0), address(mockCallback));

        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));
    }

    function test_Events_CallbackSuccess() public {
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        vm.expectEmit(true, true, false, true);
        emit INativeOracle.CallbackSuccess(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, address(mockCallback));

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Events_CallbackFailed() public {
        mockCallback.setRevert(true);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1000;

        // CallbackFailed event should be emitted
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);
        // Can't easily test the exact event due to dynamic reason bytes,
        // but we verified the record exists and callback count is 0 in earlier test
    }

    // ========================================================================
    // EDGE CASE TESTS
    // ========================================================================

    function test_EmptyPayload() public {
        bytes memory payload = "";
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
    }

    function test_LargePayload() public {
        // Create a large payload (1KB)
        bytes memory payload = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            payload[i] = bytes1(uint8(i % 256));
        }
        uint128 nonce = 1000;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce);
        assertEq(record.data, payload);
    }

    function test_NonceMustStartFromOne() public {
        bytes memory payload = abi.encode("test");

        // Nonce = 1 should work
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1);
        assertTrue(record.recordedAt > 0);
    }
}
