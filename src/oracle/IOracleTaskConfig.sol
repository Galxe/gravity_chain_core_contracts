// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IOracleTaskConfig
/// @author Gravity Team
/// @notice Interface for the Oracle Task Configuration contract
/// @dev Stores configuration for continuous oracle tasks that validators actively monitor.
///      Tasks are keyed by (sourceType, sourceId, taskName) tuple.
///      Multiple tasks can exist for the same (sourceType, sourceId) pair.
interface IOracleTaskConfig {
    // ========================================================================
    // DATA STRUCTURES
    // ========================================================================

    /// @notice Configuration for a continuous oracle task
    /// @dev Task existence is determined by config.length > 0
    struct OracleTask {
        /// @notice Task configuration bytes (interpretation depends on sourceType)
        bytes config;
        /// @notice Timestamp when this task was last updated
        uint64 updatedAt;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when an oracle task is created or updated
    /// @param sourceType The source type (e.g., 0 = BLOCKCHAIN, 1 = JWK)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param taskName The unique name/identifier for this task
    /// @param config The task configuration bytes
    event TaskSet(uint32 indexed sourceType, uint256 indexed sourceId, bytes32 indexed taskName, bytes config);

    /// @notice Emitted when an oracle task is removed
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param taskName The task name that was removed
    event TaskRemoved(uint32 indexed sourceType, uint256 indexed sourceId, bytes32 indexed taskName);

    // ========================================================================
    // TASK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @notice Create or update an oracle task
    /// @dev Only callable by GOVERNANCE. Config cannot be empty.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param taskName The unique name/identifier for this task
    /// @param config The task configuration bytes
    function setTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName,
        bytes calldata config
    ) external;

    /// @notice Remove an oracle task
    /// @dev Only callable by GOVERNANCE. Clears config and updatedAt.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param taskName The task name to remove
    function removeTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName
    ) external;

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @notice Get an oracle task by its key tuple
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param taskName The task name
    /// @return task The oracle task (config.length = 0 if not found)
    function getTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName
    ) external view returns (OracleTask memory task);

    /// @notice Check if an oracle task exists
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param taskName The task name
    /// @return True if task exists (config.length > 0)
    function hasTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName
    ) external view returns (bool);

    /// @notice Get all task names for a (sourceType, sourceId) pair
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return taskNames Array of task names
    function getTaskNames(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (bytes32[] memory taskNames);

    /// @notice Get the number of tasks for a (sourceType, sourceId) pair
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @return count The number of tasks
    function getTaskCount(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (uint256 count);

    /// @notice Get a task name by index for a (sourceType, sourceId) pair
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param index The index of the task name
    /// @return taskName The task name at the given index
    function getTaskNameAt(
        uint32 sourceType,
        uint256 sourceId,
        uint256 index
    ) external view returns (bytes32 taskName);
}
