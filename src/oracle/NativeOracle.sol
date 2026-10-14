// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeOracle, IOracleCallback } from "./INativeOracle.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title NativeOracle
/// @author Gravity Team
/// @notice Delivers verified external data and stores one latest checkpoint per source
/// @dev Legacy records and nonces retain their storage slots for hardfork compatibility.
///      Portal is a public message transport. Blockchain ingestion must keep moving even when
///      an application rejects a sender or a callback fails; mint completion is a separate result.
///      Deferred execution is limited to BLOCKCHAIN sources. Ordered non-blockchain sources stay atomic.
contract NativeOracle is INativeOracle {
    uint256 private constant MAX_CALLBACK_RETURNDATA_BYTES = 256;
    uint32 private constant SOURCE_TYPE_BLOCKCHAIN = 0;
    // Reserve outer gas for three cold pending slots, progress, events and cleanup after child OOG.
    uint256 private constant CALLBACK_FAILURE_GAS_RESERVE = 200_000;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @dev Legacy records. Kept for historical reads and storage compatibility; never written.
    mapping(uint32 => mapping(uint256 => mapping(uint128 => DataRecord))) private _records;

    /// @dev Legacy nonces. Kept for hardfork fallback and storage compatibility; never written.
    mapping(uint32 => mapping(uint256 => uint128)) private _nonces;

    /// @notice Default callback handlers: sourceType -> callback contract
    mapping(uint32 => address) private _defaultCallbacks;

    /// @notice Specialized callback handlers: sourceType -> sourceId -> callback contract
    mapping(uint32 => mapping(uint256 => address)) private _callbacks;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    /// @notice Latest post-hardfork progress, packed into one slot per source
    /// @dev Appended after every legacy field to preserve the deployed storage layout.
    mapping(uint32 => mapping(uint256 => SourceProgress)) private _sourceProgress;

    /// @dev Append-only storage. Accepted nonces and pending business execution are independent.
    mapping(uint32 => mapping(uint256 => mapping(uint128 => PendingCallback))) private _pendingCallbacks;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the contract (can only be called once by GENESIS)
    /// @param sourceTypes Array of source types to configure
    /// @param callbacks Array of default callback addresses matching sourceTypes
    function initialize(
        uint32[] calldata sourceTypes,
        address[] calldata callbacks
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        uint256 length = sourceTypes.length;
        if (length != callbacks.length) {
            revert Errors.ArrayLengthMismatch(length, callbacks.length);
        }

        for (uint256 i; i < length;) {
            _validateCallback(callbacks[i]);
            _defaultCallbacks[sourceTypes[i]] = callbacks[i];
            emit DefaultCallbackSet(sourceTypes[i], address(0), callbacks[i]);
            unchecked {
                ++i;
            }
        }

        _initialized = true;
    }

    // ========================================================================
    // RECORDING FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function record(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 blockNumber,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);
        _deliver(sourceType, sourceId, nonce, blockNumber, payload, callbackGasLimit);
    }

    /// @inheritdoc INativeOracle
    function recordBatch(
        uint32 sourceType,
        uint256 sourceId,
        uint128[] calldata nonces,
        uint256[] calldata blockNumbers,
        bytes[] calldata payloads,
        uint256[] calldata callbackGasLimits
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        uint256 length = nonces.length;
        if (length == 0) return;

        // Validate array lengths match
        if (length != blockNumbers.length || length != payloads.length || length != callbackGasLimits.length) {
            revert Errors.OracleBatchArrayLengthMismatch(
                length, blockNumbers.length, payloads.length, callbackGasLimits.length
            );
        }

        // Isolate blockchain callback failures so later messages can still be accepted.
        // Invalid nonces/inputs or transaction-level OOG still roll back this entire batch.
        for (uint256 i; i < length;) {
            _deliver(sourceType, sourceId, nonces[i], blockNumbers[i], payloads[i], callbackGasLimits[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Accept a sequential entry; blockchain callback failures do not stop source progress
    /// @dev A public Portal shares its nonce stream across senders. An untrusted sender or one
    ///      failed mint must not prevent later deposits from being processed. Retain failed
    ///      executions for a separate system retry instead of treating accepted nonce as mint success.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce
    /// @param payload The payload data
    /// @param callbackGasLimit Gas limit for callback (0 = no callback)
    function _deliver(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 blockNumber,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) private {
        SourceProgress memory current = _getSourceProgress(sourceType, sourceId);
        if (nonce != current.latestNonce + 1) {
            revert Errors.NonceNotSequential(sourceType, sourceId, current.latestNonce + 1, nonce);
        }
        if (blockNumber > type(uint128).max) revert Errors.OracleSourcePositionOverflow(blockNumber);

        uint128 sourcePosition = uint128(blockNumber);
        if (sourceType == SOURCE_TYPE_BLOCKCHAIN) {
            address callback = _resolveCallback(sourceType, sourceId);
            _requireCallback(sourceType, sourceId, callback, callbackGasLimit);
            (bool succeeded, bytes memory reason) =
                _attemptCallback(sourceType, sourceId, nonce, callback, payload, callbackGasLimit);
            if (!succeeded) {
                bytes32 payloadHash = keccak256(payload);
                _pendingCallbacks[sourceType][sourceId][nonce] = PendingCallback({
                    payloadHash: payloadHash, callback: callback, attempts: 1, sourcePosition: sourcePosition
                });
                emit CallbackFailed(sourceType, sourceId, nonce, callback, reason);
                emit CallbackDeferred(sourceType, sourceId, nonce, callback, payloadHash, 1);
            }
        } else {
            _invokeCallback(sourceType, sourceId, nonce, payload, callbackGasLimit);
        }

        _sourceProgress[sourceType][sourceId] = SourceProgress({ latestNonce: nonce, latestPosition: sourcePosition });
        emit OracleDelivered(sourceType, sourceId, nonce, sourcePosition, keccak256(payload));
    }

    /// @inheritdoc INativeOracle
    function getPendingCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (PendingCallback memory pending) {
        return _pendingCallbacks[sourceType][sourceId][nonce];
    }

    /// @inheritdoc INativeOracle
    function retryCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external returns (bool succeeded) {
        // Native mint is available only in the system transaction phase; opening this to EOAs
        // would not provide the same execution environment and could falsely report mint success.
        requireAllowed(SystemAddresses.SYSTEM_CALLER);
        PendingCallback memory pending = _pendingCallbacks[sourceType][sourceId][nonce];
        if (pending.callback == address(0)) revert Errors.OracleCallbackNotPending(sourceType, sourceId, nonce);
        bytes32 payloadHash = keccak256(payload);
        if (payloadHash != pending.payloadHash) {
            revert Errors.OracleCallbackPayloadMismatch(pending.payloadHash, payloadHash);
        }
        address current = _resolveCallback(sourceType, sourceId);
        if (current != pending.callback) revert Errors.OracleCallbackTargetChanged(pending.callback, current);
        _requireCallback(sourceType, sourceId, current, callbackGasLimit);

        // Remove before executing. A completed task can never be retried; a failed attempt is
        // restored below. This never creates a fresh source nonce or changes ingestion progress.
        delete _pendingCallbacks[sourceType][sourceId][nonce];
        ++pending.attempts;
        bytes memory reason;
        (succeeded, reason) = _attemptCallback(sourceType, sourceId, nonce, current, payload, callbackGasLimit);
        if (succeeded) {
            emit CallbackRetrySucceeded(sourceType, sourceId, nonce, current, payloadHash, pending.attempts);
        } else {
            _pendingCallbacks[sourceType][sourceId][nonce] = pending;
            emit CallbackFailed(sourceType, sourceId, nonce, current, reason);
            emit CallbackDeferred(sourceType, sourceId, nonce, current, payloadHash, pending.attempts);
        }
    }

    /// @inheritdoc INativeOracle
    function executeCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        address callback,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external {
        requireAllowed(address(this));
        (bool succeeded, bytes memory reason) =
            _callCallback(sourceType, sourceId, nonce, callback, payload, callbackGasLimit);
        if (!succeeded) {
            // Roll back the callback AND return validation in this child frame. Simply catching
            // an invalid bool in the parent could retain a mint and then execute it again on retry.
            assembly ("memory-safe") { revert(add(reason, 0x20), mload(reason)) }
        }
        emit CallbackSuccess(sourceType, sourceId, nonce, callback);
    }

    // ========================================================================
    // CALLBACK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function setDefaultCallback(
        uint32 sourceType,
        address callback
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _validateCallback(callback);

        address oldCallback = _defaultCallbacks[sourceType];
        _defaultCallbacks[sourceType] = callback;

        emit DefaultCallbackSet(sourceType, oldCallback, callback);
    }

    /// @inheritdoc INativeOracle
    function getDefaultCallback(
        uint32 sourceType
    ) external view returns (address callback) {
        return _defaultCallbacks[sourceType];
    }

    /// @inheritdoc INativeOracle
    function setCallback(
        uint32 sourceType,
        uint256 sourceId,
        address callback
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _validateCallback(callback);

        address oldCallback = _callbacks[sourceType][sourceId];
        _callbacks[sourceType][sourceId] = callback;

        emit CallbackSet(sourceType, sourceId, oldCallback, callback);
    }

    /// @inheritdoc INativeOracle
    function getCallback(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (address callback) {
        address specialized = _callbacks[sourceType][sourceId];
        if (specialized != address(0)) {
            return specialized;
        }
        return _defaultCallbacks[sourceType];
    }

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @inheritdoc INativeOracle
    function getRecord(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (DataRecord memory) {
        return _records[sourceType][sourceId][nonce];
    }

    /// @inheritdoc INativeOracle
    function getLatestNonce(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (uint128 nonce) {
        return _getSourceProgress(sourceType, sourceId).latestNonce;
    }

    /// @inheritdoc INativeOracle
    function getSourceProgress(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (SourceProgress memory progress) {
        return _getSourceProgress(sourceType, sourceId);
    }

    /// @inheritdoc INativeOracle
    function isSyncedPast(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (bool) {
        uint128 latestNonce = _getSourceProgress(sourceType, sourceId).latestNonce;
        return latestNonce > 0 && latestNonce >= nonce;
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Read post-hardfork progress or fall back to the latest legacy record
    function _getSourceProgress(
        uint32 sourceType,
        uint256 sourceId
    ) internal view returns (SourceProgress memory progress) {
        progress = _sourceProgress[sourceType][sourceId];
        if (progress.latestNonce != 0) return progress;

        uint128 legacyNonce = _nonces[sourceType][sourceId];
        if (legacyNonce == 0) return progress;

        uint256 legacyPosition = _records[sourceType][sourceId][legacyNonce].blockNumber;
        if (legacyPosition > type(uint128).max) {
            revert Errors.OracleSourcePositionOverflow(legacyPosition);
        }
        progress = SourceProgress({ latestNonce: legacyNonce, latestPosition: uint128(legacyPosition) });
    }

    /// @notice Resolve callback using 2-layer lookup
    /// @dev Returns specialized callback if set, otherwise default callback
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return callback The resolved callback address (address(0) if none set)
    function _resolveCallback(
        uint32 sourceType,
        uint256 sourceId
    ) internal view returns (address callback) {
        address specialized = _callbacks[sourceType][sourceId];
        if (specialized != address(0)) {
            return specialized;
        }
        return _defaultCallbacks[sourceType];
    }

    /// @notice Preserve atomic callback semantics for non-blockchain sources
    function _invokeCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload,
        uint256 gasLimit
    ) internal {
        address callback = _resolveCallback(sourceType, sourceId);
        _requireCallback(sourceType, sourceId, callback, gasLimit);
        (bool succeeded, bytes memory reason) = _callCallback(sourceType, sourceId, nonce, callback, payload, gasLimit);
        if (!succeeded) revert Errors.OracleCallbackFailed(sourceType, sourceId, nonce, callback, reason);
        emit CallbackSuccess(sourceType, sourceId, nonce, callback);
    }

    function _requireCallback(
        uint32 sourceType,
        uint256 sourceId,
        address callback,
        uint256 gasLimit
    ) private pure {
        // Configuration and delivery-budget errors are not executed callback failures. Reject
        // these system inputs instead of consuming a nonce with no valid execution target.
        if (callback == address(0)) revert Errors.OracleCallbackNotConfigured(sourceType, sourceId);
        // A callback cannot also possess the privileged ingestion/retry caller identity.
        if (callback == SystemAddresses.SYSTEM_CALLER) revert Errors.InvalidOracleCallback(callback);
        if (gasLimit == 0) revert Errors.OracleCallbackGasLimitZero(sourceType, sourceId);
    }

    function _attemptCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        address callback,
        bytes calldata payload,
        uint256 gasLimit
    ) private returns (bool succeeded, bytes memory reason) {
        bytes memory callData =
            abi.encodeCall(this.executeCallback, (sourceType, sourceId, nonce, callback, payload, gasLimit));
        // Both the outer self-call and the inner callback are subject to EIP-150. Include
        // wrapper encoding overhead and keep a separate parent budget to persist failure.
        uint256 wrapperGas = gasLimit + gasLimit / 63 + 30_000 + payload.length * 16;
        uint256 requiredGas = wrapperGas + wrapperGas / 63 + CALLBACK_FAILURE_GAS_RESERVE;
        uint256 availableGas = gasleft();
        if (availableGas < requiredGas) revert Errors.OracleCallbackGasBudgetTooLow(requiredGas, availableGas);
        return _callWithBoundedReturndata(address(this), wrapperGas, callData);
    }

    function _callCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        address callback,
        bytes calldata payload,
        uint256 gasLimit
    ) private returns (bool succeeded, bytes memory reason) {
        bytes memory callData = abi.encodeCall(IOracleCallback.onOracleEvent, (sourceType, sourceId, nonce, payload));
        (succeeded, reason) = _callWithBoundedReturndata(callback, gasLimit, callData);
        if (!succeeded || reason.length < 32) return (false, reason);
        uint256 rawReturnValue;
        assembly ("memory-safe") { rawReturnValue := mload(add(reason, 0x20)) }
        // false is a valid ABI result (the legacy shouldStore flag), not a failed mint.
        return (rawReturnValue <= 1, reason);
    }

    /// @dev Calls a callback without automatically copying unbounded returndata into memory.
    function _callWithBoundedReturndata(
        address callback,
        uint256 gasLimit,
        bytes memory callData
    ) private returns (bool success, bytes memory returnData) {
        uint256 maxReturnData = MAX_CALLBACK_RETURNDATA_BYTES;
        assembly ("memory-safe") {
            success := call(gasLimit, callback, 0, add(callData, 0x20), mload(callData), 0, 0)

            let returnSize := returndatasize()
            if gt(returnSize, maxReturnData) { returnSize := maxReturnData }

            returnData := mload(0x40)
            mstore(returnData, returnSize)
            returndatacopy(add(returnData, 0x20), 0, returnSize)
            mstore(0x40, and(add(add(returnData, 0x3f), returnSize), not(0x1f)))
        }
    }

    function _validateCallback(
        address callback
    ) private view {
        if (callback != address(0) && (callback == SystemAddresses.SYSTEM_CALLER || callback.code.length == 0)) {
            revert Errors.InvalidOracleCallback(callback);
        }
    }
}
