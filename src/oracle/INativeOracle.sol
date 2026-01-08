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
    ///      Record existence is determined by syncId > 0.
    struct DataRecord {
        /// @notice Sync ID when this was recorded (0 = not exists)
        uint128 syncId;
        /// @notice Stored data (empty for hash-only mode, populated for data mode)
        bytes data;
    }

    /// @notice Sync status for a source
    /// @dev The syncId must be strictly increasing for each source (starting from 1)
    struct SyncStatus {
        /// @notice Whether this source has been initialized
        bool initialized;
        /// @notice Latest sync ID (block height, timestamp, sequence number, etc.)
        uint128 latestSyncId;
    }

    // ========================================================================
    // SOURCE TYPE CONSTANTS
    // ========================================================================

    // Well-known source types by convention:
    //   0 = BLOCKCHAIN (cross-chain events from EVM chains)
    //   1 = JWK (JSON Web Keys from OAuth providers)
    //   2 = DNS (DNS records for zkEmail, etc.)
    //   3 = PRICE_FEED (price data from oracles)
    // New types can be added without contract upgrades.

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a hash is recorded (hash-only mode)
    /// @param dataHash The hash of the data
    /// @param sourceType The source type (0 = BLOCKCHAIN, 1 = JWK, etc.)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param syncId The sync ID (block height, timestamp, etc.)
    event HashRecorded(
        bytes32 indexed dataHash,
        uint32 indexed sourceType,
        uint256 indexed sourceId,
        uint128 syncId
    );

    /// @notice Emitted when data is recorded (data mode)
    /// @param dataHash The hash of the data
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param syncId The sync ID
    /// @param dataLength Length of the stored data
    event DataRecorded(
        bytes32 indexed dataHash,
        uint32 indexed sourceType,
        uint256 indexed sourceId,
        uint128 syncId,
        uint256 dataLength
    );

    /// @notice Emitted when sync status is updated for a source
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param previousSyncId The previous sync ID
    /// @param newSyncId The new sync ID
    event SyncStatusUpdated(
        uint32 indexed sourceType,
        uint256 indexed sourceId,
        uint128 previousSyncId,
        uint128 newSyncId
    );

    /// @notice Emitted when a callback is registered or updated
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param oldCallback The previous callback address
    /// @param newCallback The new callback address
    event CallbackSet(
        uint32 indexed sourceType,
        uint256 indexed sourceId,
        address indexed oldCallback,
        address newCallback
    );

    /// @notice Emitted when a callback succeeds
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param dataHash The data hash
    /// @param callback The callback contract address
    event CallbackSuccess(
        uint32 indexed sourceType,
        uint256 indexed sourceId,
        bytes32 dataHash,
        address callback
    );

    /// @notice Emitted when a callback fails (tx continues, does NOT revert)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param dataHash The data hash
    /// @param callback The callback contract address
    /// @param reason The failure reason
    event CallbackFailed(
        uint32 indexed sourceType,
        uint256 indexed sourceId,
        bytes32 dataHash,
        address callback,
        bytes reason
    );

    // ========================================================================
    // RECORDING FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @notice Record a hash (hash-only mode, storage-efficient)
    /// @dev Only callable by SYSTEM_CALLER. Invokes callback if registered.
    /// @param dataHash The hash of the data being recorded
    /// @param sourceType The source type (uint32, e.g., 0 = BLOCKCHAIN, 1 = JWK)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param syncId The sync ID - must start from 1 and strictly increase
    /// @param payload The event payload (for callback, not stored in hash mode)
    function recordHash(
        bytes32 dataHash,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes calldata payload
    ) external;

    /// @notice Record data (data mode, direct access)
    /// @dev Only callable by SYSTEM_CALLER. Invokes callback if registered.
    /// @param dataHash The hash of the data (for indexing and verification)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param syncId The sync ID - must start from 1 and strictly increase
    /// @param payload The event payload (stored on-chain)
    function recordData(
        bytes32 dataHash,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes calldata payload
    ) external;

    /// @notice Batch record multiple hashes from the same source
    /// @dev Only callable by SYSTEM_CALLER. More gas efficient for multiple records.
    /// @param dataHashes Array of hashes to record
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param syncId The sync ID for all records
    /// @param payloads Array of payloads (for callbacks)
    function recordHashBatch(
        bytes32[] calldata dataHashes,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    /// @notice Batch record multiple data entries from the same source
    /// @dev Only callable by SYSTEM_CALLER. More gas efficient for multiple records.
    /// @param dataHashes Array of hashes
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param syncId The sync ID for all records
    /// @param payloads Array of payloads to store
    function recordDataBatch(
        bytes32[] calldata dataHashes,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    // ========================================================================
    // CALLBACK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @notice Register a callback handler for a source
    /// @dev Only callable by GOVERNANCE
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param callback The callback contract address (address(0) to unregister)
    function setCallback(
        uint32 sourceType,
        uint256 sourceId,
        address callback
    ) external;

    /// @notice Get the callback handler for a source
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return callback The callback contract address (address(0) if not set)
    function getCallback(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (address callback);

    // ========================================================================
    // VERIFICATION FUNCTIONS
    // ========================================================================

    /// @notice Verify a hash exists and get its record
    /// @dev Record exists if record.syncId > 0
    /// @param dataHash The hash to verify
    /// @return record The data record (syncId = 0 if not found, data field empty if hash-only mode)
    function verifyHash(
        bytes32 dataHash
    ) external view returns (DataRecord memory record);

    /// @notice Verify pre-image matches a recorded hash
    /// @dev Useful for hash-only mode where users provide original data as calldata.
    ///      Record exists if record.syncId > 0.
    /// @param preImage The original data (provided as calldata)
    /// @return record The data record (syncId = 0 if not found)
    function verifyPreImage(
        bytes calldata preImage
    ) external view returns (DataRecord memory record);

    /// @notice Get stored data directly (for data mode records)
    /// @param dataHash The hash key
    /// @return data The stored data (empty if hash-only or not found)
    function getData(
        bytes32 dataHash
    ) external view returns (bytes memory data);

    // ========================================================================
    // SYNC STATUS
    // ========================================================================

    /// @notice Get sync status for a source
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return status The current sync status
    function getSyncStatus(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (SyncStatus memory status);

    /// @notice Check if a source has synced past a certain point
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param syncId The sync ID to check
    /// @return True if latestSyncId >= syncId
    function isSyncedPast(
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId
    ) external view returns (bool);

    // ========================================================================
    // STATISTICS
    // ========================================================================

    /// @notice Get total number of records stored
    /// @return Total record count
    function getTotalRecords() external view returns (uint256);

    // ========================================================================
    // HELPERS
    // ========================================================================

    /// @notice Compute the internal sourceName from source type and source ID
    /// @dev sourceName = keccak256(abi.encode(sourceType, sourceId))
    /// @param sourceType The source type (uint32)
    /// @param sourceId The source identifier (uint256)
    /// @return sourceName The computed source name (used internally for storage)
    function computeSourceName(
        uint32 sourceType,
        uint256 sourceId
    ) external pure returns (bytes32 sourceName);
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
    function onOracleEvent(
        bytes32 dataHash,
        bytes calldata payload
    ) external;
}
