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

    /// @notice Data records: sourceType -> sourceId -> nonce -> DataRecord
    mapping(uint32 => mapping(uint256 => mapping(uint128 => DataRecord))) private _records;

    /// @notice Latest nonce per source: sourceType -> sourceId -> nonce
    mapping(uint32 => mapping(uint256 => uint128)) private _nonces;

    /// @notice Default callback handlers: sourceType -> callback contract
    mapping(uint32 => address) private _defaultCallbacks;

    /// @notice Specialized callback handlers: sourceType -> sourceId -> callback contract
    mapping(uint32 => mapping(uint256 => address)) private _callbacks;

    // ========================================================================
    // RECORDING FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function record(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Validate and update nonce
        _updateNonce(sourceType, sourceId, nonce);

        // Store record
        _records[sourceType][sourceId][nonce] = DataRecord({ recordedAt: uint64(block.timestamp), data: payload });

        emit DataRecorded(sourceType, sourceId, nonce, payload.length);

        // Invoke callback if registered and gas limit > 0
        if (callbackGasLimit > 0) {
            _invokeCallback(sourceType, sourceId, nonce, payload, callbackGasLimit);
        }
    }

    /// @inheritdoc INativeOracle
    function recordBatch(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes[] calldata payloads,
        uint256 callbackGasLimit
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        uint256 length = payloads.length;
        if (length == 0) return;

        // Validate and update nonce to the final nonce
        uint128 finalNonce = nonce + uint128(length) - 1;
        _updateNonce(sourceType, sourceId, finalNonce);

        // Record all data entries
        for (uint256 i; i < length;) {
            uint128 currentNonce = nonce + uint128(i);
            bytes calldata payload = payloads[i];

            _records[sourceType][sourceId][currentNonce] =
                DataRecord({ recordedAt: uint64(block.timestamp), data: payload });

            emit DataRecorded(sourceType, sourceId, currentNonce, payload.length);

            // Invoke callback if gas limit > 0
            if (callbackGasLimit > 0) {
                _invokeCallback(sourceType, sourceId, currentNonce, payload, callbackGasLimit);
            }

            unchecked {
                ++i;
            }
        }
    }

    // ========================================================================
    // CALLBACK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function setDefaultCallback(uint32 sourceType, address callback) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        address oldCallback = _defaultCallbacks[sourceType];
        _defaultCallbacks[sourceType] = callback;

        emit DefaultCallbackSet(sourceType, oldCallback, callback);
    }

    /// @inheritdoc INativeOracle
    function getDefaultCallback(uint32 sourceType) external view returns (address callback) {
        return _defaultCallbacks[sourceType];
    }

    /// @inheritdoc INativeOracle
    function setCallback(uint32 sourceType, uint256 sourceId, address callback) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        address oldCallback = _callbacks[sourceType][sourceId];
        _callbacks[sourceType][sourceId] = callback;

        emit CallbackSet(sourceType, sourceId, oldCallback, callback);
    }

    /// @inheritdoc INativeOracle
    function getCallback(uint32 sourceType, uint256 sourceId) external view returns (address callback) {
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
    function getRecord(uint32 sourceType, uint256 sourceId, uint128 nonce)
        external
        view
        returns (DataRecord memory)
    {
        return _records[sourceType][sourceId][nonce];
    }

    /// @inheritdoc INativeOracle
    function getLatestNonce(uint32 sourceType, uint256 sourceId) external view returns (uint128 nonce) {
        return _nonces[sourceType][sourceId];
    }

    /// @inheritdoc INativeOracle
    function isSyncedPast(uint32 sourceType, uint256 sourceId, uint128 nonce) external view returns (bool) {
        uint128 latestNonce = _nonces[sourceType][sourceId];
        return latestNonce > 0 && latestNonce >= nonce;
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Update nonce for a source
    /// @dev Validates that nonce is strictly increasing (and >= 1 for first record)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The new nonce (must be > current nonce)
    function _updateNonce(uint32 sourceType, uint256 sourceId, uint128 nonce) internal {
        uint128 currentNonce = _nonces[sourceType][sourceId];

        // Nonce must be strictly increasing (currentNonce defaults to 0, so first nonce must be >= 1)
        if (nonce <= currentNonce) {
            revert Errors.NonceNotIncreasing(sourceType, sourceId, currentNonce, nonce);
        }

        _nonces[sourceType][sourceId] = nonce;
    }

    /// @notice Resolve callback using 2-layer lookup
    /// @dev Returns specialized callback if set, otherwise default callback
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return callback The resolved callback address (address(0) if none set)
    function _resolveCallback(uint32 sourceType, uint256 sourceId) internal view returns (address callback) {
        address specialized = _callbacks[sourceType][sourceId];
        if (specialized != address(0)) {
            return specialized;
        }
        return _defaultCallbacks[sourceType];
    }

    /// @notice Invoke callback with specified gas limit
    /// @dev Failures are caught to prevent DOS attacks
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
        if (callback == address(0)) return;

        // Try to call the callback with specified gas limit
        // This prevents malicious callbacks from:
        // 1. Consuming excessive gas
        // 2. Blocking oracle updates by reverting
        try IOracleCallback(callback).onOracleEvent{ gas: gasLimit }(sourceType, sourceId, nonce, payload) {
            emit CallbackSuccess(sourceType, sourceId, nonce, callback);
        } catch (bytes memory reason) {
            emit CallbackFailed(sourceType, sourceId, nonce, callback, reason);
        }
    }
}
