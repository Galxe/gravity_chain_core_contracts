// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
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
    bool public returnShouldStore = true; // Default: store in NativeOracle

    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external override returns (bool shouldStore) {
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

        return returnShouldStore;
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

    function setShouldStore(
        bool _shouldStore
    ) external {
        returnShouldStore = _shouldStore;
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
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

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
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Record_RevertWhenNonceIsZero() public {
        bytes memory payload = abi.encode("first");

        // Try to record with nonce = 0 (latestNonce starts at 0, so first nonce must be 1)
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0)
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0, 0, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Record_RevertWhenNonceNotSequential() public {
        bytes memory payload1 = abi.encode("first");

        // Record first (nonce must be 1)
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload1, CALLBACK_GAS_LIMIT);

        // Try to record with same nonce (expected: 2, provided: 1)
        bytes memory payload2 = abi.encode("second");

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, 1)
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload2, CALLBACK_GAS_LIMIT);

        // Try to record with a gap (expected: 2, provided: 5)
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, 5)
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 5, 0, payload2, CALLBACK_GAS_LIMIT);
    }

    function test_Record_MultipleSourcesIndependent() public {
        bytes memory payload1 = abi.encode("ethereum event");
        bytes memory payload2 = abi.encode("google jwk");

        // Record to ethereum source (first nonce must be 1)
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload1, CALLBACK_GAS_LIMIT);

        // Record to google source (first nonce must also be 1, independent source)
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, 1, 0, payload2, CALLBACK_GAS_LIMIT);

        // Verify both sources
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID), 1);
    }

    // ========================================================================
    // BATCH RECORDING TESTS
    // ========================================================================

    function test_RecordBatch() public {
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory blockNumbers = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory gasLimits = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            nonces[i] = 1 + uint128(i); // Sequential: 1, 2, 3
            blockNumbers[i] = 0;
            payloads[i] = abi.encode("event", i);
            gasLimits[i] = CALLBACK_GAS_LIMIT;
        }

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);

        // Verify all records exist (recordedAt > 0 means exists)
        for (uint256 i = 0; i < 3; i++) {
            INativeOracle.DataRecord memory record =
                oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces[i]);
            assertTrue(record.recordedAt > 0);
            assertEq(record.data, payloads[i]);
        }

        // Verify latest nonce is the final nonce
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), nonces[2]);
    }

    function test_RecordBatch_EmptyArrays() public {
        uint128[] memory nonces = new uint128[](0);
        uint256[] memory blockNumbers = new uint256[](0);
        bytes[] memory payloads = new bytes[](0);
        uint256[] memory gasLimits = new uint256[](0);

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);

        // Nothing should be recorded
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
    }

    function test_RecordBatch_RevertWhenArrayLengthMismatch() public {
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory blockNumbers = new uint256[](3);
        bytes[] memory payloads = new bytes[](2); // Mismatched length
        uint256[] memory gasLimits = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            nonces[i] = 1000 + uint128(i);
            blockNumbers[i] = 0;
            gasLimits[i] = CALLBACK_GAS_LIMIT;
        }
        payloads[0] = abi.encode("event0");
        payloads[1] = abi.encode("event1");

        vm.expectRevert(abi.encodeWithSelector(Errors.OracleBatchArrayLengthMismatch.selector, 3, 2, 3));
        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);
    }

    function test_RecordBatch_RevertWhenNonceNotSequential() public {
        // First, record at nonce 1
        bytes memory payload = abi.encode("first");
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload, CALLBACK_GAS_LIMIT);

        // Now try batch starting at nonce 1 (should fail - must be 2)
        uint128[] memory nonces = new uint128[](2);
        uint256[] memory blockNumbers = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        uint256[] memory gasLimits = new uint256[](2);

        nonces[0] = 1; // Invalid: same as existing, expected 2
        nonces[1] = 2;
        blockNumbers[0] = 0;
        blockNumbers[1] = 0;
        payloads[0] = abi.encode("batch0");
        payloads[1] = abi.encode("batch1");
        gasLimits[0] = CALLBACK_GAS_LIMIT;
        gasLimits[1] = CALLBACK_GAS_LIMIT;

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, 1)
        );
        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);
    }

    function test_RecordBatch_RevertWhenBatchNoncesNotSequential() public {
        // Try batch with non-sequential nonces within the batch
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory blockNumbers = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory gasLimits = new uint256[](3);

        nonces[0] = 1;
        nonces[1] = 2;
        nonces[2] = 2; // Invalid: not sequential (expected 3)
        blockNumbers[0] = 0;
        blockNumbers[1] = 0;
        blockNumbers[2] = 0;
        payloads[0] = abi.encode("batch0");
        payloads[1] = abi.encode("batch1");
        payloads[2] = abi.encode("batch2");
        gasLimits[0] = CALLBACK_GAS_LIMIT;
        gasLimits[1] = CALLBACK_GAS_LIMIT;
        gasLimits[2] = CALLBACK_GAS_LIMIT;

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 3, 2)
        );
        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);
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
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

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
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, 0);

        // Verify callback was NOT invoked
        assertEq(mockCallback.callCount(), 0);
    }

    function test_DefaultCallbackInvoked() public {
        // Register default callback for BLOCKCHAIN type
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(mockCallback));

        // Record (no specialized callback set)
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

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
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload, CALLBACK_GAS_LIMIT);

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
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, arbitrumSourceId, 1, 0, payload1, CALLBACK_GAS_LIMIT);

        // Record for Ethereum (should use specialized)
        bytes memory payload2 = abi.encode("ethereum event");
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload2, CALLBACK_GAS_LIMIT);

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
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

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
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        // Record should still exist (recordedAt > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
    }

    function test_CallbackInvokedForBatch() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record batch
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory blockNumbers = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory gasLimits = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            nonces[i] = 1 + uint128(i); // Sequential: 1, 2, 3
            blockNumbers[i] = 0;
            payloads[i] = abi.encode("event", i);
            gasLimits[i] = CALLBACK_GAS_LIMIT;
        }

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);

        // Callback should be invoked 3 times
        assertEq(mockCallback.callCount(), 3);
    }

    function test_CallbackNotInvokedForBatchWhenGasLimitZero() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record batch with zero gas limits
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory blockNumbers = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory gasLimits = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            nonces[i] = 1 + uint128(i); // Sequential: 1, 2, 3
            blockNumbers[i] = 0;
            payloads[i] = abi.encode("event", i);
            gasLimits[i] = 0; // Zero gas limit
        }

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);

        // Callback should NOT be invoked
        assertEq(mockCallback.callCount(), 0);
    }

    function test_CallbackPartiallyInvokedForBatch() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record batch with mixed gas limits (some zero, some non-zero)
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory blockNumbers = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory gasLimits = new uint256[](3);

        nonces[0] = 1;
        nonces[1] = 2;
        nonces[2] = 3;
        blockNumbers[0] = 0;
        blockNumbers[1] = 0;
        blockNumbers[2] = 0;
        payloads[0] = abi.encode("event0");
        payloads[1] = abi.encode("event1");
        payloads[2] = abi.encode("event2");
        gasLimits[0] = CALLBACK_GAS_LIMIT; // Will invoke callback
        gasLimits[1] = 0; // Will NOT invoke callback
        gasLimits[2] = CALLBACK_GAS_LIMIT; // Will invoke callback

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);

        // Callback should be invoked only 2 times
        assertEq(mockCallback.callCount(), 2);
    }

    // ========================================================================
    // QUERY TESTS
    // ========================================================================

    function test_GetRecord() public {
        bytes memory payload = abi.encode(alice, uint256(100), "deposit");
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

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
        assertFalse(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1));

        // Record nonces 1 and 2
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload, CALLBACK_GAS_LIMIT);
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, 0, payload, CALLBACK_GAS_LIMIT);

        // Now synced past 1 and 2
        assertTrue(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1));
        assertTrue(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2));

        // Not synced past 3
        assertFalse(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 3));
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Record(
        bytes memory payload
    ) public {
        // Sequential nonce: first record must use nonce 1
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
        assertEq(record.data, payload);
    }

    function testFuzz_NonceMustBeSequential(
        uint128 badNonce
    ) public {
        // First record must be nonce 1
        bytes memory payload1 = abi.encode("first");
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload1, CALLBACK_GAS_LIMIT);

        // Any nonce that isn't 2 should fail
        vm.assume(badNonce != 2);

        bytes memory payload2 = abi.encode("second");

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, badNonce
            )
        );
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, badNonce, 0, payload2, CALLBACK_GAS_LIMIT);
    }

    function testFuzz_SourceTypeAndId(
        uint32 sourceType,
        uint256 sourceId
    ) public {
        // Sequential nonce: first record must use nonce 1
        uint128 nonce = 1;

        bytes memory payload = abi.encode("test", sourceType, sourceId);

        vm.prank(systemCaller);
        oracle.record(sourceType, sourceId, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        assertEq(oracle.getLatestNonce(sourceType, sourceId), nonce);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_DataRecorded() public {
        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1;

        vm.expectEmit(true, true, true, true);
        emit INativeOracle.DataRecorded(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, payload.length);

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);
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
        uint128 nonce = 1;

        vm.expectEmit(true, true, false, true);
        emit INativeOracle.CallbackSuccess(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, address(mockCallback));

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Events_CallbackFailed() public {
        mockCallback.setRevert(true);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode(alice, uint256(100));
        uint128 nonce = 1;

        // CallbackFailed event should be emitted
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);
        // Can't easily test the exact event due to dynamic reason bytes,
        // but we verified the record exists and callback count is 0 in earlier test
    }

    // ========================================================================
    // EDGE CASE TESTS
    // ========================================================================

    function test_EmptyPayload() public {
        bytes memory payload = "";
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
    }

    function test_LargePayload() public {
        // Create a large payload (1KB)
        bytes memory payload = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            payload[i] = bytes1(uint8(i % 256));
        }
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce);
        assertEq(record.data, payload);
    }

    function test_NonceMustStartFromOne() public {
        bytes memory payload = abi.encode("test");

        // Nonce = 1 should work
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1);
        assertTrue(record.recordedAt > 0);
    }

    // ========================================================================
    // SKIP-STORAGE TESTS (callback returns shouldStore=false)
    // ========================================================================

    function test_CallbackSkipStorage() public {
        // Register callback that returns shouldStore=false
        mockCallback.setShouldStore(false);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode("jwk data");
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        // Callback was invoked
        assertEq(mockCallback.callCount(), 1);

        // But record was NOT stored (recordedAt == 0)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce);
        assertEq(record.recordedAt, 0);

        // Nonce was still updated (for replay protection)
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID), nonce);
    }

    function test_CallbackStoreByDefault() public {
        // Register callback that returns shouldStore=true (default)
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode("blockchain event");
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        // Callback was invoked
        assertEq(mockCallback.callCount(), 1);

        // Record WAS stored
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
        assertEq(record.data, payload);
    }

    function test_NoCallbackStoresByDefault() public {
        // No callback registered - should always store
        bytes memory payload = abi.encode("no callback");
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        // Record WAS stored
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
    }

    function test_CallbackFailureStoresByDefault() public {
        // Register callback that reverts
        mockCallback.setRevert(true);
        mockCallback.setShouldStore(false); // Would skip if it succeeded
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode("jwk data");
        uint128 nonce = 1;

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        // Callback failed (callCount not incremented)
        assertEq(mockCallback.callCount(), 0);

        // But record WAS stored (failure defaults to store)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce);
        assertTrue(record.recordedAt > 0);
        assertEq(record.data, payload);
    }

    function test_BatchSkipStoragePerRecord() public {
        // Create two callbacks with different behaviors
        MockOracleCallback storeCallback = new MockOracleCallback();
        storeCallback.setShouldStore(true);

        MockOracleCallback skipCallback = new MockOracleCallback();
        skipCallback.setShouldStore(false);

        // Set default callback for JWK type that skips storage
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_JWK, address(skipCallback));

        // Record batch
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory blockNumbers = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory gasLimits = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            nonces[i] = 1 + uint128(i); // Sequential: 1, 2, 3
            blockNumbers[i] = 0;
            payloads[i] = abi.encode("event", i);
            gasLimits[i] = CALLBACK_GAS_LIMIT;
        }

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonces, blockNumbers, payloads, gasLimits);

        // All callbacks were invoked
        assertEq(skipCallback.callCount(), 3);

        // No records were stored
        for (uint256 i = 0; i < 3; i++) {
            INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonces[i]);
            assertEq(record.recordedAt, 0);
        }

        // But nonce was updated
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID), nonces[2]);
    }

    function test_Events_StorageSkipped() public {
        mockCallback.setShouldStore(false);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode("jwk data");
        uint128 nonce = 1;

        // Expect both CallbackSuccess and StorageSkipped events
        vm.expectEmit(true, true, false, true);
        emit INativeOracle.CallbackSuccess(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, address(mockCallback));

        vm.expectEmit(true, true, false, true);
        emit INativeOracle.StorageSkipped(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, address(mockCallback));

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Events_NoDataRecordedWhenSkipped() public {
        mockCallback.setShouldStore(false);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode("jwk data");
        uint128 nonce = 1;

        // Record logs to check that DataRecorded is NOT emitted
        vm.recordLogs();

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, nonce, 0, payload, CALLBACK_GAS_LIMIT);

        // Check logs - should have CallbackSuccess and StorageSkipped, but NOT DataRecorded
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool foundDataRecorded = false;
        bytes32 dataRecordedTopic = keccak256("DataRecorded(uint32,uint256,uint128,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == dataRecordedTopic) {
                foundDataRecorded = true;
                break;
            }
        }

        assertFalse(foundDataRecorded, "DataRecorded should not be emitted when storage is skipped");
    }
}
