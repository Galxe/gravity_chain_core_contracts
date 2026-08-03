// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle, IOracleCallback } from "../../../src/oracle/INativeOracle.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";

contract MockOracleCallback is IOracleCallback {
    uint32 public lastSourceType;
    uint256 public lastSourceId;
    uint128 public lastNonce;
    bytes public lastPayload;
    uint256 public callCount;
    bool public shouldRevert;
    bool public returnValue = true;

    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external override returns (bool) {
        if (shouldRevert) revert("intentional callback failure");

        lastSourceType = sourceType;
        lastSourceId = sourceId;
        lastNonce = nonce;
        lastPayload = payload;
        ++callCount;
        return returnValue;
    }

    function setRevert(
        bool value
    ) external {
        shouldRevert = value;
    }

    function setReturnValue(
        bool value
    ) external {
        returnValue = value;
    }
}

contract MalformedReturnCallback {
    uint256 private immutable _returnWord;
    uint256 private immutable _returnSize;

    constructor(
        uint256 returnWord,
        uint256 returnSize
    ) {
        _returnWord = returnWord;
        _returnSize = returnSize;
    }

    fallback() external {
        uint256 returnWord = _returnWord;
        uint256 returnSize = _returnSize;
        assembly ("memory-safe") {
            mstore(0, returnWord)
            return(0, returnSize)
        }
    }
}

