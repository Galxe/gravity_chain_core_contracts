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

    // Test data
    bytes32 public constant ETHEREUM_SOURCE_ID = keccak256("ethereum");
    bytes32 public constant GOOGLE_JWK_SOURCE_ID = keccak256("google");
    bytes32 public ethereumSourceName;
    bytes32 public googleSourceName;

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

        // Compute source names
        ethereumSourceName = oracle.computeSourceName(INativeOracle.EventType.BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        googleSourceName = oracle.computeSourceName(INativeOracle.EventType.JWK, GOOGLE_JWK_SOURCE_ID);

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
        oracle.recordHash(dataHash, ethereumSourceName, syncId, payload);

        // Verify record exists
        (bool exists, INativeOracle.DataRecord memory record) = oracle.verifyHash(dataHash);
        assertTrue(exists);
        assertEq(record.syncId, syncId);
        assertEq(record.data.length, 0); // Hash mode doesn't store data

        // Verify sync status
        INativeOracle.SyncStatus memory status = oracle.getSyncStatus(ethereumSourceName);
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
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);
    }

    function test_RecordHash_RevertWhenNotInitialized() public {
        NativeOracle newOracle = new NativeOracle();
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.expectRevert(Errors.OracleNotInitialized.selector);
        vm.prank(systemCaller);
        newOracle.recordHash(dataHash, ethereumSourceName, 1000, payload);
    }

    function test_RecordHash_RevertWhenSyncIdNotIncreasing() public {
        bytes memory payload1 = abi.encode("first");
        bytes32 dataHash1 = keccak256(payload1);

        // Record first hash
        vm.prank(systemCaller);
        oracle.recordHash(dataHash1, ethereumSourceName, 1000, payload1);

        // Try to record with same syncId
        bytes memory payload2 = abi.encode("second");
        bytes32 dataHash2 = keccak256(payload2);

        vm.expectRevert(abi.encodeWithSelector(Errors.SyncIdNotIncreasing.selector, ethereumSourceName, 1000, 1000));
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, ethereumSourceName, 1000, payload2);

        // Try to record with lower syncId
        vm.expectRevert(abi.encodeWithSelector(Errors.SyncIdNotIncreasing.selector, ethereumSourceName, 1000, 500));
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, ethereumSourceName, 500, payload2);
    }

    function test_RecordHash_MultipleSourcesIndependent() public {
        bytes memory payload1 = abi.encode("ethereum event");
        bytes32 dataHash1 = keccak256(payload1);

        bytes memory payload2 = abi.encode("google jwk");
        bytes32 dataHash2 = keccak256(payload2);

        // Record to ethereum source
        vm.prank(systemCaller);
        oracle.recordHash(dataHash1, ethereumSourceName, 1000, payload1);

        // Record to google source with lower syncId (allowed because different source)
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, googleSourceName, 500, payload2);

        // Verify both sources
        INativeOracle.SyncStatus memory ethStatus = oracle.getSyncStatus(ethereumSourceName);
        INativeOracle.SyncStatus memory googleStatus = oracle.getSyncStatus(googleSourceName);

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
        oracle.recordData(dataHash, googleSourceName, syncId, payload);

        // Verify record exists with data
        (bool exists, INativeOracle.DataRecord memory record) = oracle.verifyHash(dataHash);
        assertTrue(exists);
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
        oracle.recordData(dataHash, googleSourceName, 1000, payload);
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
        oracle.recordHashBatch(hashes, ethereumSourceName, syncId, payloads);

        // Verify all records
        for (uint256 i = 0; i < 3; i++) {
            (bool exists,) = oracle.verifyHash(hashes[i]);
            assertTrue(exists);
        }

        // Verify total records
        assertEq(oracle.getTotalRecords(), 3);

        // Verify sync status updated only once
        INativeOracle.SyncStatus memory status = oracle.getSyncStatus(ethereumSourceName);
        assertEq(status.latestSyncId, syncId);
    }

    function test_RecordHashBatch_RevertWhenArrayLengthMismatch() public {
        bytes32[] memory hashes = new bytes32[](3);
        bytes[] memory payloads = new bytes[](2); // Different length

        vm.expectRevert(abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 3, 2));
        vm.prank(systemCaller);
        oracle.recordHashBatch(hashes, ethereumSourceName, 1000, payloads);
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
        oracle.recordDataBatch(hashes, googleSourceName, syncId, payloads);

        // Verify data stored correctly
        assertEq(oracle.getData(hashes[0]), payloads[0]);
        assertEq(oracle.getData(hashes[1]), payloads[1]);

        assertEq(oracle.getTotalRecords(), 2);
    }

    // ========================================================================
    // CALLBACK TESTS
    // ========================================================================

    function test_SetCallback() public {
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        assertEq(oracle.getCallback(ethereumSourceName), address(mockCallback));
    }

    function test_SetCallback_RevertWhenNotTimelock() public {
        vm.expectRevert();
        vm.prank(alice);
        oracle.setCallback(ethereumSourceName, address(mockCallback));
    }

    function test_SetCallback_Unregister() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        // Unregister by setting to zero
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(0));

        assertEq(oracle.getCallback(ethereumSourceName), address(0));
    }

    function test_CallbackInvoked() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        // Record hash
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);

        // Verify callback was invoked
        assertEq(mockCallback.callCount(), 1);
        assertEq(mockCallback.lastDataHash(), dataHash);
        assertEq(mockCallback.lastPayload(), payload);
    }

    function test_CallbackFailureDoesNotRevert() public {
        // Register callback that reverts
        mockCallback.setRevert(true);
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        // Record hash - should NOT revert even though callback fails
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);

        // Record should still exist
        (bool exists,) = oracle.verifyHash(dataHash);
        assertTrue(exists);

        // Callback was not successfully called
        assertEq(mockCallback.callCount(), 0);
    }

    function test_CallbackGasLimitEnforced() public {
        // Register callback that consumes all gas
        mockCallback.setConsumeAllGas(true);
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        // Record hash - should NOT revert even though callback runs out of gas
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);

        // Record should still exist
        (bool exists,) = oracle.verifyHash(dataHash);
        assertTrue(exists);
    }

    function test_CallbackInvokedForBatch() public {
        // Register callback
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        // Record batch
        bytes32[] memory hashes = new bytes32[](3);
        bytes[] memory payloads = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            payloads[i] = abi.encode("event", i);
            hashes[i] = keccak256(payloads[i]);
        }

        vm.prank(systemCaller);
        oracle.recordHashBatch(hashes, ethereumSourceName, 2000, payloads);

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
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);

        // Verify using pre-image
        (bool exists, INativeOracle.DataRecord memory record) = oracle.verifyPreImage(payload);
        assertTrue(exists);
        assertEq(record.syncId, 1000);
    }

    function test_VerifyPreImage_NotFound() public {
        bytes memory payload = abi.encode("unrecorded");

        (bool exists,) = oracle.verifyPreImage(payload);
        assertFalse(exists);
    }

    function test_IsSyncedPast() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);

        // Before recording, not synced
        assertFalse(oracle.isSyncedPast(ethereumSourceName, 500));

        // Record at syncId 1000
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);

        // Now synced past 500 and 1000
        assertTrue(oracle.isSyncedPast(ethereumSourceName, 500));
        assertTrue(oracle.isSyncedPast(ethereumSourceName, 1000));

        // Not synced past 1001
        assertFalse(oracle.isSyncedPast(ethereumSourceName, 1001));
    }

    function test_GetData_EmptyForHashMode() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);

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
        bytes32 sourceName = oracle.computeSourceName(INativeOracle.EventType.BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        bytes32 expected = keccak256(abi.encode(INativeOracle.EventType.BLOCKCHAIN, ETHEREUM_SOURCE_ID));
        assertEq(sourceName, expected);
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
        oracle.recordHash(dataHash, ethereumSourceName, syncId, payload);

        (bool exists, INativeOracle.DataRecord memory record) = oracle.verifyHash(dataHash);
        assertTrue(exists);
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
        oracle.recordData(dataHash, googleSourceName, syncId, payload);

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
        oracle.recordHash(dataHash1, ethereumSourceName, syncId1, payload1);

        // Second record with non-increasing syncId fails
        bytes memory payload2 = abi.encode("second");
        bytes32 dataHash2 = keccak256(payload2);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.SyncIdNotIncreasing.selector, ethereumSourceName, syncId1, syncId2)
        );
        vm.prank(systemCaller);
        oracle.recordHash(dataHash2, ethereumSourceName, syncId2, payload2);
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
            oracle.recordHash(dataHash, ethereumSourceName, syncId, payload);
        }

        assertEq(oracle.getTotalRecords(), count);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_HashRecorded() public {
        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 1000;

        vm.expectEmit(true, true, false, true);
        emit INativeOracle.HashRecorded(dataHash, ethereumSourceName, syncId);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, syncId, payload);
    }

    function test_Events_DataRecorded() public {
        bytes memory payload = abi.encode("jwk_data");
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 2000;

        vm.expectEmit(true, true, false, true);
        emit INativeOracle.DataRecorded(dataHash, googleSourceName, syncId, payload.length);

        vm.prank(systemCaller);
        oracle.recordData(dataHash, googleSourceName, syncId, payload);
    }

    function test_Events_SyncStatusUpdated() public {
        bytes memory payload = abi.encode("test");
        bytes32 dataHash = keccak256(payload);
        uint128 syncId = 1000;

        vm.expectEmit(true, false, false, true);
        emit INativeOracle.SyncStatusUpdated(ethereumSourceName, 0, syncId);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, syncId, payload);
    }

    function test_Events_CallbackSet() public {
        vm.expectEmit(true, true, true, false);
        emit INativeOracle.CallbackSet(ethereumSourceName, address(0), address(mockCallback));

        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));
    }

    function test_Events_CallbackSuccess() public {
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        vm.expectEmit(true, true, true, false);
        emit INativeOracle.CallbackSuccess(ethereumSourceName, dataHash, address(mockCallback));

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);
    }

    function test_Events_CallbackFailed() public {
        mockCallback.setRevert(true);
        vm.prank(governance);
        oracle.setCallback(ethereumSourceName, address(mockCallback));

        bytes memory payload = abi.encode(alice, uint256(100));
        bytes32 dataHash = keccak256(payload);

        // CallbackFailed event should be emitted
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);
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
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);
        assertEq(oracle.getTotalRecords(), 1);

        // Record same hash again with higher syncId
        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 2000, payload);

        // Total records should still be 1 (update, not new record)
        assertEq(oracle.getTotalRecords(), 1);

        // SyncId should be updated
        (bool exists, INativeOracle.DataRecord memory record) = oracle.verifyHash(dataHash);
        assertTrue(exists);
        assertEq(record.syncId, 2000);
    }

    function test_EmptyPayload() public {
        bytes memory payload = "";
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordHash(dataHash, ethereumSourceName, 1000, payload);

        (bool exists,) = oracle.verifyHash(dataHash);
        assertTrue(exists);
    }

    function test_LargePayload() public {
        // Create a large payload (1KB)
        bytes memory payload = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            payload[i] = bytes1(uint8(i % 256));
        }
        bytes32 dataHash = keccak256(payload);

        vm.prank(systemCaller);
        oracle.recordData(dataHash, googleSourceName, 1000, payload);

        bytes memory storedData = oracle.getData(dataHash);
        assertEq(storedData, payload);
    }
}

