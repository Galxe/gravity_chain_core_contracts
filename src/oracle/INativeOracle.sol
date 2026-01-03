// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title INativeOracle
/// @author Gravity Team
/// @notice Interface for the Native Oracle contract
/// @dev Stores verified data from external sources (blockchains, JWK providers, DNS records).
///      Data is recorded by the consensus engine via SYSTEM_CALLER after validators reach consensus.
///      Supports two storage modes:
///      - Hash mode: Store only keccak256(payload), users provide pre-image as calldata for verification
///      - Data mode: Store full payload for contracts to read directly
interface INativeOracle {
    // ========================================================================
    // DATA STRUCTURES
    // ========================================================================

    /// @notice Record stored in the oracle
    /// @dev For hash-only mode, data is empty. For data mode, data contains the full payload.
    struct DataRecord {
        /// @notice Whether this record exists
        bool exists;
        /// @notice Sync ID when this was recorded (for ordering/freshness)
        uint128 syncId;
        /// @notice Stored data (empty for hash-only mode, populated for data mode)
        bytes data;
    }

    /// @notice Sync status for a source
    /// @dev The syncId must be strictly increasing for each source
    struct SyncStatus {
        /// @notice Whether this source has been initialized
        bool initialized;
        /// @notice Latest sync ID (block height, timestamp, sequence number, etc.)
        uint128 latestSyncId;
    }

    /// @notice Event source types
    /// @dev Used to compute sourceName = keccak256(abi.encode(eventType, sourceId))
    enum EventType {
        BLOCKCHAIN, // Cross-chain events (Ethereum, BSC, etc.)
        JWK, // JWK key providers (Google, Apple, etc.)
        DNS, // DNS records
        CUSTOM // Custom/extensible sources
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a hash is recorded (hash-only mode)
    /// @param dataHash The hash of the data
    /// @param sourceName The source identifier (hash of eventType + sourceId)
    /// @param syncId The sync ID (block height, timestamp, etc.)
    event HashRecorded(bytes32 indexed dataHash, bytes32 indexed sourceName, uint128 syncId);

    /// @notice Emitted when data is recorded (data mode)
    /// @param dataHash The hash of the data
    /// @param sourceName The source identifier
    /// @param syncId The sync ID
    /// @param dataLength Length of the stored data
    event DataRecorded(bytes32 indexed dataHash, bytes32 indexed sourceName, uint128 syncId, uint256 dataLength);

    /// @notice Emitted when sync status is updated for a source
    /// @param sourceName The source identifier
    /// @param previousSyncId The previous sync ID
    /// @param newSyncId The new sync ID
    event SyncStatusUpdated(bytes32 indexed sourceName, uint128 previousSyncId, uint128 newSyncId);

    /// @notice Emitted when a callback is registered or updated
    /// @param sourceName The source identifier
    /// @param oldCallback The previous callback address
    /// @param newCallback The new callback address
    event CallbackSet(bytes32 indexed sourceName, address indexed oldCallback, address indexed newCallback);

    /// @notice Emitted when a callback succeeds
    /// @param sourceName The source identifier
    /// @param dataHash The data hash
    /// @param callback The callback contract address
    event CallbackSuccess(bytes32 indexed sourceName, bytes32 indexed dataHash, address indexed callback);

    /// @notice Emitted when a callback fails (tx continues, does NOT revert)
    /// @param sourceName The source identifier
    /// @param dataHash The data hash
    /// @param callback The callback contract address
    /// @param reason The failure reason
    event CallbackFailed(bytes32 indexed sourceName, bytes32 indexed dataHash, address indexed callback, bytes reason);

    // ========================================================================
    // RECORDING FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @notice Record a hash (hash-only mode, storage-efficient)
    /// @dev Only callable by SYSTEM_CALLER. Invokes callback if registered.
    /// @param dataHash The hash of the data being recorded
    /// @param sourceName The source identifier (hash of eventType + sourceId)
    /// @param syncId The sync ID (block height, timestamp, etc.) - must be > current
    /// @param payload The event payload (for callback, not stored in hash mode)
    function recordHash(bytes32 dataHash, bytes32 sourceName, uint128 syncId, bytes calldata payload) external;

