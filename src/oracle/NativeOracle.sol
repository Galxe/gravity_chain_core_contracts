// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {INativeOracle, IOracleCallback} from "./INativeOracle.sol";
import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {requireAllowed} from "../foundation/SystemAccessControl.sol";
import {Errors} from "../foundation/Errors.sol";

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
    /// @dev Tracks the latest verified position for each source
    mapping(bytes32 => SyncStatus) private _syncStatus;

    /// @notice Callback handlers: sourceName => callback contract
    /// @dev When an event is recorded, the callback is invoked (if registered)
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
    function recordHash(bytes32 dataHash, bytes32 sourceName, uint128 syncId, bytes calldata payload)
        external
        whenInitialized
    {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Update sync status (validates syncId is increasing)
        _updateSyncStatus(sourceName, syncId);

        // Record hash without storing payload data
        _recordHashInternal(dataHash, syncId);

        emit HashRecorded(dataHash, sourceName, syncId);

        // Invoke callback if registered
        _invokeCallback(sourceName, dataHash, payload);
    }

    /// @inheritdoc INativeOracle
    function recordData(bytes32 dataHash, bytes32 sourceName, uint128 syncId, bytes calldata payload)
        external
        whenInitialized
    {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Update sync status (validates syncId is increasing)
        _updateSyncStatus(sourceName, syncId);

        // Record with full data storage
        _recordDataInternal(dataHash, syncId, payload);

        emit DataRecorded(dataHash, sourceName, syncId, payload.length);

        // Invoke callback if registered
        _invokeCallback(sourceName, dataHash, payload);
    }

    /// @inheritdoc INativeOracle
    function recordHashBatch(
        bytes32[] calldata dataHashes,
        bytes32 sourceName,
        uint128 syncId,
        bytes[] calldata payloads
    ) external whenInitialized {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Validate array lengths match
        if (dataHashes.length != payloads.length) {
            revert Errors.ArrayLengthMismatch(dataHashes.length, payloads.length);
        }

        // Update sync status once for the batch
        _updateSyncStatus(sourceName, syncId);

        // Record all hashes
        uint256 length = dataHashes.length;
        for (uint256 i; i < length;) {
            bytes32 dataHash = dataHashes[i];

            _recordHashInternal(dataHash, syncId);

            emit HashRecorded(dataHash, sourceName, syncId);

            // Invoke callback for each record
            _invokeCallback(sourceName, dataHash, payloads[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc INativeOracle
    function recordDataBatch(
        bytes32[] calldata dataHashes,
        bytes32 sourceName,
        uint128 syncId,
        bytes[] calldata payloads
    ) external whenInitialized {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Validate array lengths match
        if (dataHashes.length != payloads.length) {
            revert Errors.ArrayLengthMismatch(dataHashes.length, payloads.length);
        }

        // Update sync status once for the batch
        _updateSyncStatus(sourceName, syncId);

        // Record all data entries
        uint256 length = dataHashes.length;
        for (uint256 i; i < length;) {
            bytes32 dataHash = dataHashes[i];
            bytes calldata payload = payloads[i];

            _recordDataInternal(dataHash, syncId, payload);

            emit DataRecorded(dataHash, sourceName, syncId, payload.length);

            // Invoke callback for each record
            _invokeCallback(sourceName, dataHash, payload);

            unchecked {
                ++i;
            }
        }
    }

    // ========================================================================
    // CALLBACK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @inheritdoc INativeOracle
    function setCallback(bytes32 sourceName, address callback) external whenInitialized {
        requireAllowed(SystemAddresses.TIMELOCK);

        address oldCallback = _callbacks[sourceName];
        _callbacks[sourceName] = callback;

        emit CallbackSet(sourceName, oldCallback, callback);
    }

    /// @inheritdoc INativeOracle
    function getCallback(bytes32 sourceName) external view returns (address callback) {
        return _callbacks[sourceName];
    }

    // ========================================================================
    // VERIFICATION FUNCTIONS
    // ========================================================================

    /// @inheritdoc INativeOracle
    function verifyHash(bytes32 dataHash) external view returns (bool exists, DataRecord memory record) {
        record = _dataRecords[dataHash];
        exists = record.exists;
    }

    /// @inheritdoc INativeOracle
    function verifyPreImage(bytes calldata preImage) external view returns (bool exists, DataRecord memory record) {
        bytes32 dataHash = keccak256(preImage);
        record = _dataRecords[dataHash];
        exists = record.exists;
    }

    /// @inheritdoc INativeOracle
    function getData(bytes32 dataHash) external view returns (bytes memory data) {
        return _dataRecords[dataHash].data;
    }

    // ========================================================================
    // SYNC STATUS
    // ========================================================================

    /// @inheritdoc INativeOracle
    function getSyncStatus(bytes32 sourceName) external view returns (SyncStatus memory status) {
        return _syncStatus[sourceName];
    }

    /// @inheritdoc INativeOracle
    function isSyncedPast(bytes32 sourceName, uint128 syncId) external view returns (bool) {
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
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Update sync status for a source
    /// @dev Validates that syncId is strictly increasing
    /// @param sourceName The source identifier
    /// @param syncId The new sync ID
    function _updateSyncStatus(bytes32 sourceName, uint128 syncId) internal {
        SyncStatus storage status = _syncStatus[sourceName];

        if (status.initialized) {
            // Sync ID must be strictly increasing
            if (syncId <= status.latestSyncId) {
                revert Errors.SyncIdNotIncreasing(sourceName, status.latestSyncId, syncId);
            }
        }

        uint128 previousSyncId = status.latestSyncId;
        status.initialized = true;
        status.latestSyncId = syncId;

        emit SyncStatusUpdated(sourceName, previousSyncId, syncId);
    }

    /// @notice Record a hash without storing payload data
    /// @param dataHash The hash to record
    /// @param syncId The sync ID for this record
    function _recordHashInternal(bytes32 dataHash, uint128 syncId) internal {
        DataRecord storage record = _dataRecords[dataHash];

        // Only increment total if this is a new record
        if (!record.exists) {
            _totalRecords++;
        }

        record.exists = true;
        record.syncId = syncId;
        // Note: record.data remains empty for hash-only mode
    }

    /// @notice Record data with full payload storage
    /// @param dataHash The hash to record
    /// @param syncId The sync ID for this record
    /// @param payload The payload to store
    function _recordDataInternal(bytes32 dataHash, uint128 syncId, bytes calldata payload) internal {
        DataRecord storage record = _dataRecords[dataHash];

        // Only increment total if this is a new record
        if (!record.exists) {
            _totalRecords++;
        }

        record.exists = true;
        record.syncId = syncId;
        record.data = payload;
    }

    /// @notice Invoke callback with limited gas
    /// @dev Failures are caught to prevent DOS attacks
    /// @param sourceName The source identifier
    /// @param dataHash The data hash
    /// @param payload The event payload
    function _invokeCallback(bytes32 sourceName, bytes32 dataHash, bytes calldata payload) internal {
        address callback = _callbacks[sourceName];
        if (callback == address(0)) return;

        // Try to call the callback with limited gas
        // This prevents malicious callbacks from:
        // 1. Consuming excessive gas
        // 2. Blocking oracle updates by reverting
        try IOracleCallback(callback).onOracleEvent{gas: CALLBACK_GAS_LIMIT}(dataHash, payload) {
            emit CallbackSuccess(sourceName, dataHash, callback);
        } catch (bytes memory reason) {
            emit CallbackFailed(sourceName, dataHash, callback, reason);
        }
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    /// @notice Compute the sourceName from event type and source ID
    /// @dev sourceName = keccak256(abi.encode(eventType, sourceId))
    /// @param eventType The event type enum value
    /// @param sourceId The source identifier (e.g., keccak256("ethereum"))
    /// @return sourceName The computed source name
    function computeSourceName(EventType eventType, bytes32 sourceId) external pure returns (bytes32) {
        return keccak256(abi.encode(eventType, sourceId));
    }
}

