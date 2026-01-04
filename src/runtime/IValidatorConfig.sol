// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IValidatorConfig
/// @author Gravity Team
/// @notice Read-only interface for ValidatorConfig contract
/// @dev Used by contracts that need to read validator configuration (e.g., ValidatorManagement)
interface IValidatorConfig {
    /// @notice Minimum bond to join validator set
    function minimumBond() external view returns (uint256);

    /// @notice Maximum bond per validator (caps voting power)
    function maximumBond() external view returns (uint256);

    /// @notice Unbonding delay in microseconds
    function unbondingDelayMicros() external view returns (uint64);

    /// @notice Whether validators can join/leave post-genesis
    function allowValidatorSetChange() external view returns (bool);

    /// @notice Max % of voting power that can join per epoch (1-50)
    function votingPowerIncreaseLimitPct() external view returns (uint64);

    /// @notice Maximum number of validators in the set
    function maxValidatorSetSize() external view returns (uint256);

    /// @notice Maximum allowed voting power increase limit (50%)
    function MAX_VOTING_POWER_INCREASE_LIMIT() external view returns (uint64);

    /// @notice Maximum allowed validator set size
    function MAX_VALIDATOR_SET_SIZE() external view returns (uint256);
}

