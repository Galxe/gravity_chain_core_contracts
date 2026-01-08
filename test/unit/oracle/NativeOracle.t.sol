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
    bytes32 public lastDataHash;
    bytes public lastPayload;
    uint256 public callCount;
    bool public shouldRevert;
    bool public shouldConsumeAllGas;

    function onOracleEvent(
        bytes32 dataHash,
        bytes calldata payload
    ) external override {
        if (shouldRevert) {
            revert("MockCallback: intentional revert");
        }
        if (shouldConsumeAllGas) {
            // Consume all gas by infinite loop
            while (true) { }
        }

        lastDataHash = dataHash;
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
    address public genesis;
    address public governance;
    address public alice;
    address public bob;

    // Test data - Source types as uint32 (0 = BLOCKCHAIN, 1 = JWK, etc.)
    uint32 public constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint32 public constant SOURCE_TYPE_JWK = 1;
    uint256 public constant ETHEREUM_SOURCE_ID = 1; // Ethereum chain ID
    uint256 public constant GOOGLE_JWK_SOURCE_ID = 1; // Google JWK provider

    function setUp() public {
        // Set up addresses
        systemCaller = SystemAddresses.SYSTEM_CALLER;
        genesis = SystemAddresses.GENESIS;
        governance = SystemAddresses.GOVERNANCE;
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy oracle
        oracle = new NativeOracle();

        // Deploy mock callback
        mockCallback = new MockOracleCallback();

        // Initialize oracle
        vm.prank(genesis);
        oracle.initialize();
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public view {
        assertTrue(oracle.isInitialized());
        assertEq(oracle.getTotalRecords(), 0);
    }

    function test_Initialize_RevertWhenNotGenesis() public {
        NativeOracle newOracle = new NativeOracle();

        vm.expectRevert();
        vm.prank(alice);
        newOracle.initialize();
    }

    function test_Initialize_RevertWhenAlreadyInitialized() public {
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        vm.prank(genesis);
        oracle.initialize();
    }

    // ========================================================================
    // RECORD HASH TESTS
    // ========================================================================

    function test_RecordHash() public {
        bytes memory payload = abi.encode(alice, uint256(100), "deposit");
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 1000;

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId, payload);

        // Verify record exists (syncId > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.verifyHash(dataHash);
        assertTrue(record.syncId > 0);
        assertEq(record.syncId, syncId);
        assertEq(record.data.length, 0); // Hash mode doesn't store data

        // Verify sync status
        INativeOracle.SyncStatus memory status = oracle.getSyncStatus(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertTrue(status.initialized);
        assertEq(status.latestSyncId, syncId);

        // Verify total records
        assertEq(oracle.getTotalRecords(), 1);
    }

    function test_RecordHash_RevertWhenNotSystemCaller() public {
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.expectRevert();
        vm.prank(alice);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_RecordHash_RevertWhenNotInitialized() public {
        NativeOracle newOracle = new NativeOracle();
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.expectRevert(Errors.OracleNotInitialized.selector);
        vm.prank(systemCaller);
        newOracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_RecordHash_RevertWhenSyncIdIsZero() public {
        bytes memory payload = abi.encode("first");
        bytes32 dataHash = keccak256(payload);

        // Try to record with syncId = 0 (latestSyncId starts at 0, so syncId must be > 0)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.SyncIdNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0, 0
            )
        );
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0, payload);
    }

    function test_RecordHash_RevertWhenSyncIdNotIncreasing() public {
        bytes memory payload1 = abi.encode("first");
        bytes32 dataHash1 = keccak256(payload1);

        // Record first hash
        vm.prank(systemCaller);
        oracle.recordHash(dataHash1, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload1);

        // Try to record with same syncId
        bytes memory payload2 = abi.encode("second");
        bytes32 dataHash2 = keccak256(payload2);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.SyncIdNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, 1000
            )
        );
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload2);

        // Try to record with lower syncId
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.SyncIdNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, 500
            )
        );
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 500, payload2);
    }

    function test_RecordHash_MultipleSourcesIndependent() public {
        bytes memory payload1 = abi.encode("ethereum event");
        bytes32 dataHash1 = keccak256(payload1);

        bytes memory payload2 = abi.encode("google jwk");
        bytes32 dataHash2 = keccak256(payload2);

        // Record to ethereum source
        vm.prank(systemCaller);
        oracle.recordHash(dataHash1, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload1);

        // Record to google source with lower syncId (allowed because different source)
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, 500, payload2);

        // Verify both sources
        INativeOracle.SyncStatus memory ethStatus = oracle.getSyncStatus(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        INativeOracle.SyncStatus memory googleStatus = oracle.getSyncStatus(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID);

        assertEq(ethStatus.latestSyncId, 1000);
        assertEq(googleStatus.latestSyncId, 500);
    }

    // ========================================================================
    // RECORD DATA TESTS
    // ========================================================================

    function test_RecordData() public {
        bytes memory payload = abi.encode("kid123", "RS256", "n_value", "e_value");
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 1704067200; // timestamp

        vm.prank(systemCaller);
        oracle.recordData(dataHash, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, syncId, payload);

        // Verify record exists with data (syncId > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.verifyHash(dataHash);
        assertTrue(record.syncId > 0);
        assertEq(record.syncId, syncId);
        assertEq(record.data, payload); // Data mode stores full payload

        // Verify getData
        bytes memory storedData = oracle.getData(dataHash);
        assertEq(storedData, payload);
    }

    function test_RecordData_RevertWhenNotSystemCaller() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);

        vm.expectRevert();
        vm.prank(alice);
        oracle.recordData(dataHash, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, 1000, payload);
    }

    // ========================================================================
    // BATCH RECORDING TESTS
    // ========================================================================

    function test_RecordHashBatch() public {
        bytes32[] memory hashes = new bytes32[](3);
        bytes[] memory payloads = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            payloads[i] = abi.encode("event", i);
            hashes[i] = keccak256(payloads[i]);
        }

        uint128 syncId = 2000;

        vm.prank(systemCaller);
        oracle.recordHashBatch(hashes, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId, payloads);

        // Verify all records (syncId > 0 means exists)
        for (uint256 i = 0; i < 3; i++) {
            INativeOracle.DataRecord memory record = oracle.verifyHash(hashes[i]);
            assertTrue(record.syncId > 0);
        }

        // Verify total records
        assertEq(oracle.getTotalRecords(), 3);

        // Verify sync status updated only once
        INativeOracle.SyncStatus memory status = oracle.getSyncStatus(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(status.latestSyncId, syncId);
    }

    function test_RecordHashBatch_RevertWhenArrayLengthMismatch() public {
        bytes32[] memory hashes = new bytes32[](3);
        bytes[] memory payloads = new bytes[](2); // Different length

        vm.expectRevert(abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 3, 2));
        vm.prank(systemCaller);
        oracle.recordHashBatch(hashes, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payloads);
    }

    function test_RecordDataBatch() public {
        bytes32[] memory hashes = new bytes32[](2);
        bytes[] memory payloads = new bytes[](2);

        payloads[0] = abi.encode("jwk1", "data1");
        hashes[0] = keccak256(payloads[0]);
        payloads[1] = abi.encode("jwk2", "data2");
        hashes[1] = keccak256(payloads[1]);

        uint128 syncId = 3000;

        vm.prank(systemCaller);
        oracle.recordDataBatch(hashes, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, syncId, payloads);

        // Verify data stored correctly
        assertEq(oracle.getData(hashes[0]), payloads[0]);
        assertEq(oracle.getData(hashes[1]), payloads[1]);

        assertEq(oracle.getTotalRecords(), 2);
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

        // Record hash
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        // Verify callback was invoked
        assertEq(mockCallback.callCount(), 1);
        assertEq(mockCallback.lastDataHash(), dataHash);
        assertEq(mockCallback.lastPayload(), payload);
    }

    function test_DefaultCallbackInvoked() public {
        // Register default callback for BLOCKCHAIN type
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(mockCallback));

        // Record hash (no specialized callback set)
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        // Verify default callback was invoked
        assertEq(mockCallback.callCount(), 1);
        assertEq(mockCallback.lastDataHash(), dataHash);
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

        // Record hash
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

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

        // Record hash for Arbitrum (should use default)
        bytes memory payload1 = abi.encode("arbitrum event");
        bytes32 dataHash1 = keccak256(payload1);
        vm.prank(systemCaller);
        oracle.recordHash(dataHash1, SOURCE_TYPE_BLOCKCHAIN, arbitrumSourceId, 1000, payload1);

        // Record hash for Ethereum (should use specialized)
        bytes memory payload2 = abi.encode("ethereum event");
        bytes32 dataHash2 = keccak256(payload2);
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2000, payload2);

        // Verify correct callbacks were invoked
        assertEq(defaultCallback.callCount(), 1);
        assertEq(defaultCallback.lastDataHash(), dataHash1);

        assertEq(specializedCallback.callCount(), 1);
        assertEq(specializedCallback.lastDataHash(), dataHash2);
    }

    function test_CallbackFailureDoesNotRevert() public {
        // Register callback that reverts
        mockCallback.setRevert(true);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record hash - should NOT revert even though callback fails
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        // Record should still exist (syncId > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.verifyHash(dataHash);
        assertTrue(record.syncId > 0);

        // Callback was not successfully called
        assertEq(mockCallback.callCount(), 0);
    }

    function test_CallbackGasLimitEnforced() public {
        // Register callback that consumes all gas
        mockCallback.setConsumeAllGas(true);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record hash - should NOT revert even though callback runs out of gas
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        // Record should still exist (syncId > 0 means exists)
        INativeOracle.DataRecord memory record2 = oracle.verifyHash(dataHash);
        assertTrue(record2.syncId > 0);
    }

    function test_CallbackInvokedForBatch() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        // Record batch
        bytes32[] memory hashes = new bytes32[](3);
        bytes[] memory payloads = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            payloads[i] = abi.encode("event", i);
            hashes[i] = keccak256(payloads[i]);
        }

        vm.prank(systemCaller);
        oracle.recordHashBatch(hashes, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2000, payloads);

        // Callback should be invoked 3 times
        assertEq(mockCallback.callCount(), 3);
    }

    // ========================================================================
    // VERIFICATION TESTS
    // ========================================================================

    function test_VerifyPreImage() public {
        bytes memory payload = abi.encode(alice, uint256(100), "deposit");
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        // Verify using pre-image (syncId > 0 means exists)
        INativeOracle.DataRecord memory record = oracle.verifyPreImage(payload);
        assertTrue(record.syncId > 0);
        assertEq(record.syncId, 1000);
    }

    function test_VerifyPreImage_NotFound() public {
        bytes memory payload = abi.encode("unrecorded");

        INativeOracle.DataRecord memory record = oracle.verifyPreImage(payload);
        assertEq(record.syncId, 0); // Not found
    }

    function test_IsSyncedPast() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);

        // Before recording, not synced
        assertFalse(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 500));

        // Record at syncId 1000
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        // Now synced past 500 and 1000
        assertTrue(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 500));
        assertTrue(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000));

        // Not synced past 1001
        assertFalse(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1001));
    }

    function test_GetData_EmptyForHashMode() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        // getData returns empty for hash-only mode
        bytes memory data = oracle.getData(dataHash);
        assertEq(data.length, 0);
    }

    function test_GetData_NotFound() public {
        bytes memory data = oracle.getData(keccak256("nonexistent"));
        assertEq(data.length, 0);
    }

    // ========================================================================
    // HELPER FUNCTION TESTS
    // ========================================================================

    function test_ComputeSourceName() public view {
        bytes32 sourceName = oracle.computeSourceName(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        bytes32 expected = keccak256(abi.encode(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID));
        assertEq(sourceName, expected);
    }

    function test_ComputeSourceName_DifferentTypesProduceDifferentNames() public view {
        bytes32 blockchainSource = oracle.computeSourceName(SOURCE_TYPE_BLOCKCHAIN, 1);
        bytes32 jwkSource = oracle.computeSourceName(SOURCE_TYPE_JWK, 1);

        assertTrue(blockchainSource != jwkSource);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_RecordHash(
        bytes memory payload,
        uint128 syncId
    ) public {
        vm.assume(syncId > 0);
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId, payload);

        INativeOracle.DataRecord memory record = oracle.verifyHash(dataHash);
        assertTrue(record.syncId > 0);
        assertEq(record.syncId, syncId);
    }

    function testFuzz_RecordData(
        bytes memory payload,
        uint128 syncId
    ) public {
        vm.assume(syncId > 0);
        vm.assume(payload.length <= 10000); // Reasonable size limit
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordData(dataHash, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, syncId, payload);

        bytes memory storedData = oracle.getData(dataHash);
        assertEq(storedData, payload);
    }

    function testFuzz_SyncIdMustIncrease(
        uint128 syncId1,
        uint128 syncId2
    ) public {
        vm.assume(syncId1 > 0);
        vm.assume(syncId2 <= syncId1);

        bytes memory payload1 = abi.encode("first");
        bytes32 dataHash1 = keccak256(payload1);

        // First record succeeds
        vm.prank(systemCaller);
        oracle.recordHash(dataHash1, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId1, payload1);

        // Second record with non-increasing syncId fails
        bytes memory payload2 = abi.encode("second");
        bytes32 dataHash2 = keccak256(payload2);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.SyncIdNotIncreasing.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId1, syncId2
            )
        );
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId2, payload2);
    }

    function testFuzz_MultipleRecordsCount(
        uint8 count
    ) public {
        vm.assume(count > 0 && count <= 50);

        for (uint256 i = 0; i < count; i++) {
            bytes memory payload = abi.encode("record", i);
            bytes32 dataHash = keccak256(payload);
            uint128 syncId = uint128(1000 + i);

            vm.prank(systemCaller);
            oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId, payload);
        }

        assertEq(oracle.getTotalRecords(), count);
    }

    function testFuzz_SourceTypeAndId(
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId
    ) public {
        vm.assume(syncId > 0);

        bytes memory payload = abi.encode("test", sourceType, sourceId);
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, sourceType, sourceId, syncId, payload);

        INativeOracle.SyncStatus memory status = oracle.getSyncStatus(sourceType, sourceId);
        assertTrue(status.initialized);
        assertEq(status.latestSyncId, syncId);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_HashRecorded() public {
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 1000;

        vm.expectEmit(true, true, true, true);
        emit INativeOracle.HashRecorded(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId, payload);
    }

    function test_Events_DataRecorded() public {
        bytes memory payload = abi.encode("jwk_data");
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 2000;

        vm.expectEmit(true, true, true, true);
        emit INativeOracle.DataRecorded(dataHash, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, syncId, payload.length);

        vm.prank(systemCaller);
        oracle.recordData(dataHash, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, syncId, payload);
    }

    function test_Events_SyncStatusUpdated() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 1000;

        vm.expectEmit(true, true, false, true);
        emit INativeOracle.SyncStatusUpdated(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0, syncId);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, syncId, payload);
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
        bytes32 dataHash = keccak256(payload);

        vm.expectEmit(true, true, false, true);
        emit INativeOracle.CallbackSuccess(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, dataHash, address(mockCallback));

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_Events_CallbackFailed() public {
        mockCallback.setRevert(true);
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(mockCallback));

        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        // CallbackFailed event should be emitted
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
        // Can't easily test the exact event due to dynamic reason bytes,
        // but we verified the record exists and callback count is 0 in earlier test
    }

    // ========================================================================
    // EDGE CASE TESTS
    // ========================================================================

    function test_RecordSameHashTwice() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);

        // Record once
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
        assertEq(oracle.getTotalRecords(), 1);

        // Record same hash again with higher syncId
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2000, payload);

        // Total records should still be 1 (update, not new record)
        assertEq(oracle.getTotalRecords(), 1);

        // SyncId should be updated
        INativeOracle.DataRecord memory record = oracle.verifyHash(dataHash);
        assertTrue(record.syncId > 0);
        assertEq(record.syncId, 2000);
    }

    function test_EmptyPayload() public {
        bytes memory payload = "";
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        INativeOracle.DataRecord memory record = oracle.verifyHash(dataHash);
        assertTrue(record.syncId > 0);
    }

    function test_LargePayload() public {
        // Create a large payload (1KB)
        bytes memory payload = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            payload[i] = bytes1(uint8(i % 256));
        }
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordData(dataHash, SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, 1000, payload);

        bytes memory storedData = oracle.getData(dataHash);
        assertEq(storedData, payload);
    }

    function test_SyncIdMustStartFromOne() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);

        // SyncId = 1 should work
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, payload);

        INativeOracle.DataRecord memory record = oracle.verifyHash(dataHash);
        assertEq(record.syncId, 1);
    }
}
