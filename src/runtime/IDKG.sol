// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { RandomnessConfig } from "./RandomnessConfig.sol";
import { ValidatorConsensusInfo } from "../foundation/Types.sol";

/// @title IDKG
/// @author Gravity Team
/// @notice Interface for the DKG contract
interface IDKG {
    /// @notice DKG session metadata (shared with genesis contract)
    struct DKGSessionMetadata {
        /// @notice Epoch number of the dealers (current validators)
        uint64 dealerEpoch;
        /// @notice Randomness configuration for this session
        RandomnessConfig.RandomnessConfigData randomnessConfig;
        /// @notice Current validators who will run DKG (dealers)
        ValidatorConsensusInfo[] dealerValidatorSet;
        /// @notice Next epoch validators who will receive keys (targets)
        ValidatorConsensusInfo[] targetValidatorSet;
    }

    /// @notice Essential DKG session info stored on-chain
    struct DKGSessionInfo {
        /// @notice Session metadata
        DKGSessionMetadata metadata;
        /// @notice When the session started (microseconds)
        uint64 startTimeUs;
        /// @notice DKG transcript (output, set on completion)
        bytes transcript;
    }

    // ========== Session Management (RECONFIGURATION only) ==========

    /// @notice Start a new DKG session
    /// @dev Emits DKGStartEvent with full metadata for consensus engine
    function start(
        uint64 dealerEpoch,
        RandomnessConfig.RandomnessConfigData calldata randomnessConfig,
        ValidatorConsensusInfo[] calldata dealerValidatorSet,
        ValidatorConsensusInfo[] calldata targetValidatorSet
    ) external;

    /// @notice Complete DKG session with transcript
    function finish(
        bytes calldata transcript
    ) external;

    /// @notice Clear incomplete session (no-op if none)
    function tryClearIncompleteSession() external;

    // ========== View Functions ==========

    /// @notice Check if DKG is in progress
    function isInProgress() external view returns (bool);

    /// @notice Get incomplete session info if any
    function getIncompleteSession() external view returns (bool hasSession, DKGSessionInfo memory info);

    /// @notice Get last completed session info if any
    function getLastCompletedSession() external view returns (bool hasSession, DKGSessionInfo memory info);

    /// @notice Get dealer epoch from session info
    function sessionDealerEpoch(
        DKGSessionInfo calldata info
    ) external pure returns (uint64);

    /// @notice Get complete DKG state for debugging
    function getDKGState()
        external
        view
        returns (
            DKGSessionInfo memory lastCompleted,
            bool hasLastCompleted,
            DKGSessionInfo memory inProgress,
            bool hasInProgress
        );
}
