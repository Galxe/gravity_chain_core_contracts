// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Proposal, ProposalState } from "../foundation/Types.sol";

/// @title IGovernance
/// @author Gravity Team
/// @notice Interface for on-chain governance
/// @dev Voting power is derived from StakePools via the Staking factory.
///      The pool's `voter` address casts votes using the pool's voting power.
interface IGovernance {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new proposal is created
    /// @param proposalId Unique identifier for the proposal
    /// @param proposer Address that created the proposal (pool's voter)
    /// @param stakePool StakePool used for proposer's voting power
    /// @param executionHash Hash of (target, calldata) for execution
    /// @param metadataUri URI to proposal metadata (IPFS, etc.)
    event ProposalCreated(
        uint64 indexed proposalId,
        address indexed proposer,
        address indexed stakePool,
        bytes32 executionHash,
        string metadataUri
    );

    /// @notice Emitted when a vote is cast
    /// @param proposalId ID of the proposal being voted on
    /// @param voter Address that cast the vote (pool's voter)
    /// @param stakePool StakePool whose voting power was used
    /// @param votingPower Amount of voting power used
    /// @param support True for yes, false for no
    event VoteCast(
        uint64 indexed proposalId, address indexed voter, address indexed stakePool, uint128 votingPower, bool support
    );

    /// @notice Emitted when a proposal is resolved
    /// @param proposalId ID of the resolved proposal
    /// @param state Final state of the proposal
    event ProposalResolved(uint64 indexed proposalId, ProposalState state);

    /// @notice Emitted when a proposal is executed
    /// @param proposalId ID of the executed proposal
    /// @param executor Address that executed the proposal
    /// @param target Contract that was called
    /// @param data Calldata that was sent
    event ProposalExecuted(uint64 indexed proposalId, address indexed executor, address target, bytes data);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get a proposal by ID
    /// @param proposalId ID of the proposal
    /// @return The proposal struct
    function getProposal(
        uint64 proposalId
    ) external view returns (Proposal memory);

    /// @notice Get the current state of a proposal
    /// @param proposalId ID of the proposal
    /// @return Current state (PENDING, SUCCEEDED, FAILED, EXECUTED, CANCELLED)
    function getProposalState(
        uint64 proposalId
    ) external view returns (ProposalState);

    /// @notice Get the remaining voting power a pool can use on a proposal
    /// @param stakePool Address of the stake pool
    /// @param proposalId ID of the proposal
    /// @return Remaining voting power available
    function getRemainingVotingPower(
        address stakePool,
        uint64 proposalId
    ) external view returns (uint128);

    /// @notice Check if a proposal can be resolved
    /// @param proposalId ID of the proposal
    /// @return True if the proposal can be resolved
    function canResolve(
        uint64 proposalId
    ) external view returns (bool);

    /// @notice Get the execution hash of a proposal
    /// @param proposalId ID of the proposal
    /// @return The stored execution hash
    function getExecutionHash(
        uint64 proposalId
    ) external view returns (bytes32);

    /// @notice Get the next proposal ID that will be assigned
    /// @return The next proposal ID
    function getNextProposalId() external view returns (uint64);

    /// @notice Check if a proposal has been executed
    /// @param proposalId ID of the proposal
    /// @return True if executed
    function isExecuted(
        uint64 proposalId
    ) external view returns (bool);

    // ========================================================================
    // PROPOSAL MANAGEMENT
    // ========================================================================

    /// @notice Create a new governance proposal
    /// @dev Caller must be the voter address of the stake pool.
    ///      Pool must have sufficient voting power and lockup >= voting duration.
    /// @param stakePool Address of the stake pool to use for proposer stake
    /// @param executionHash Hash of keccak256(abi.encodePacked(target, calldata))
    /// @param metadataUri URI pointing to proposal metadata
    /// @return proposalId The ID of the newly created proposal
    function createProposal(
        address stakePool,
        bytes32 executionHash,
        string calldata metadataUri
    ) external returns (uint64 proposalId);

    /// @notice Vote on a proposal using a stake pool's voting power
    /// @dev Caller must be the voter address of the stake pool.
    ///      Pool's lockup must extend past proposal expiration.
    /// @param stakePool Address of the stake pool to vote with
    /// @param proposalId ID of the proposal to vote on
    /// @param votingPower Amount of voting power to use
    /// @param support True to vote yes, false to vote no
    function vote(
        address stakePool,
        uint64 proposalId,
        uint128 votingPower,
        bool support
    ) external;

    /// @notice Resolve a proposal after voting ends or early threshold is met
    /// @dev Anyone can call this function.
    /// @param proposalId ID of the proposal to resolve
    function resolve(
        uint64 proposalId
    ) external;

    /// @notice Execute an approved proposal
    /// @dev Anyone can call this function.
    ///      The hash of (target, data) must match the stored execution hash.
    /// @param proposalId ID of the proposal to execute
    /// @param target Contract address to call
    /// @param data Calldata to send to the target
    function execute(
        uint64 proposalId,
        address target,
        bytes calldata data
    ) external;
}

