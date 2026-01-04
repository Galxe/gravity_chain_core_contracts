// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { RandomnessConfig } from "./RandomnessConfig.sol";

/// @title IRandomnessConfig
/// @author Gravity Team
/// @notice Interface for the RandomnessConfig contract
interface IRandomnessConfig {
    /// @notice Get current active randomness configuration
    function getCurrentConfig() external view returns (RandomnessConfig.RandomnessConfigData memory);

    /// @notice Apply pending configuration (called at epoch boundaries)
    function applyPendingConfig() external;
}
