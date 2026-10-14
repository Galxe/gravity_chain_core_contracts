// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle, IOracleCallback } from "../../../src/oracle/INativeOracle.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

contract DeferredCallbackProbe is IOracleCallback {
    enum Mode {
        Normal,
        Revert,
        InvalidBool,
        ShortReturn,
        OutOfGas,
        Reenter
    }

    NativeOracle internal immutable oracle;
    Mode public mode;
    uint256 public effects;
    bool public recordReentrySucceeded;
    bool public retryReentrySucceeded;
    bool public wrapperReentrySucceeded;

    constructor(
        NativeOracle oracle_
    ) {
        oracle = oracle_;
    }

    function setMode(
        Mode value
    ) external {
        mode = value;
    }

    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external returns (bool) {
        ++effects;
        Mode current = mode;
        if (current == Mode.Revert) revert("callback failed");
        if (current == Mode.InvalidBool) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (current == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (current == Mode.OutOfGas) {
            assembly ("memory-safe") { for { } 1 { } { } }
        }
        if (current == Mode.Reenter) {
            (recordReentrySucceeded,) = address(oracle)
                .call(abi.encodeCall(oracle.record, (sourceType, sourceId, nonce + 1, 101, payload, 100_000)));
            (retryReentrySucceeded,) = address(oracle)
                .call(abi.encodeCall(oracle.retryCallback, (sourceType, sourceId, nonce, payload, 100_000)));
            (wrapperReentrySucceeded,) = address(oracle)
                .call(
                    abi.encodeCall(
                        oracle.executeCallback, (sourceType, sourceId, nonce, address(this), payload, 100_000)
                    )
                );
        }
        return true;
    }
}

contract NativeOracleDeferredTest is Test {
    NativeOracle internal oracle;
    DeferredCallbackProbe internal callback;
    uint256 internal constant SOURCE_ID = 1;
    uint256 internal constant CALLBACK_GAS = 500_000;
    bytes internal payload = hex"0102030405";

    function setUp() public {
        oracle = new NativeOracle();
        callback = new DeferredCallbackProbe(oracle);
        vm.startPrank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(0, address(callback));
        oracle.setDefaultCallback(1, address(callback));
        vm.stopPrank();
    }

    function test_SystemCallerCannotBeRegisteredAsCallbackEvenWithCode() public {
        vm.etch(SystemAddresses.SYSTEM_CALLER, address(callback).code);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidOracleCallback.selector, SystemAddresses.SYSTEM_CALLER));
        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(0, SystemAddresses.SYSTEM_CALLER);
    }

    function test_InvalidBoolRollsBackEffectsBeforeDeferring() public {
        callback.setMode(DeferredCallbackProbe.Mode.InvalidBool);
        _record(0, 1, 100, CALLBACK_GAS);
        assertEq(callback.effects(), 0, "invalid ABI must roll back callback side effects");
        _assertPending(1, 1, 100);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 1);

        callback.setMode(DeferredCallbackProbe.Mode.Normal);
        assertTrue(_retry(1));
        assertEq(callback.effects(), 1, "retry executes effects exactly once");
        assertEq(oracle.getPendingCallback(0, SOURCE_ID, 1).callback, address(0));
    }

    function test_ShortReturnAlsoRollsBackEffectsBeforeDeferring() public {
        callback.setMode(DeferredCallbackProbe.Mode.ShortReturn);
        _record(0, 1, 100, CALLBACK_GAS);
        assertEq(callback.effects(), 0);
        _assertPending(1, 1, 100);
    }

    function test_CallbackOutOfGasDefersAndLaterNonceExecutes() public {
        callback.setMode(DeferredCallbackProbe.Mode.OutOfGas);
        _record(0, 1, 100, 100_000);
        assertEq(callback.effects(), 0);
        _assertPending(1, 1, 100);
        callback.setMode(DeferredCallbackProbe.Mode.Normal);
        _record(0, 2, 101, CALLBACK_GAS);
        assertEq(callback.effects(), 1);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 2);
        assertEq(oracle.getSourceProgress(0, SOURCE_ID).latestPosition, 101);
        _assertPending(1, 1, 100);
    }

    function test_CallbackOutOfGasWithBoundedOuterBudgetStillPersistsColdFailure() public {
        callback.setMode(DeferredCallbackProbe.Mode.OutOfGas);
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        (bool succeeded,) = address(oracle).call{ gas: 360_000 }(
            abi.encodeCall(oracle.record, (uint32(0), SOURCE_ID, uint128(1), uint256(100), payload, uint256(100_000)))
        );
        assertTrue(succeeded, "outer reserve must persist cold pending and progress after child OOG");
        assertEq(callback.effects(), 0);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 1);
        assertEq(oracle.getSourceProgress(0, SOURCE_ID).latestPosition, 100);
        _assertPending(1, 1, 100);
    }

    function test_FailedRetriesRetainPendingThenSuccessCannotRepeat() public {
        _defer();
        assertFalse(_retry(1));
        _assertPending(1, 2, 100);
        assertEq(callback.effects(), 0);

        callback.setMode(DeferredCallbackProbe.Mode.Normal);
        _record(0, 2, 200, CALLBACK_GAS);
        assertTrue(_retry(1));
        assertEq(callback.effects(), 2);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 2);
        assertEq(oracle.getSourceProgress(0, SOURCE_ID).latestPosition, 200);
        assertEq(oracle.getPendingCallback(0, SOURCE_ID, 1).callback, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleCallbackNotPending.selector, uint32(0), SOURCE_ID, uint128(1))
        );
        _retry(1);
        assertEq(callback.effects(), 2);
    }

    function test_RetryRejectsPayloadTampering() public {
        _defer();
        bytes memory changedPayload = hex"0102030406";
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.OracleCallbackPayloadMismatch.selector, keccak256(payload), keccak256(changedPayload)
            )
        );
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.retryCallback(0, SOURCE_ID, 1, changedPayload, CALLBACK_GAS);
        _assertPending(1, 1, 100);
    }

    function test_RetryRejectsNonceWhichNeverFailed() public {
        _record(0, 1, 100, CALLBACK_GAS);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleCallbackNotPending.selector, uint32(0), SOURCE_ID, uint128(1))
        );
        _retry(1);
        assertEq(callback.effects(), 1);
    }

    function test_EOACannotRecordOrRetry() public {
        address outsider = makeAddr("outsider");
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, outsider, SystemAddresses.SYSTEM_CALLER));
        vm.prank(outsider);
        oracle.record(0, SOURCE_ID, 1, 100, payload, CALLBACK_GAS);
        _defer();
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, outsider, SystemAddresses.SYSTEM_CALLER));
        vm.prank(outsider);
        oracle.retryCallback(0, SOURCE_ID, 1, payload, CALLBACK_GAS);
        _assertPending(1, 1, 100);
    }

    function test_ExecutionWrapperRejectsEOAAndSystemCaller() public {
        address outsider = makeAddr("outsider");
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, outsider, address(oracle)));
        vm.prank(outsider);
        oracle.executeCallback(0, SOURCE_ID, 1, address(callback), payload, CALLBACK_GAS);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, address(oracle)));
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.executeCallback(0, SOURCE_ID, 1, address(callback), payload, CALLBACK_GAS);
        assertEq(callback.effects(), 0);
    }

    function test_ChangedCallbackCannotReceiveOriginalPendingPayload() public {
        _defer();
        DeferredCallbackProbe replacement = new DeferredCallbackProbe(oracle);
        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setCallback(0, SOURCE_ID, address(replacement));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleCallbackTargetChanged.selector, address(callback), address(replacement))
        );
        _retry(1);
        assertEq(replacement.effects(), 0);
        _assertPending(1, 1, 100);
    }

    function test_RevokedCallbackCannotExecutePendingTask() public {
        _defer();
        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(0, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleCallbackTargetChanged.selector, address(callback), address(0))
        );
        _retry(1);
        _assertPending(1, 1, 100);
    }

    function test_InsufficientOuterGasDoesNotConsumeNonceOrCreatePending() public {
        callback.setMode(DeferredCallbackProbe.Mode.OutOfGas);
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        (bool succeeded, bytes memory reason) = address(oracle).call{ gas: 250_000 }(
            abi.encodeCall(oracle.record, (uint32(0), SOURCE_ID, uint128(1), 100, payload, CALLBACK_GAS))
        );
        assertFalse(succeeded);
        assertGe(reason.length, 4, "reject gas budget before exhausting the outer frame");
        assertEq(bytes4(reason), Errors.OracleCallbackGasBudgetTooLow.selector);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 0);
        assertEq(oracle.getPendingCallback(0, SOURCE_ID, 1).callback, address(0));
        assertEq(callback.effects(), 0);
    }

    function test_InsufficientRetryGasPreservesOriginalPending() public {
        _defer();
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        (bool succeeded, bytes memory reason) = address(oracle).call{ gas: 250_000 }(
            abi.encodeCall(oracle.retryCallback, (uint32(0), SOURCE_ID, uint128(1), payload, CALLBACK_GAS))
        );
        assertFalse(succeeded);
        assertEq(bytes4(reason), Errors.OracleCallbackGasBudgetTooLow.selector);
        _assertPending(1, 1, 100);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 1);
    }

    function test_NonBlockchainFailureRemainsAtomic() public {
        callback.setMode(DeferredCallbackProbe.Mode.Revert);
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(1, 1, 100, CALLBACK_GAS);
        assertEq(oracle.getLatestNonce(1, SOURCE_ID), 0);
        assertEq(oracle.getPendingCallback(1, SOURCE_ID, 1).callback, address(0));
        assertEq(callback.effects(), 0);
    }

    function test_CallbackCannotReenterRecordRetryOrWrapper() public {
        _defer();
        callback.setMode(DeferredCallbackProbe.Mode.Reenter);
        assertTrue(_retry(1));
        assertFalse(callback.recordReentrySucceeded());
        assertFalse(callback.retryReentrySucceeded());
        assertFalse(callback.wrapperReentrySucceeded());
        assertEq(callback.effects(), 1);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 1);
        assertEq(oracle.getPendingCallback(0, SOURCE_ID, 1).callback, address(0));
    }

    function test_LegacyStoredRecordCannotBeRetriedWithoutPendingState() public {
        // Legacy _records and _nonces occupy slots 0 and 1. An old receipt is not
        // proof of callback failure; old records also include successfully minted messages.
        bytes32 sourceRecords = keccak256(abi.encode(SOURCE_ID, keccak256(abi.encode(uint32(0), uint256(0)))));
        bytes32 recordSlot = keccak256(abi.encode(uint128(7), sourceRecords));
        vm.store(address(oracle), recordSlot, bytes32(uint256(1)));
        vm.store(address(oracle), bytes32(uint256(recordSlot) + 1), bytes32(uint256(999)));
        bytes32 sourceNonceSlot = keccak256(abi.encode(SOURCE_ID, keccak256(abi.encode(uint32(0), uint256(1)))));
        vm.store(address(oracle), sourceNonceSlot, bytes32(uint256(7)));
        INativeOracle.DataRecord memory legacyRecord = oracle.getRecord(0, SOURCE_ID, 7);
        assertEq(legacyRecord.recordedAt, 1);
        assertEq(legacyRecord.blockNumber, 999);
        assertEq(oracle.getLatestNonce(0, SOURCE_ID), 7);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleCallbackNotPending.selector, uint32(0), SOURCE_ID, uint128(7))
        );
        _retry(7);
        assertEq(callback.effects(), 0);
    }

    function _defer() internal {
        callback.setMode(DeferredCallbackProbe.Mode.Revert);
        _record(0, 1, 100, CALLBACK_GAS);
    }

    function _record(
        uint32 sourceType,
        uint128 nonce,
        uint256 position,
        uint256 gasLimit
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.record(sourceType, SOURCE_ID, nonce, position, payload, gasLimit);
    }

    function _retry(
        uint128 nonce
    ) internal returns (bool) {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        return oracle.retryCallback(0, SOURCE_ID, nonce, payload, CALLBACK_GAS);
    }

    function _assertPending(
        uint128 nonce,
        uint64 attempts,
        uint128 position
    ) internal view {
        INativeOracle.PendingCallback memory pending = oracle.getPendingCallback(0, SOURCE_ID, nonce);
        assertEq(pending.payloadHash, keccak256(payload));
        assertEq(pending.callback, address(callback));
        assertEq(pending.attempts, attempts);
        assertEq(pending.sourcePosition, position);
    }
}
