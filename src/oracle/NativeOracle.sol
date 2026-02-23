// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeOracle, IOracleCallback } from "./INativeOracle.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title NativeOracle
/// @author Gravity Team
/// @notice Stores verified data from external sources (blockchains, JWK providers, DNS records)
/// @dev Data is recorded by the consensus engine via SYSTEM_CALLER after validators reach consensus.
///      Records are keyed by (sourceType, sourceId, nonce) tuple.
///      Callbacks are invoked with caller-specified gas limit and failures do NOT revert oracle recording.
contract NativeOracle is INativeOracle {
    // ========================================================================
    // STATE
    // ========================================================================

    // TODO: refactor? how to upgrade
    /// @notice Data records: sourceType -> sourceId -> nonce -> DataRecord
    mapping(uint32 => mapping(uint256 => mapping(uint128 => DataRecord))) private _records;

    /// @notice Latest nonce per source: sourceType -> sourceId -> nonce
    mapping(uint32 => mapping(uint256 => uint128)) private _nonces;

    /// @notice Default callback handlers: sourceType -> callback contract
    mapping(uint32 => address) private _defaultCallbacks;

    /// @notice Specialized callback handlers: sourceType -> sourceId -> callback contract
    mapping(uint32 => mapping(uint256 => address)) private _callbacks;

    /// @notice Failed callbacks stored for retry: sourceType -> sourceId -> nonce -> FailedCallback
    mapping(uint32 => mapping(uint256 => mapping(uint128 => FailedCallback))) private _failedCallbacks;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

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

        // Validate and update nonce (always done regardless of storage)
        _updateNonce(sourceType, sourceId, nonce);

        // Invoke callback first to determine if we should store
        // Default: store if no callback or callback fails
        bool shouldStore = true;
        if (callbackGasLimit > 0) {
            shouldStore = _invokeCallback(sourceType, sourceId, nonce, payload, callbackGasLimit);
        }

        // Conditionally store record based on callback result
        if (shouldStore) {
            _records[sourceType][sourceId][nonce] =
                DataRecord({ recordedAt: uint64(block.timestamp), blockNumber: blockNumber, data: payload });
            emit DataRecorded(sourceType, sourceId, nonce, payload.length);
        }
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
        if (length != payloads.length || length != callbackGasLimits.length) {
            revert Errors.OracleBatchArrayLengthMismatch(length, payloads.length, callbackGasLimits.length);
        }

        // Record all data entries with individual nonce validation
        for (uint256 i; i < length;) {
            _recordSingle(sourceType, sourceId, nonces[i], blockNumbers[i], payloads[i], callbackGasLimits[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal helper to record a single entry (reduces stack depth)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce
    /// @param payload The payload data
    /// @param callbackGasLimit Gas limit for callback (0 = no callback)
    function _recordSingle(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 blockNumber,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) private {
        // Validate and update nonce (always done regardless of storage)
        _updateNonce(sourceType, sourceId, nonce);

        // Invoke callback first to determine if we should store
        // Default: store if no callback or callback fails
        bool shouldStore = true;
        if (callbackGasLimit > 0) {
            shouldStore = _invokeCallback(sourceType, sourceId, nonce, payload, callbackGasLimit);
        }

        // Conditionally store record based on callback result
        if (shouldStore) {
            _records[sourceType][sourceId][nonce] =
                DataRecord({ recordedAt: uint64(block.timestamp), blockNumber: blockNumber, data: payload });
            emit DataRecorded(sourceType, sourceId, nonce, payload.length);
        }
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
        return _nonces[sourceType][sourceId];
    }

    /// @inheritdoc INativeOracle
    function isSyncedPast(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (bool) {
        uint128 latestNonce = _nonces[sourceType][sourceId];
        return latestNonce > 0 && latestNonce >= nonce;
    }

    // ========================================================================
    // RETRY FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function retryCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 callbackGasLimit
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        FailedCallback storage failed = _failedCallbacks[sourceType][sourceId][nonce];
        if (failed.callback == address(0)) {
            revert Errors.NoFailedCallback(sourceType, sourceId, nonce);
        }

        address callback = failed.callback;
        bytes memory payload = failed.payload;

        try IOracleCallback(callback).onOracleEvent{ gas: callbackGasLimit }(
            sourceType, sourceId, nonce, payload
        ) returns (
            bool
        ) {
            // Success - clear the failed callback
            delete _failedCallbacks[sourceType][sourceId][nonce];
            emit CallbackRetrySucceeded(sourceType, sourceId, nonce, callback);
        } catch (bytes memory reason) {
            // Still failing - update attempts
            failed.attempts += 1;
            emit CallbackRetryFailed(sourceType, sourceId, nonce, callback, reason);
        }
    }

    /// @inheritdoc INativeOracle
    function getFailedCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (FailedCallback memory) {
        return _failedCallbacks[sourceType][sourceId][nonce];
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Update nonce for a source
    /// @dev Validates that nonce is strictly increasing (and >= 1 for first record)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The new nonce (must be > current nonce)
    function _updateNonce(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) internal {
        uint128 currentNonce = _nonces[sourceType][sourceId];

        // Nonce must be sequential (currentNonce defaults to 0, so first nonce must be 1)
        if (nonce != currentNonce + 1) {
            revert Errors.NonceNotSequential(sourceType, sourceId, currentNonce + 1, nonce);
        }

        _nonces[sourceType][sourceId] = nonce;
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

    /// @notice Invoke callback with specified gas limit
    /// @dev Failures are caught to prevent DOS attacks. Returns whether storage should happen.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param payload The event payload
    /// @param gasLimit Gas limit for callback execution
    /// @return shouldStore True if payload should be stored, false to skip storage
    function _invokeCallback(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload,
        uint256 gasLimit
    ) internal returns (bool shouldStore) {
        address callback = _resolveCallback(sourceType, sourceId);
        if (callback == address(0)) return true; // No callback = store by default

        // Try to call the callback with specified gas limit
        // This prevents malicious callbacks from:
        // 1. Consuming excessive gas
        // 2. Blocking oracle updates by reverting
        try IOracleCallback(callback).onOracleEvent{ gas: gasLimit }(sourceType, sourceId, nonce, payload) returns (
            bool callbackShouldStore
        ) {
            emit CallbackSuccess(sourceType, sourceId, nonce, callback);
            if (!callbackShouldStore) {
                emit StorageSkipped(sourceType, sourceId, nonce, callback);
            }
            return callbackShouldStore;
        } catch (bytes memory reason) {
            // Store failed callback for retry
            _failedCallbacks[sourceType][sourceId][nonce] =
                FailedCallback({ payload: payload, gasLimit: gasLimit, callback: callback, attempts: 1 });
            emit CallbackFailed(sourceType, sourceId, nonce, callback, reason);
            return true; // On failure, store by default to preserve data
        }
    }
}
