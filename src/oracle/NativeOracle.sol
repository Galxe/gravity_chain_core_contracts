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
contract NativeOracle is INativeOracle {
    uint256 private constant MAX_CALLBACK_RETURNDATA_BYTES = 256;

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

        // Deliver all entries atomically. Any callback failure reverts the full batch.
        for (uint256 i; i < length;) {
            _deliver(sourceType, sourceId, nonces[i], blockNumbers[i], payloads[i], callbackGasLimits[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Deliver one entry and advance progress only after callback success
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

        _invokeCallback(sourceType, sourceId, nonce, payload, callbackGasLimit);

        uint128 sourcePosition = uint128(blockNumber);
        _sourceProgress[sourceType][sourceId] = SourceProgress({ latestNonce: nonce, latestPosition: sourcePosition });
        emit OracleDelivered(sourceType, sourceId, nonce, sourcePosition, keccak256(payload));
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

    /// @notice Invoke callback with bounded returndata and fail atomically
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param payload The event payload
    /// @param gasLimit Gas limit for callback execution
    function _invokeCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload,
        uint256 gasLimit
    ) internal {
        address callback = _resolveCallback(sourceType, sourceId);
        if (callback == address(0)) {
            revert Errors.OracleCallbackNotConfigured(sourceType, sourceId);
        }
        if (gasLimit == 0) {
            revert Errors.OracleCallbackGasLimitZero(sourceType, sourceId);
        }

        bytes memory callData = abi.encodeCall(IOracleCallback.onOracleEvent, (sourceType, sourceId, nonce, payload));
        (bool success, bytes memory returnData) = _callWithBoundedReturndata(callback, gasLimit, callData);

        if (!success || returnData.length < 32) {
            revert Errors.OracleCallbackFailed(sourceType, sourceId, nonce, callback, returnData);
        }

        uint256 rawReturnValue;
        assembly ("memory-safe") {
            rawReturnValue := mload(add(returnData, 0x20))
        }
        if (rawReturnValue > 1) {
            revert Errors.OracleCallbackFailed(sourceType, sourceId, nonce, callback, returnData);
        }

        emit CallbackSuccess(sourceType, sourceId, nonce, callback);
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
        if (callback != address(0) && callback.code.length == 0) {
            revert Errors.InvalidOracleCallback(callback);
        }
    }
}
