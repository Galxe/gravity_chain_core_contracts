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
    using EnumerableSet for EnumerableSet.UintSet;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Task names per source: sourceType -> sourceId -> set of taskNames
    mapping(uint32 => mapping(uint256 => EnumerableSet.Bytes32Set)) private _taskNames;

    /// @notice Task data: sourceType -> sourceId -> taskName -> OracleTask
    mapping(uint32 => mapping(uint256 => mapping(bytes32 => OracleTask))) private _tasks;

    /// @notice Registered source types (for enumeration)
    EnumerableSet.UintSet private _registeredSourceTypes;

    /// @notice Registered source IDs per source type: sourceType -> set of sourceIds
    mapping(uint32 => EnumerableSet.UintSet) private _registeredSourceIds;

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
        requireAllowed(SystemAddresses.GENESIS, SystemAddresses.GOVERNANCE);

        if (config.length == 0) {
            revert Errors.EmptyConfig();
        }

        // Register source type and source ID for enumeration (no-op if already exists)
        _registeredSourceTypes.add(sourceType);
        _registeredSourceIds[sourceType].add(sourceId);

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

        // Cleanup source registration if no more tasks for this source
        if (_taskNames[sourceType][sourceId].length() == 0) {
            _registeredSourceIds[sourceType].remove(sourceId);
            // If no more sourceIds for this sourceType, remove the sourceType
            if (_registeredSourceIds[sourceType].length() == 0) {
                _registeredSourceTypes.remove(sourceType);
            }
        }

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

    // ========================================================================
    // SOURCE ENUMERATION
    // ========================================================================

    /// @inheritdoc IOracleTaskConfig
    function getSourceTypes() external view returns (uint32[] memory sourceTypes) {
        uint256 length = _registeredSourceTypes.length();
        sourceTypes = new uint32[](length);
        for (uint256 i = 0; i < length; i++) {
            sourceTypes[i] = uint32(_registeredSourceTypes.at(i));
        }
    }

    /// @inheritdoc IOracleTaskConfig
    function getSourceIds(
        uint32 sourceType
    ) external view returns (uint256[] memory sourceIds) {
        return _registeredSourceIds[sourceType].values();
    }

    /// @inheritdoc IOracleTaskConfig
    function getAllTasks() external view returns (FullTaskInfo[] memory tasks) {
        // First, count total tasks
        uint256 totalTasks = 0;
        uint256 sourceTypesLength = _registeredSourceTypes.length();

        for (uint256 i = 0; i < sourceTypesLength; i++) {
            uint32 sourceType = uint32(_registeredSourceTypes.at(i));
            uint256 sourceIdsLength = _registeredSourceIds[sourceType].length();
            for (uint256 j = 0; j < sourceIdsLength; j++) {
                uint256 sourceId = _registeredSourceIds[sourceType].at(j);
                totalTasks += _taskNames[sourceType][sourceId].length();
            }
        }

        // Allocate result array
        tasks = new FullTaskInfo[](totalTasks);
        uint256 index = 0;

        // Populate result array
        for (uint256 i = 0; i < sourceTypesLength; i++) {
            uint32 sourceType = uint32(_registeredSourceTypes.at(i));
            uint256 sourceIdsLength = _registeredSourceIds[sourceType].length();
            for (uint256 j = 0; j < sourceIdsLength; j++) {
                uint256 sourceId = _registeredSourceIds[sourceType].at(j);
                bytes32[] memory taskNamesList = _taskNames[sourceType][sourceId].values();
                for (uint256 k = 0; k < taskNamesList.length; k++) {
                    OracleTask storage task = _tasks[sourceType][sourceId][taskNamesList[k]];
                    tasks[index] = FullTaskInfo({
                        sourceType: sourceType,
                        sourceId: sourceId,
                        taskName: taskNamesList[k],
                        config: task.config,
                        updatedAt: task.updatedAt
                    });
                    index++;
                }
            }
        }
    }
}