    /// @notice Record data (data mode, direct access)
    /// @dev Only callable by SYSTEM_CALLER. Invokes callback if registered.
    /// @param dataHash The hash of the data (for indexing and verification)
    /// @param sourceName The source identifier
    /// @param syncId The sync ID - must be > current
    /// @param payload The event payload (stored on-chain)
    function recordData(bytes32 dataHash, bytes32 sourceName, uint128 syncId, bytes calldata payload) external;

    /// @notice Batch record multiple hashes from the same source
    /// @dev Only callable by SYSTEM_CALLER. More gas efficient for multiple records.
    /// @param dataHashes Array of hashes to record
    /// @param sourceName The source identifier
    /// @param syncId The sync ID for all records
    /// @param payloads Array of payloads (for callbacks)
    function recordHashBatch(
        bytes32[] calldata dataHashes,
        bytes32 sourceName,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    /// @notice Batch record multiple data entries from the same source
    /// @dev Only callable by SYSTEM_CALLER. More gas efficient for multiple records.
    /// @param dataHashes Array of hashes
    /// @param sourceName The source identifier
    /// @param syncId The sync ID for all records
    /// @param payloads Array of payloads to store
    function recordDataBatch(
        bytes32[] calldata dataHashes,
        bytes32 sourceName,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    // ========================================================================
    // CALLBACK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @notice Register a callback handler for a source
    /// @dev Only callable by TIMELOCK (governance)
    /// @param sourceName The source identifier
    /// @param callback The callback contract address (address(0) to unregister)
    function setCallback(bytes32 sourceName, address callback) external;

    /// @notice Get the callback handler for a source
    /// @param sourceName The source identifier
    /// @return callback The callback contract address (address(0) if not set)
    function getCallback(bytes32 sourceName) external view returns (address callback);

    // ========================================================================
    // VERIFICATION FUNCTIONS
    // ========================================================================

    /// @notice Verify a hash exists and get its record
    /// @param dataHash The hash to verify
    /// @return exists True if the hash is recorded
    /// @return record The data record (data field empty if hash-only mode)
    function verifyHash(bytes32 dataHash) external view returns (bool exists, DataRecord memory record);

    /// @notice Verify pre-image matches a recorded hash
    /// @dev Useful for hash-only mode where users provide original data as calldata
    /// @param preImage The original data (provided as calldata)
    /// @return exists True if hash(preImage) is recorded
    /// @return record The data record
    function verifyPreImage(bytes calldata preImage) external view returns (bool exists, DataRecord memory record);

    /// @notice Get stored data directly (for data mode records)
    /// @param dataHash The hash key
    /// @return data The stored data (empty if hash-only or not found)
    function getData(bytes32 dataHash) external view returns (bytes memory data);

    // ========================================================================
    // SYNC STATUS
    // ========================================================================

    /// @notice Get sync status for a source
    /// @param sourceName The source identifier
    /// @return status The current sync status
    function getSyncStatus(bytes32 sourceName) external view returns (SyncStatus memory status);

    /// @notice Check if a source has synced past a certain point
    /// @param sourceName The source identifier
    /// @param syncId The sync ID to check
    /// @return True if latestSyncId >= syncId
    function isSyncedPast(bytes32 sourceName, uint128 syncId) external view returns (bool);

    // ========================================================================
    // STATISTICS
    // ========================================================================

    /// @notice Get total number of records stored
    /// @return Total record count
    function getTotalRecords() external view returns (uint256);
}

/// @title IOracleCallback
/// @notice Interface for oracle callback handlers
/// @dev Implement this to receive oracle events. Callbacks are invoked with limited gas.
interface IOracleCallback {
    /// @notice Called when an oracle event is recorded
    /// @dev Callback failures are caught - they do NOT revert the oracle recording.
    ///      Callbacks are invoked with limited gas (CALLBACK_GAS_LIMIT).
    /// @param dataHash The hash of the recorded data
    /// @param payload The event payload (encoding depends on event type)
    function onOracleEvent(bytes32 dataHash, bytes calldata payload) external;
}

