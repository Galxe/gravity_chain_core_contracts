// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IStakingConfig
/// @author Gravity Team
/// @notice Read-only interface for StakingConfig contract
/// @dev Used by contracts that need to read staking configuration (e.g., Staking, StakePool)
interface IStakingConfig {
    /// @notice Minimum stake amount for governance participation
    function minimumStake() external view returns (uint256);

    /// @notice Lockup duration in microseconds
    function lockupDurationMicros() external view returns (uint64);

    /// @notice Unbonding delay in microseconds (additional wait after lockedUntil before withdrawal)
    function unbondingDelayMicros() external view returns (uint64);

    /// @notice Minimum stake required to create governance proposals
    function minimumProposalStake() external view returns (uint256);
}

