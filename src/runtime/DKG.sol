// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";
import { ValidatorConsensusInfo } from "../foundation/Types.sol";
import { RandomnessConfig } from "./RandomnessConfig.sol";
import { IDKG } from "./IDKG.sol";
import { ITimestamp } from "./ITimestamp.sol";

/// @title DKG
/// @author Gravity Team
/// @notice Distributed Key Generation on-chain state management
/// @dev Manages DKG session lifecycle for epoch transitions.
///      The consensus engine listens for DKGStartEvent to begin off-chain DKG.
///      Only RECONFIGURATION can start/finish sessions.
///      Note: Full validator arrays are emitted in events only (not stored in contract state)
///      to avoid storage limitations with dynamic arrays.
contract DKG is IDKG {
    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Full DKG session metadata for events
    /// @dev Emitted in DKGStartEvent for consensus engine
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

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice In-progress DKG session info (if any)
    IDKG.DKGSessionInfo private _inProgress;

    /// @notice Last completed DKG session info (if any)
    IDKG.DKGSessionInfo private _lastCompleted;

    /// @notice Whether an in-progress session exists
    bool public hasInProgress;

    /// @notice Whether a last completed session exists
    bool public hasLastCompleted;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a DKG session starts
    /// @dev Consensus engine listens for this event to begin off-chain DKG.
    ///      Contains full metadata including validator sets.
    /// @param dealerEpoch Epoch of the dealer validators
    /// @param startTimeUs When the session started (microseconds)
    /// @param metadata Full session metadata for consensus engine
    event DKGStartEvent(uint64 indexed dealerEpoch, uint64 startTimeUs, DKGSessionMetadata metadata);

    /// @notice Emitted when a DKG session completes
    /// @param dealerEpoch Epoch of the dealer validators
    /// @param transcriptHash Hash of the DKG transcript
    event DKGCompleted(uint64 indexed dealerEpoch, bytes32 transcriptHash);

    /// @notice Emitted when an incomplete session is cleared
    /// @param dealerEpoch Epoch of the cleared session
    event DKGSessionCleared(uint64 indexed dealerEpoch);

    // ========================================================================
    // SESSION MANAGEMENT (RECONFIGURATION only)
    // ========================================================================

    /// @notice Start a new DKG session
    /// @dev Called by RECONFIGURATION during epoch transition start.
    ///      Emits DKGStartEvent with full metadata for consensus engine to listen.
    /// @param dealerEpoch Current epoch number
    /// @param randomnessConfig Randomness configuration for this session
    /// @param dealerValidatorSet Current validators who will run DKG
    /// @param targetValidatorSet Next epoch validators who will receive keys
    function start(
        uint64 dealerEpoch,
        RandomnessConfig.RandomnessConfigData calldata randomnessConfig,
        ValidatorConsensusInfo[] calldata dealerValidatorSet,
        ValidatorConsensusInfo[] calldata targetValidatorSet
    ) external override {
        requireAllowed(SystemAddresses.RECONFIGURATION);

        // Cannot start if already in progress
        if (hasInProgress) {
            revert Errors.DKGInProgress();
        }

        // Get current timestamp from Timestamp contract
        uint64 startTimeUs = _getCurrentTimeMicros();

        // Store essential session info on-chain
        // TODO(lightman): validator's voting power needs to be uint64 on the consensus engine.
        _inProgress = IDKG.DKGSessionInfo({
            dealerEpoch: dealerEpoch,
            configVariant: randomnessConfig.variant,
            dealerCount: uint64(dealerValidatorSet.length),
            targetCount: uint64(targetValidatorSet.length),
            startTimeUs: startTimeUs,
            transcript: ""
        });
        hasInProgress = true;

        // Emit full metadata in event for consensus engine
        // Note: We create the memory struct here to include the calldata arrays
        DKGSessionMetadata memory metadata = DKGSessionMetadata({
            dealerEpoch: dealerEpoch,
            randomnessConfig: randomnessConfig,
            dealerValidatorSet: dealerValidatorSet,
            targetValidatorSet: targetValidatorSet
        });

        emit DKGStartEvent(dealerEpoch, startTimeUs, metadata);
    }

    /// @notice Complete a DKG session with the generated transcript
    /// @dev Called by RECONFIGURATION after DKG completes off-chain
    /// @param transcript The DKG transcript from consensus engine
    function finish(
        bytes calldata transcript
    ) external override {
        requireAllowed(SystemAddresses.RECONFIGURATION);

        if (!hasInProgress) {
            revert Errors.DKGNotInProgress();
        }

        uint64 dealerEpoch = _inProgress.dealerEpoch;

        // Store transcript and move to completed
        _inProgress.transcript = transcript;
        _lastCompleted = _inProgress;
        hasLastCompleted = true;

        // Clear in-progress
        _clearInProgress();

        emit DKGCompleted(dealerEpoch, keccak256(transcript));
    }

    /// @notice Clear an incomplete DKG session
    /// @dev Called by RECONFIGURATION to clean up stale sessions.
    ///      No-op if no session is in progress.
    function tryClearIncompleteSession() external override {
        requireAllowed(SystemAddresses.RECONFIGURATION);

        if (!hasInProgress) {
            // Nothing to clear
            return;
        }

        uint64 dealerEpoch = _inProgress.dealerEpoch;
        _clearInProgress();

        emit DKGSessionCleared(dealerEpoch);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check if a DKG session is in progress
    /// @return True if a session is in progress
    function isInProgress() external view override returns (bool) {
        return hasInProgress;
    }

    /// @notice Get the incomplete session info if any
    /// @return hasSession Whether an in-progress session exists
    /// @return info Session info (only valid if hasSession is true)
    function getIncompleteSession() external view override returns (bool hasSession, IDKG.DKGSessionInfo memory info) {
        if (hasInProgress) {
            return (true, _inProgress);
        }
        return (false, info);
    }

    /// @notice Get the last completed session info if any
    /// @return hasSession Whether a completed session exists
    /// @return info Session info (only valid if hasSession is true)
    function getLastCompletedSession()
        external
        view
        override
        returns (bool hasSession, IDKG.DKGSessionInfo memory info)
    {
        if (hasLastCompleted) {
            return (true, _lastCompleted);
        }
        return (false, info);
    }

    /// @notice Get the dealer epoch from session info
    /// @param info Session info to query
    /// @return The dealer epoch
    function sessionDealerEpoch(
        IDKG.DKGSessionInfo calldata info
    ) external pure override returns (uint64) {
        return info.dealerEpoch;
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Get current timestamp in microseconds from Timestamp contract
    /// @return Current time in microseconds
    function _getCurrentTimeMicros() internal view returns (uint64) {
        return ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
    }

    /// @notice Clear the in-progress session storage
    function _clearInProgress() internal {
        delete _inProgress;
        hasInProgress = false;
    }
}
