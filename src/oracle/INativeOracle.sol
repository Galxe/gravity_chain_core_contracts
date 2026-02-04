// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title INativeOracle
/// @author Gravity Team
/// @notice Interface for the Native Oracle contract
/// @dev Stores verified data from external sources (blockchains, JWK providers, DNS records).
///      Data is recorded by the consensus engine via SYSTEM_CALLER after validators reach consensus.
///      Records are keyed by (sourceType, sourceId, nonce) tuple.
interface INativeOracle {
    // ========================================================================
    // DATA STRUCTURES
    // ========================================================================

    /// @notice Record stored in the oracle
    /// @dev Record existence is determined by recordedAt > 0.
    struct DataRecord {
        /// @notice Timestamp when this was recorded (0 = not exists)
        uint64 recordedAt;
        /// @notice Block number when this was created (0 = not exists)
        uint256 blockNumber;
        /// @notice Stored payload data
        bytes data;
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

    /// @notice Emitted when data is recorded
    /// @param sourceType The source type (0 = BLOCKCHAIN, 1 = JWK, etc.)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param nonce The nonce (block height, timestamp, etc.)
    /// @param dataLength Length of the stored data
    event DataRecorded(uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, uint256 dataLength);

    /// @notice Emitted when a default callback is registered or updated
    /// @param sourceType The source type
    /// @param oldCallback The previous callback address
    /// @param newCallback The new callback address
    event DefaultCallbackSet(uint32 indexed sourceType, address indexed oldCallback, address newCallback);

    /// @notice Emitted when a specialized callback is registered or updated
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param oldCallback The previous callback address
    /// @param newCallback The new callback address
    event CallbackSet(
        uint32 indexed sourceType, uint256 indexed sourceId, address indexed oldCallback, address newCallback
    );

    /// @notice Emitted when a callback succeeds
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param callback The callback contract address
    event CallbackSuccess(uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, address callback);

    /// @notice Emitted when a callback fails (tx continues, does NOT revert)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param callback The callback contract address
    /// @param reason The failure reason
    event CallbackFailed(
        uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, address callback, bytes reason
    );

    /// @notice Emitted when payload storage is skipped (callback returned shouldStore=false)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param callback The callback contract that requested skip
    event StorageSkipped(uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, address callback);

    // ========================================================================
    // RECORDING FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @notice Record a single data entry
    /// @dev Only callable by SYSTEM_CALLER. Invokes callback if registered.
    /// @param sourceType The source type (uint32, e.g., 0 = BLOCKCHAIN, 1 = JWK)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param nonce The nonce - must start from 1 and strictly increase
    /// @param payload The data payload to store
    /// @param callbackGasLimit Gas limit for callback execution (0 = no callback)
    function record(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 blockNumber,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external;

    /// @notice Batch record multiple data entries from the same source
    /// @dev Only callable by SYSTEM_CALLER. More gas efficient for multiple records.
    ///      Each nonce is validated individually to prevent overwriting existing records.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonces Array of nonces (must be strictly increasing, each > previous latestNonce)
    /// @param payloads Array of payloads to store (must match nonces length)
    /// @param callbackGasLimits Array of gas limits for callback execution per record (0 = no callback)
    function recordBatch(
        uint32 sourceType,
        uint256 sourceId,
        uint128[] calldata nonces,
        uint256[] calldata blockNumbers,
        bytes[] calldata payloads,
        uint256[] calldata callbackGasLimits
    ) external;

    // ========================================================================
    // CALLBACK MANAGEMENT (Governance Only)
    // ========================================================================
    //
    // Callbacks use a 2-layer resolution system:
    //   1. Default callback per sourceType - applies to all sources of that type
    //   2. Specialized callback per (sourceType, sourceId) - overrides default
    //
    // When an oracle event is recorded, the system first checks for a specialized
    // callback. If none is set, it falls back to the default callback for that
    // source type.
    // ========================================================================

    /// @notice Register a default callback handler for a source type
    /// @dev Only callable by GOVERNANCE. This callback applies to all sources
    ///      of the given type unless overridden by a specialized callback.
    /// @param sourceType The source type
    /// @param callback The callback contract address (address(0) to unregister)
    function setDefaultCallback(
        uint32 sourceType,
        address callback
    ) external;

    /// @notice Get the default callback handler for a source type
    /// @param sourceType The source type
    /// @return callback The default callback address (address(0) if not set)
    function getDefaultCallback(
        uint32 sourceType
    ) external view returns (address callback);

    /// @notice Register a specialized callback handler for a specific source
    /// @dev Only callable by GOVERNANCE. This callback overrides the default
    ///      callback for the given (sourceType, sourceId) pair.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param callback The callback contract address (address(0) to unregister)
    function setCallback(
        uint32 sourceType,
        uint256 sourceId,
        address callback
    ) external;

    /// @notice Get the effective callback handler for a source (2-layer resolution)
    /// @dev Returns specialized callback if set, otherwise returns default callback.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return callback The effective callback address (address(0) if none set)
    function getCallback(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (address callback);

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @notice Get a record by its key tuple
    /// @dev Record exists if record.recordedAt > 0
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce
    /// @return record The data record (recordedAt = 0 if not found)
    function getRecord(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (DataRecord memory record);

    /// @notice Get the latest nonce for a source
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return nonce The latest nonce (0 if no records)
    function getLatestNonce(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (uint128 nonce);

    /// @notice Check if a source has synced past a certain point
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce to check
    /// @return True if latestNonce >= nonce
    function isSyncedPast(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (bool);
}

/// @title IOracleCallback
/// @author Gravity Team
/// @notice Interface for oracle callback handlers
/// @dev Implement this to receive oracle events. Callbacks are invoked with caller-specified gas limit.
interface IOracleCallback {
    /// @notice Called when an oracle event is recorded
    /// @dev Callback failures are caught - they do NOT revert the oracle recording.
    ///      The return value controls whether NativeOracle stores the payload:
    ///      - true: Store the payload in NativeOracle (default behavior)
    ///      - false: Skip storage (callback handles its own storage, e.g., JWKManager)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param payload The event payload (encoding depends on event type)
    /// @return shouldStore True if NativeOracle should store the payload, false to skip storage
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external returns (bool shouldStore);
}
