// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IOnDemandOracleTaskConfig
/// @author Gravity Team
/// @notice Interface for the On-Demand Oracle Task Configuration contract
/// @dev Defines which on-demand request types the consensus engine supports.
///      Task types are keyed by (sourceType, sourceId) tuple.
interface IOnDemandOracleTaskConfig {
    // ========================================================================
    // DATA STRUCTURES
    // ========================================================================

    /// @notice Configuration for an on-demand oracle task type
    /// @dev Task type existence is determined by config.length > 0
    struct OnDemandTaskType {
        /// @notice Type configuration bytes (e.g., API endpoint, validation rules)
        bytes config;
        /// @notice Timestamp when this task type was last updated (block.timestamp in seconds, NOT microseconds)
        uint64 updatedAt;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when an on-demand task type is created or updated
    /// @param sourceType The source type (e.g., 3 = PRICE_FEED)
    /// @param sourceId The source identifier (e.g., exchange ID)
    /// @param config The task type configuration bytes
    event TaskTypeSet(uint32 indexed sourceType, uint256 indexed sourceId, bytes config);

    /// @notice Emitted when an on-demand task type is removed
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    event TaskTypeRemoved(uint32 indexed sourceType, uint256 indexed sourceId);

    // ========================================================================
    // TASK TYPE MANAGEMENT (Governance Only)
    // ========================================================================

    /// @notice Create or update an on-demand task type
    /// @dev Only callable by GOVERNANCE. Config cannot be empty.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param config The task type configuration bytes
    function setTaskType(
        uint32 sourceType,
        uint256 sourceId,
        bytes calldata config
    ) external;

    /// @notice Remove an on-demand task type
    /// @dev Only callable by GOVERNANCE. Clears config and updatedAt.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    function removeTaskType(
        uint32 sourceType,
        uint256 sourceId
    ) external;

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @notice Get an on-demand task type by its key tuple
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return taskType The on-demand task type (config.length = 0 if not found)
    function getTaskType(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (OnDemandTaskType memory taskType);

    /// @notice Check if an on-demand task type is supported
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return True if task type exists (config.length > 0)
    function isSupported(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (bool);
}

