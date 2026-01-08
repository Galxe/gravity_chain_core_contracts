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
///      Supports two storage modes:
///      - Hash mode: Store only keccak256(payload), storage-efficient
///      - Data mode: Store full payload for direct contract access
///      Callbacks are invoked with limited gas and failures do NOT revert oracle recording.
contract NativeOracle is INativeOracle {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Gas limit for callback execution
    /// @dev Prevents malicious callbacks from consuming excessive gas
    uint256 public constant CALLBACK_GAS_LIMIT = 500_000;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Data records: hash => DataRecord
    /// @dev The hash serves as the unique key for each record
    mapping(bytes32 => DataRecord) private _dataRecords;

    /// @notice Sync status per source: sourceName => SyncStatus
    /// @dev sourceName = keccak256(abi.encode(sourceType, sourceId))
    mapping(bytes32 => SyncStatus) private _syncStatus;

    /// @notice Default callback handlers: sourceType => callback contract
    /// @dev Fallback callback for all sources of a given type
    mapping(uint32 => address) private _defaultCallbacks;

    /// @notice Specialized callback handlers: sourceName => callback contract
    /// @dev Overrides default callback for specific (sourceType, sourceId) pairs
    mapping(bytes32 => address) private _callbacks;

    /// @notice Total number of records stored
    uint256 private _totalRecords;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the oracle contract
    /// @dev Can only be called once by GENESIS
    function initialize() external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        _initialized = true;
    }

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Require the contract to be initialized
    modifier whenInitialized() {
        if (!_initialized) {
            revert Errors.OracleNotInitialized();
        }
        _;
    }

    // ========================================================================
    // RECORDING FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function recordHash(
        bytes32 dataHash,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes calldata payload
    ) external whenInitialized {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        bytes32 sourceName = _computeSourceName(sourceType, sourceId);

        // Update sync status (validates syncId is increasing and >= 1)
        _updateSyncStatus(sourceName, sourceType, sourceId, syncId);

        // Record hash without storing payload data
        _recordHashInternal(dataHash, syncId);

        emit HashRecorded(dataHash, sourceType, sourceId, syncId);

        // Invoke callback if registered
        _invokeCallback(sourceName, sourceType, sourceId, dataHash, payload);
    }

    /// @inheritdoc INativeOracle
    function recordData(
        bytes32 dataHash,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes calldata payload
    ) external whenInitialized {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        bytes32 sourceName = _computeSourceName(sourceType, sourceId);

        // Update sync status (validates syncId is increasing and >= 1)
        _updateSyncStatus(sourceName, sourceType, sourceId, syncId);

        // Record with full data storage
        _recordDataInternal(dataHash, syncId, payload);

        emit DataRecorded(dataHash, sourceType, sourceId, syncId, payload.length);

        // Invoke callback if registered
        _invokeCallback(sourceName, sourceType, sourceId, dataHash, payload);
    }

    /// @inheritdoc INativeOracle
    function recordHashBatch(
        bytes32[] calldata dataHashes,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes[] calldata payloads
    ) external whenInitialized {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Validate array lengths match
        if (dataHashes.length != payloads.length) {
            revert Errors.ArrayLengthMismatch(dataHashes.length, payloads.length);
        }

        bytes32 sourceName = _computeSourceName(sourceType, sourceId);

        // Update sync status once for the batch
        _updateSyncStatus(sourceName, sourceType, sourceId, syncId);

        // Record all hashes
        uint256 length = dataHashes.length;
        for (uint256 i; i < length;) {
            bytes32 dataHash = dataHashes[i];

            _recordHashInternal(dataHash, syncId);

            emit HashRecorded(dataHash, sourceType, sourceId, syncId);

            // Invoke callback for each record
            _invokeCallback(sourceName, sourceType, sourceId, dataHash, payloads[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc INativeOracle
    function recordDataBatch(
        bytes32[] calldata dataHashes,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes[] calldata payloads
    ) external whenInitialized {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Validate array lengths match
        if (dataHashes.length != payloads.length) {
            revert Errors.ArrayLengthMismatch(dataHashes.length, payloads.length);
        }

        bytes32 sourceName = _computeSourceName(sourceType, sourceId);

        // Update sync status once for the batch
        _updateSyncStatus(sourceName, sourceType, sourceId, syncId);

        // Record all data entries
        uint256 length = dataHashes.length;
        for (uint256 i; i < length;) {
            bytes32 dataHash = dataHashes[i];
            bytes calldata payload = payloads[i];

            _recordDataInternal(dataHash, syncId, payload);

            emit DataRecorded(dataHash, sourceType, sourceId, syncId, payload.length);

            // Invoke callback for each record
            _invokeCallback(sourceName, sourceType, sourceId, dataHash, payload);

            unchecked {
                ++i;
            }
        }
    }

    // ========================================================================
    // CALLBACK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function setDefaultCallback(
        uint32 sourceType,
        address callback
    ) external whenInitialized {
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
    ) external whenInitialized {
        requireAllowed(SystemAddresses.GOVERNANCE);

        bytes32 sourceName = _computeSourceName(sourceType, sourceId);
        address oldCallback = _callbacks[sourceName];
        _callbacks[sourceName] = callback;

        emit CallbackSet(sourceType, sourceId, oldCallback, callback);
    }

    /// @inheritdoc INativeOracle
    function getCallback(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (address callback) {
        bytes32 sourceName = _computeSourceName(sourceType, sourceId);
        address specialized = _callbacks[sourceName];
        if (specialized != address(0)) {
            return specialized;
        }
        return _defaultCallbacks[sourceType];
    }

    // ========================================================================
    // VERIFICATION FUNCTIONS
    // ========================================================================

    /// @inheritdoc INativeOracle
    function verifyHash(
        bytes32 dataHash
    ) external view returns (DataRecord memory record) {
        return _dataRecords[dataHash];
    }

    /// @inheritdoc INativeOracle
    function verifyPreImage(
        bytes calldata preImage
    ) external view returns (DataRecord memory record) {
        bytes32 dataHash = keccak256(preImage);
        return _dataRecords[dataHash];
    }

    /// @inheritdoc INativeOracle
    function getData(
        bytes32 dataHash
    ) external view returns (bytes memory data) {
        return _dataRecords[dataHash].data;
    }

    // ========================================================================
    // SYNC STATUS
    // ========================================================================

    /// @inheritdoc INativeOracle
    function getSyncStatus(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (SyncStatus memory status) {
        bytes32 sourceName = _computeSourceName(sourceType, sourceId);
        return _syncStatus[sourceName];
    }

    /// @inheritdoc INativeOracle
    function isSyncedPast(
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId
    ) external view returns (bool) {
        bytes32 sourceName = _computeSourceName(sourceType, sourceId);
        SyncStatus storage status = _syncStatus[sourceName];
        return status.initialized && status.latestSyncId >= syncId;
    }

    // ========================================================================
    // STATISTICS
    // ========================================================================

    /// @inheritdoc INativeOracle
    function getTotalRecords() external view returns (uint256) {
        return _totalRecords;
    }

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    /// @inheritdoc INativeOracle
    function computeSourceName(
        uint32 sourceType,
        uint256 sourceId
    ) external pure returns (bytes32) {
        return _computeSourceName(sourceType, sourceId);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Compute the internal sourceName from source type and source ID
    /// @param sourceType The source type (uint32)
    /// @param sourceId The source identifier (uint256)
    /// @return sourceName The computed source name
    function _computeSourceName(
        uint32 sourceType,
        uint256 sourceId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(sourceType, sourceId));
    }

    /// @notice Update sync status for a source
    /// @dev Validates that syncId is strictly increasing (and >= 1 for first record since latestSyncId starts at 0)
    /// @param sourceName The computed source name
    /// @param sourceType The source type (for error reporting)
    /// @param sourceId The source identifier (for error reporting)
    /// @param syncId The new sync ID (must be > latestSyncId, which means >= 1 for first record)
    function _updateSyncStatus(
        bytes32 sourceName,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId
    ) internal {
        SyncStatus storage status = _syncStatus[sourceName];

        // Sync ID must be strictly increasing (latestSyncId defaults to 0, so first syncId must be >= 1)
        if (syncId <= status.latestSyncId) {
            revert Errors.SyncIdNotIncreasing(sourceType, sourceId, status.latestSyncId, syncId);
        }

        uint128 previousSyncId = status.latestSyncId;
        status.initialized = true;
        status.latestSyncId = syncId;

        emit SyncStatusUpdated(sourceType, sourceId, previousSyncId, syncId);
    }

    /// @notice Record a hash without storing payload data
    /// @param dataHash The hash to record
    /// @param syncId The sync ID for this record
    function _recordHashInternal(
        bytes32 dataHash,
        uint128 syncId
    ) internal {
        DataRecord storage record = _dataRecords[dataHash];

        // Only increment total if this is a new record (syncId == 0 means not exists)
        if (record.syncId == 0) {
            _totalRecords++;
        }

        record.syncId = syncId;
        // Note: record.data remains empty for hash-only mode
    }

    /// @notice Record data with full payload storage
    /// @param dataHash The hash to record
    /// @param syncId The sync ID for this record
    /// @param payload The payload to store
    function _recordDataInternal(
        bytes32 dataHash,
        uint128 syncId,
        bytes calldata payload
    ) internal {
        DataRecord storage record = _dataRecords[dataHash];

        // Only increment total if this is a new record (syncId == 0 means not exists)
        if (record.syncId == 0) {
            _totalRecords++;
        }

        record.syncId = syncId;
        record.data = payload;
    }

    /// @notice Resolve callback using 2-layer lookup
    /// @dev Returns specialized callback if set, otherwise default callback
    /// @param sourceName The computed source name for specialized lookup
    /// @param sourceType The source type for default lookup
    /// @return callback The resolved callback address (address(0) if none set)
    function _resolveCallback(
        bytes32 sourceName,
        uint32 sourceType
    ) internal view returns (address callback) {
        address specialized = _callbacks[sourceName];
        if (specialized != address(0)) {
            return specialized;
        }
        return _defaultCallbacks[sourceType];
    }

    /// @notice Invoke callback with limited gas
    /// @dev Failures are caught to prevent DOS attacks
    /// @param sourceName The computed source name
    /// @param sourceType The source type (for event emission)
    /// @param sourceId The source identifier (for event emission)
    /// @param dataHash The data hash
    /// @param payload The event payload
    function _invokeCallback(
        bytes32 sourceName,
        uint32 sourceType,
        uint256 sourceId,
        bytes32 dataHash,
        bytes calldata payload
    ) internal {
        address callback = _resolveCallback(sourceName, sourceType);
        if (callback == address(0)) return;

        // Try to call the callback with limited gas
        // This prevents malicious callbacks from:
        // 1. Consuming excessive gas
        // 2. Blocking oracle updates by reverting
        try IOracleCallback(callback).onOracleEvent{ gas: CALLBACK_GAS_LIMIT }(dataHash, payload) {
            emit CallbackSuccess(sourceType, sourceId, dataHash, callback);
        } catch (bytes memory reason) {
            emit CallbackFailed(sourceType, sourceId, dataHash, callback, reason);
        }
    }
}