contract NativeOracleTest is Test {
    NativeOracle internal oracle;
    MockOracleCallback internal callback;

    uint32 internal constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint32 internal constant SOURCE_TYPE_JWK = 1;
    uint256 internal constant ETHEREUM_SOURCE_ID = 1;
    uint256 internal constant GOOGLE_JWK_SOURCE_ID = 2;
    uint256 internal constant CALLBACK_GAS_LIMIT = 500_000;

    address internal systemCaller = SystemAddresses.SYSTEM_CALLER;
    address internal governance = SystemAddresses.GOVERNANCE;
    address internal alice = makeAddr("alice");

    function setUp() public {
        oracle = new NativeOracle();
        callback = new MockOracleCallback();

        vm.startPrank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(callback));
        oracle.setDefaultCallback(SOURCE_TYPE_JWK, address(callback));
        vm.stopPrank();
    }

    function test_RecordStoresOnlyLatestProgress() public {
        bytes memory payload = abi.encode(alice, uint256(100), "deposit");

        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 19_876_543, payload, CALLBACK_GAS_LIMIT);

        INativeOracle.SourceProgress memory progress =
            oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(progress.latestNonce, 1);
        assertEq(progress.latestPosition, 19_876_543);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);
        assertTrue(oracle.isSyncedPast(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1));

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1);
        assertEq(record.recordedAt, 0);
        assertEq(record.blockNumber, 0);
        assertEq(record.data.length, 0);

        assertEq(callback.lastSourceType(), SOURCE_TYPE_BLOCKCHAIN);
        assertEq(callback.lastSourceId(), ETHEREUM_SOURCE_ID);
        assertEq(callback.lastNonce(), 1);
        assertEq(callback.lastPayload(), payload);
    }

    function test_RecordOverwritesOneProgressSlot() public {
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, 110, hex"02", CALLBACK_GAS_LIMIT);

        INativeOracle.SourceProgress memory progress =
            oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(progress.latestNonce, 2);
        assertEq(progress.latestPosition, 110);
        assertEq(oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1).recordedAt, 0);
        assertEq(oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2).recordedAt, 0);
    }

    function test_RecordMultipleSourcesRemainIndependent() public {
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 101, hex"01", CALLBACK_GAS_LIMIT);
        _record(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID, 1, 202, hex"02", CALLBACK_GAS_LIMIT);

        INativeOracle.SourceProgress memory blockchain =
            oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        INativeOracle.SourceProgress memory jwk = oracle.getSourceProgress(SOURCE_TYPE_JWK, GOOGLE_JWK_SOURCE_ID);
        assertEq(blockchain.latestNonce, 1);
        assertEq(blockchain.latestPosition, 101);
        assertEq(jwk.latestNonce, 1);
        assertEq(jwk.latestPosition, 202);
    }

    function test_RecordBatchAdvancesToFinalProgressWithoutHistory() public {
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory positions = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory gasLimits = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            nonces[i] = uint128(i + 1);
            positions[i] = 1_000 + i;
            payloads[i] = abi.encode(i);
            gasLimits[i] = CALLBACK_GAS_LIMIT;
        }

        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, positions, payloads, gasLimits);

        INativeOracle.SourceProgress memory progress =
            oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(progress.latestNonce, 3);
        assertEq(progress.latestPosition, 1_002);
        assertEq(callback.callCount(), 3);
        for (uint128 nonce = 1; nonce <= 3; ++nonce) {
            assertEq(oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonce).recordedAt, 0);
        }
    }

    function test_RecordBatchIsAtomic() public {
        uint128[] memory nonces = new uint128[](2);
        nonces[0] = 1;
        nonces[1] = 3;
        uint256[] memory positions = new uint256[](2);
        positions[0] = 100;
        positions[1] = 300;
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = hex"01";
        payloads[1] = hex"03";
        uint256[] memory gasLimits = new uint256[](2);
        gasLimits[0] = CALLBACK_GAS_LIMIT;
        gasLimits[1] = CALLBACK_GAS_LIMIT;

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, 3)
        );
        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, positions, payloads, gasLimits);

        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
        assertEq(callback.callCount(), 0);
    }

    function test_RecordBatchRejectsMismatchedLengths() public {
        uint128[] memory nonces = new uint128[](1);
        uint256[] memory positions = new uint256[](0);
        bytes[] memory payloads = new bytes[](1);
        uint256[] memory gasLimits = new uint256[](1);

        vm.expectRevert(abi.encodeWithSelector(Errors.OracleBatchArrayLengthMismatch.selector, 1, 0, 1, 1));
        vm.prank(systemCaller);
        oracle.recordBatch(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, nonces, positions, payloads, gasLimits);
    }

    function test_RecordBatchAllowsEmptyBatch() public {
        vm.prank(systemCaller);
        oracle.recordBatch(
            SOURCE_TYPE_BLOCKCHAIN,
            ETHEREUM_SOURCE_ID,
            new uint128[](0),
            new uint256[](0),
            new bytes[](0),
            new uint256[](0)
        );
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
    }

    function test_RecordRevertsWhenNotSystemCaller() public {
        vm.expectRevert();
        vm.prank(alice);
        oracle.record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);
    }

    function test_RecordRequiresSequentialNonce() public {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 0)
        );
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0, 100, hex"00", CALLBACK_GAS_LIMIT);

        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NonceNotSequential.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 2, 3)
        );
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 3, 300, hex"03", CALLBACK_GAS_LIMIT);
    }

    function test_RecordRejectsPositionOverflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleSourcePositionOverflow.selector, uint256(type(uint128).max) + 1)
        );
        _record(
            SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, uint256(type(uint128).max) + 1, hex"01", CALLBACK_GAS_LIMIT
        );
    }

    function test_MissingCallbackRevertsWithoutAdvancing() public {
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.OracleCallbackNotConfigured.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID
            )
        );
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
    }

    function test_ZeroCallbackGasRevertsWithoutAdvancing() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.OracleCallbackGasLimitZero.selector, SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID
            )
        );
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", 0);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
    }

    function test_CallbackRevertIsAtomic() public {
        callback.setRevert(true);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);

        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
        assertEq(callback.callCount(), 0);
    }

    function test_CallbackFalseReturnIsAcceptedButDoesNotStorePayload() public {
        callback.setReturnValue(false);
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);

        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);
        assertEq(oracle.getRecord(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1).recordedAt, 0);
    }

    function test_MalformedCallbackReturnReverts() public {
        MalformedReturnCallback malformed = new MalformedReturnCallback(2, 32);
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(malformed));

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);
    }

    function test_ShortCallbackReturnReverts() public {
        MalformedReturnCallback malformed = new MalformedReturnCallback(1, 1);
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(malformed));

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);
    }

    function test_LongCallbackReturnIsBoundedAndAccepted() public {
        MalformedReturnCallback longReturn = new MalformedReturnCallback(1, 4_096);
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, address(longReturn));

        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);
    }

    function test_SpecializedCallbackOverridesDefault() public {
        MockOracleCallback specialized = new MockOracleCallback();
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, address(specialized));

        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 100, hex"01", CALLBACK_GAS_LIMIT);
        assertEq(specialized.callCount(), 1);
        assertEq(callback.callCount(), 0);
        assertEq(oracle.getCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), address(specialized));
    }

    function test_SetCallbackRejectsAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidOracleCallback.selector, alice));
        vm.prank(governance);
        oracle.setCallback(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, alice);
    }

    function test_SetDefaultCallbackRejectsAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidOracleCallback.selector, alice));
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_BLOCKCHAIN, alice);
    }

    function test_InitializeRejectsAddressWithoutCode() public {
        uint32[] memory sourceTypes = new uint32[](1);
        sourceTypes[0] = SOURCE_TYPE_BLOCKCHAIN;
        address[] memory callbacks = new address[](1);
        callbacks[0] = alice;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidOracleCallback.selector, alice));
        vm.prank(SystemAddresses.GENESIS);
        oracle.initialize(sourceTypes, callbacks);
    }

    function test_LegacyProgressFallbackAndFirstNewWrite() public {
        uint128 legacyNonce = 41;
        uint256 legacyPosition = 19_876_500;
        vm.store(
            address(oracle), _legacyNonceSlot(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), bytes32(uint256(legacyNonce))
        );
        vm.store(
            address(oracle),
            bytes32(uint256(_legacyRecordSlot(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, legacyNonce)) + 1),
            bytes32(legacyPosition)
        );

        INativeOracle.SourceProgress memory progress =
            oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(progress.latestNonce, legacyNonce);
        assertEq(progress.latestPosition, legacyPosition);

        _record(
            SOURCE_TYPE_BLOCKCHAIN,
            ETHEREUM_SOURCE_ID,
            legacyNonce + 1,
            legacyPosition + 10,
            hex"42",
            CALLBACK_GAS_LIMIT
        );

        progress = oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(progress.latestNonce, legacyNonce + 1);
        assertEq(progress.latestPosition, legacyPosition + 10);
        assertEq(
            uint256(vm.load(address(oracle), _legacyNonceSlot(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID))), legacyNonce
        );
    }

    function test_LegacyProgressWithoutStoredRecordMarksPositionUnknown() public {
        uint128 legacyNonce = 41;
        vm.store(
            address(oracle), _legacyNonceSlot(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), bytes32(uint256(legacyNonce))
        );

        INativeOracle.SourceProgress memory progress =
            oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(progress.latestNonce, legacyNonce);
        assertEq(progress.latestPosition, 0);

        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, legacyNonce + 1, 19_876_510, hex"42", CALLBACK_GAS_LIMIT);
        progress = oracle.getSourceProgress(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(progress.latestNonce, legacyNonce + 1);
        assertEq(progress.latestPosition, 19_876_510);
    }

    function test_EventsOracleDeliveredAndCallbackSuccess() public {
        bytes memory payload = hex"aabbcc";

        vm.expectEmit(true, true, false, true, address(oracle));
        emit INativeOracle.CallbackSuccess(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, address(callback));
        vm.expectEmit(true, true, false, true, address(oracle));
        emit INativeOracle.OracleDelivered(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 123, keccak256(payload));
        _record(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1, 123, payload, CALLBACK_GAS_LIMIT);
    }

    function testFuzz_RecordTracksLatestProgress(
        uint32 sourceType,
        uint256 sourceId,
        uint128 position,
        bytes calldata payload
    ) public {
        vm.assume(payload.length < 4_096);
        vm.prank(governance);
        oracle.setDefaultCallback(sourceType, address(callback));

        _record(sourceType, sourceId, 1, position, payload, CALLBACK_GAS_LIMIT);
        INativeOracle.SourceProgress memory progress = oracle.getSourceProgress(sourceType, sourceId);
        assertEq(progress.latestNonce, 1);
        assertEq(progress.latestPosition, position);
    }

    function _record(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 position,
        bytes memory payload,
        uint256 gasLimit
    ) internal {
        vm.prank(systemCaller);
        oracle.record(sourceType, sourceId, nonce, position, payload, gasLimit);
    }

    function _legacyNonceSlot(
        uint32 sourceType,
        uint256 sourceId
    ) internal pure returns (bytes32) {
        bytes32 typeSlot = keccak256(abi.encode(sourceType, uint256(1)));
        return keccak256(abi.encode(sourceId, typeSlot));
    }

    function _legacyRecordSlot(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) internal pure returns (bytes32) {
        bytes32 typeSlot = keccak256(abi.encode(sourceType, uint256(0)));
        bytes32 sourceSlot = keccak256(abi.encode(sourceId, typeSlot));
        return keccak256(abi.encode(nonce, sourceSlot));
    }
}
