// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Proposal, ProposalState} from "../foundation/Types.sol";

/// @title IVoting
/// @author Gravity Team
/// @notice Interface for generic voting engine
/// @dev Used by governance to create proposals, cast votes, and resolve outcomes
interface IVoting {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a proposal is created
    /// @param proposalId Unique proposal identifier
    /// @param proposer Address that created the proposal
    /// @param executionHash Hash of the execution payload
    event ProposalCreated(uint64 indexed proposalId, address indexed proposer, bytes32 executionHash);

    /// @notice Emitted when a vote is cast
    /// @param proposalId Proposal being voted on
    /// @param voter Address casting the vote
    /// @param support True for yes, false for no
    /// @param votingPower Amount of voting power used
    event VoteCast(uint64 indexed proposalId, address indexed voter, bool support, uint128 votingPower);

    /// @notice Emitted when a proposal is resolved
    /// @param proposalId Proposal that was resolved
    /// @param state Final state of the proposal
    event ProposalResolved(uint64 indexed proposalId, ProposalState state);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get proposal details
    /// @param proposalId Proposal identifier
    /// @return Proposal struct
    function getProposal(uint64 proposalId) external view returns (Proposal memory);

    /// @notice Get current state of a proposal
    /// @param proposalId Proposal identifier
    /// @return Current ProposalState
    function getProposalState(uint64 proposalId) external view returns (ProposalState);

    /// @notice Check if voting is closed for a proposal
    /// @param proposalId Proposal identifier
    /// @return True if voting period has ended or proposal is resolved
    function isVotingClosed(uint64 proposalId) external view returns (bool);

    /// @notice Check if proposal can be resolved early (before expiration)
    /// @dev Early resolution is possible if yes or no votes exceed early resolution threshold
    /// @param proposalId Proposal identifier
    /// @return True if proposal can be resolved early
    function canBeResolvedEarly(uint64 proposalId) external view returns (bool);

    /// @notice Get the next proposal ID that will be assigned
    /// @return Next proposal ID
    function getNextProposalId() external view returns (uint64);

    /// @notice Get the early resolution threshold
    /// @return Threshold for early resolution (0 if disabled)
    function getEarlyResolutionThreshold() external view returns (uint128);

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @notice Create a new proposal
    /// @param proposer Address creating the proposal
    /// @param executionHash Hash of the execution payload
    /// @param metadataUri URI pointing to proposal metadata (IPFS/URL)
    /// @param minVoteThreshold Minimum total votes required for quorum
    /// @param votingDurationMicros Voting period duration in microseconds
    /// @return proposalId Unique identifier for the created proposal
    function createProposal(
        address proposer,
        bytes32 executionHash,
        string calldata metadataUri,
        uint128 minVoteThreshold,
        uint64 votingDurationMicros
    ) external returns (uint64 proposalId);

    /// @notice Cast a vote on a proposal
    /// @param proposalId Proposal to vote on
    /// @param voter Address casting the vote
    /// @param votingPower Amount of voting power to use
    /// @param support True for yes vote, false for no vote
    function vote(uint64 proposalId, address voter, uint128 votingPower, bool support) external;

    /// @notice Resolve a proposal after voting ends
    /// @dev Can be called by anyone once voting period ends or early resolution threshold met
    /// @param proposalId Proposal to resolve
    /// @return Final state of the proposal
    function resolve(uint64 proposalId) external returns (ProposalState);

    /// @notice Set the early resolution threshold
    /// @dev Only callable by TIMELOCK (governance)
    /// @param threshold New threshold (0 to disable early resolution)
    function setEarlyResolutionThreshold(uint128 threshold) external;
}

