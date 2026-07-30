// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title INativeOracle
/// @author Gravity Team
/// @notice Interface for the Native Oracle contract
/// @dev Delivers consensus-approved external data to callbacks and stores only the latest
///      progress for each (sourceType, sourceId) pair. Legacy records remain queryable.
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

    /// @notice Latest accepted progress for one oracle source
    /// @dev Both fields pack into one storage slot.
    struct SourceProgress {
        uint128 latestNonce;
        uint128 latestPosition;
    }

    // ========================================================================
    // SOURCE TYPE CONSTANTS
    // ========================================================================

    // Well-known source types by convention:
    //   0 = BLOCKCHAIN (cross-chain events from EVM chains)
    //   1 = JWK (JSON Web Keys from OAuth providers)
    //   2 = DNS (DNS records for zkEmail, etc.)
    //   3 = PRICE_FEED (price data from oracles)
    //   4 = reserved (no runtime adapter in this branch)
    //   5 = reserved (no runtime adapter in this branch)
    //   6 = POLYMARKET_SETTLEMENT (Polygon CTF settlement mirror)
    // New types can be added without contract upgrades.

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Legacy event retained in the ABI for historical log decoding
    /// @dev New deliveries emit OracleDelivered instead.
    event DataRecorded(uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, uint256 dataLength);

    /// @notice Emitted after a consensus payload is successfully delivered
    event OracleDelivered(
        uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, uint128 sourcePosition, bytes32 payloadHash
    );

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

    /// @notice Legacy event retained in the ABI for historical log decoding
    /// @dev New callback failures revert atomically.
    event CallbackFailed(
        uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, address callback, bytes reason
    );

    /// @notice Legacy event retained in the ABI for historical log decoding
    event StorageSkipped(uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, address callback);

    /// @notice Legacy event retained in the ABI for historical log decoding
    event CallbackSkipped(uint32 indexed sourceType, uint256 indexed sourceId, uint128 nonce, address callback);

    // ========================================================================
    // RECORDING FUNCTIONS (Consensus Only)
    // ========================================================================

    /// @notice Deliver a single consensus-approved data entry
    /// @dev Only callable by SYSTEM_CALLER. Callback execution and progress update are atomic.
    /// @param sourceType The source type (uint32, e.g., 0 = BLOCKCHAIN, 1 = JWK)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param nonce The nonce - must start from 1 and strictly increase
    /// @param blockNumber Source-defined restart position; retained name preserves the existing ABI
    /// @param payload The callback payload
    /// @param callbackGasLimit Gas limit for callback execution
    function record(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 blockNumber,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external;

    /// @notice Deliver multiple consensus-approved entries from the same source
    /// @dev Only callable by SYSTEM_CALLER. The entire batch is atomic.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonces Array of nonces (must be strictly increasing, each > previous latestNonce)
    /// @param payloads Array of callback payloads (must match nonces length)
    /// @param callbackGasLimits Array of nonzero callback gas limits
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

    /// @notice Get a legacy record by its key tuple
    /// @dev New deliveries do not write records. This getter remains for pre-upgrade history.
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
    /// @return nonce The latest accepted nonce (0 if no delivery exists)
    function getLatestNonce(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (uint128 nonce);

    /// @notice Get the effective latest progress, including legacy fallback
    function getSourceProgress(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (SourceProgress memory progress);

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
/// @dev The bool return is retained for ABI compatibility but no longer controls NativeOracle storage.
interface IOracleCallback {
    /// @notice Called when an oracle event is recorded
    /// @dev Callback failure reverts delivery, so callback state and source progress remain atomic.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param payload The event payload (encoding depends on event type)
    /// @return shouldStore Deprecated and ignored by NativeOracle
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external returns (bool shouldStore);
}
