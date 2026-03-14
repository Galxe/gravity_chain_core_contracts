// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IValidatorPerformanceTracker
/// @author Gravity Team
/// @notice Interface for tracking validator proposal performance within each epoch
/// @dev Follows Aptos stake::ValidatorPerformance pattern.
///      Per-block: updateStatistics() tracks successful/failed proposals.
///      Per-epoch: onNewEpoch() resets counters for the new validator set.
interface IValidatorPerformanceTracker {
    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Performance counters for a single validator within one epoch
    struct IndividualPerformance {
        uint64 successfulProposals;
        uint64 failedProposals;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when performance statistics are updated
    /// @param proposerIndex The index of the proposer (type(uint64).max for NIL)
    /// @param failedCount Number of failed proposer indices recorded
    event PerformanceUpdated(uint64 indexed proposerIndex, uint256 failedCount);

    /// @notice Emitted when performance counters are reset for a new epoch
    /// @param epoch The new epoch number
    /// @param validatorCount Number of validators in the new set
    event PerformanceReset(uint64 indexed epoch, uint256 validatorCount);

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the tracker with the genesis validator set size
    /// @dev Called by Genesis during chain initialization
    /// @param activeValidatorCount Number of active validators at genesis
    function initialize(
        uint256 activeValidatorCount
    ) external;

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @notice Update proposal performance statistics for the current block
    /// @dev Called by Blocker.onBlockStart() every block.
    ///      Follows Aptos stake::update_performance_statistics() pattern:
    ///      - Increments successful_proposals for the proposer (skipped for NIL)
    ///      - Increments failed_proposals for each failed proposer
    ///      - Silently skips out-of-bounds indices (never reverts)
    /// @param proposerIndex Index of the proposer (type(uint64).max for NIL)
    /// @param failedProposerIndices Indices of validators who failed to propose
    function updateStatistics(
        uint64 proposerIndex,
        uint64[] calldata failedProposerIndices
    ) external;

    /// @notice Reset performance counters for a new epoch
    /// @dev Called by Reconfiguration._applyReconfiguration() during epoch transitions.
    ///      Clears all existing counters and re-initializes for the new validator set.
    /// @param activeValidatorCount Number of active validators in the new epoch
    function onNewEpoch(
        uint256 activeValidatorCount
    ) external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get performance counters for a specific validator
    /// @param validatorIndex Index of the validator in the active set
    /// @return successful Number of successful proposals
    /// @return failed Number of failed proposals
    function getPerformance(
        uint64 validatorIndex
    ) external view returns (uint64 successful, uint64 failed);

    /// @notice Get performance counters for all validators
    /// @dev Returns a copy of the entire performance array
    /// @return performances Array of IndividualPerformance structs
    function getAllPerformances() external view returns (IndividualPerformance[] memory performances);

    /// @notice Get the number of tracked validators
    /// @return Number of validators being tracked
    function getTrackedValidatorCount() external view returns (uint256);
}
