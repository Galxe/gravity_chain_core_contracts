// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IOracleTaskConfig } from "./IOracleTaskConfig.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";
import { EnumerableSet } from "@openzeppelin/utils/structs/EnumerableSet.sol";

/// @title OracleTaskConfig
/// @author Gravity Team
/// @notice Stores configuration for continuous oracle tasks that validators actively monitor
/// @dev Tasks are keyed by (sourceType, sourceId, taskName) tuple.
///      Multiple tasks can exist for the same (sourceType, sourceId) pair.
///      Only GOVERNANCE can create, update, or remove tasks.
contract OracleTaskConfig is IOracleTaskConfig {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Task names per source: sourceType -> sourceId -> set of taskNames
    mapping(uint32 => mapping(uint256 => EnumerableSet.Bytes32Set)) private _taskNames;

    /// @notice Task data: sourceType -> sourceId -> taskName -> OracleTask
    mapping(uint32 => mapping(uint256 => mapping(bytes32 => OracleTask))) private _tasks;

    // ========================================================================
    // TASK MANAGEMENT (Governance Only)
    // ========================================================================

    /// @inheritdoc IOracleTaskConfig
    function setTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName,
        bytes calldata config
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        if (config.length == 0) {
            revert Errors.EmptyConfig();
        }

        // Add task name to the set (no-op if already exists)
        _taskNames[sourceType][sourceId].add(taskName);

        // Store/update task data
        _tasks[sourceType][sourceId][taskName] = OracleTask({ config: config, updatedAt: uint64(block.timestamp) });

        emit TaskSet(sourceType, sourceId, taskName, config);
    }

    /// @inheritdoc IOracleTaskConfig
    function removeTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        // Remove task name from set
        _taskNames[sourceType][sourceId].remove(taskName);

        // Delete task data
        delete _tasks[sourceType][sourceId][taskName];

        emit TaskRemoved(sourceType, sourceId, taskName);
    }

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @inheritdoc IOracleTaskConfig
    function getTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName
    ) external view returns (OracleTask memory task) {
        return _tasks[sourceType][sourceId][taskName];
    }

    /// @inheritdoc IOracleTaskConfig
    function hasTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName
    ) external view returns (bool) {
        return _tasks[sourceType][sourceId][taskName].config.length > 0;
    }

    /// @inheritdoc IOracleTaskConfig
    function getTaskNames(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (bytes32[] memory taskNames) {
        return _taskNames[sourceType][sourceId].values();
    }

    /// @inheritdoc IOracleTaskConfig
    function getTaskCount(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (uint256 count) {
        return _taskNames[sourceType][sourceId].length();
    }

    /// @inheritdoc IOracleTaskConfig
    function getTaskNameAt(
        uint32 sourceType,
        uint256 sourceId,
        uint256 index
    ) external view returns (bytes32 taskName) {
        return _taskNames[sourceType][sourceId].at(index);
    }
}
