// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IValidatorPerformanceTracker } from "./IValidatorPerformanceTracker.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title ValidatorPerformanceTracker
/// @author Gravity Team
/// @notice Tracks validator proposal performance within each epoch
/// @dev Follows Aptos stake::ValidatorPerformance pattern.
///      Called by Blocker every block to record successful/failed proposals.
///      Reset by Reconfiguration at epoch boundaries.
///      Performance data can be consumed by ValidatorManagement.onNewEpoch()
///      for future rewards distribution or validator ejection.
contract ValidatorPerformanceTracker is IValidatorPerformanceTracker {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Performance counters indexed by validator index
    /// @dev Array length matches the active validator set size for the current epoch.
    ///      Reset to zeros at each epoch boundary.
    IndividualPerformance[] private _validators;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @inheritdoc IValidatorPerformanceTracker
    function initialize(
        uint256 activeValidatorCount
    ) external override {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        _initialized = true;

        // Initialize performance counters for all validators
        for (uint256 i; i < activeValidatorCount;) {
            _validators.push(IndividualPerformance({ successfulProposals: 0, failedProposals: 0 }));
            unchecked {
                ++i;
            }
        }
    }

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @inheritdoc IValidatorPerformanceTracker
    function updateStatistics(
        uint64 proposerIndex,
        uint64[] calldata failedProposerIndices
    ) external override {
        requireAllowed(SystemAddresses.BLOCK);

        uint256 validatorLen = _validators.length;

        // Record successful proposal (skip for NIL blocks where proposerIndex == type(uint64).max)
        // Also skip out-of-bounds indices to match Aptos's non-aborting behavior
        if (proposerIndex != type(uint64).max && proposerIndex < validatorLen) {
            _validators[proposerIndex].successfulProposals++;
        }

        // Record failed proposals
        uint256 failedLen = failedProposerIndices.length;
        for (uint256 f; f < failedLen; ++f) {
            uint64 validatorIndex = failedProposerIndices[f];
            // Skip out-of-bounds indices (Aptos pattern: never abort)
            if (validatorIndex < validatorLen) {
                _validators[validatorIndex].failedProposals++;
            }
        }

        emit PerformanceUpdated(proposerIndex, failedLen);
    }

    /// @inheritdoc IValidatorPerformanceTracker
    function onNewEpoch(
        uint256 activeValidatorCount
    ) external override {
        requireAllowed(SystemAddresses.RECONFIGURATION);

        // Clear existing performance data
        uint256 oldLen = _validators.length;
        for (uint256 i = oldLen; i > 0;) {
            _validators.pop();
            unchecked {
                --i;
            }
        }

        // Re-initialize for the new validator set
        for (uint256 i; i < activeValidatorCount;) {
            _validators.push(IndividualPerformance({ successfulProposals: 0, failedProposals: 0 }));
            unchecked {
                ++i;
            }
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IValidatorPerformanceTracker
    function getPerformance(
        uint64 validatorIndex
    ) external view override returns (uint64 successful, uint64 failed) {
        if (validatorIndex >= _validators.length) {
            return (0, 0);
        }
        IndividualPerformance storage perf = _validators[validatorIndex];
        return (perf.successfulProposals, perf.failedProposals);
    }

    /// @inheritdoc IValidatorPerformanceTracker
    function getAllPerformances() external view override returns (IndividualPerformance[] memory performances) {
        uint256 len = _validators.length;
        performances = new IndividualPerformance[](len);
        for (uint256 i; i < len;) {
            performances[i] = _validators[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IValidatorPerformanceTracker
    function getTrackedValidatorCount() external view override returns (uint256) {
        return _validators.length;
    }

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }
}
