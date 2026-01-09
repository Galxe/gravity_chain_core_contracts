// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IOnDemandOracleTaskConfig } from "./IOnDemandOracleTaskConfig.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";
import { Errors } from "../../foundation/Errors.sol";

/// @title OnDemandOracleTaskConfig
/// @author Gravity Team
/// @notice Defines which on-demand request types the consensus engine supports
/// @dev Task types are keyed by (sourceType, sourceId) tuple.
///      Only GOVERNANCE can create, update, or remove task types.
contract OnDemandOracleTaskConfig is IOnDemandOracleTaskConfig {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice On-demand task types: sourceType -> sourceId -> OnDemandTaskType
    mapping(uint32 => mapping(uint256 => OnDemandTaskType)) private _taskTypes;

    // ========================================================================
    // TASK TYPE MANAGEMENT (Governance Only)
    // ========================================================================

    /// @inheritdoc IOnDemandOracleTaskConfig
    function setTaskType(
        uint32 sourceType,
        uint256 sourceId,
        bytes calldata config
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        if (config.length == 0) {
            revert Errors.EmptyConfig();
        }

        _taskTypes[sourceType][sourceId] = OnDemandTaskType({ config: config, updatedAt: uint64(block.timestamp) });

        emit TaskTypeSet(sourceType, sourceId, config);
    }

    /// @inheritdoc IOnDemandOracleTaskConfig
    function removeTaskType(
        uint32 sourceType,
        uint256 sourceId
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        delete _taskTypes[sourceType][sourceId];

        emit TaskTypeRemoved(sourceType, sourceId);
    }

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @inheritdoc IOnDemandOracleTaskConfig
    function getTaskType(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (OnDemandTaskType memory taskType) {
        return _taskTypes[sourceType][sourceId];
    }

    /// @inheritdoc IOnDemandOracleTaskConfig
    function isSupported(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (bool) {
        return _taskTypes[sourceType][sourceId].config.length > 0;
    }
}

