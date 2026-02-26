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
    /// @param targets Contracts that were called
    /// @param datas Calldata that was sent to each target
    event ProposalExecuted(
        uint64 indexed proposalId, address indexed executor, address[] targets, bytes[] datas
    );

    /// @notice Emitted when a proposal is cancelled
    /// @param proposalId ID of the cancelled proposal
    event ProposalCancelled(uint64 indexed proposalId);

    /// @notice Emitted when an executor is added
    /// @param executor Address of the added executor
    event ExecutorAdded(address indexed executor);

    /// @notice Emitted when an executor is removed
    /// @param executor Address of the removed executor
    event ExecutorRemoved(address indexed executor);

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

    /// @notice Check if an address is an authorized executor
    /// @param account Address to check
    /// @return True if the address is an executor
    function isExecutor(
        address account
    ) external view returns (bool);

    /// @notice Get the last vote time for a proposal (atomicity guard)
    /// @dev Resolution must happen strictly after this time to prevent flash loan attacks
    /// @param proposalId ID of the proposal
    /// @return The timestamp of the last vote (0 if no votes cast)
    function getLastVoteTime(
        uint64 proposalId
    ) external view returns (uint64);

    /// @notice Get the earliest time a proposal can be executed (after timelock)
    /// @param proposalId ID of the proposal
    /// @return Earliest execution timestamp in microseconds (0 if not yet resolved)
    function getEarliestExecutionTime(
        uint64 proposalId
    ) external view returns (uint64);

    /// @notice Get the latest time a proposal can be executed (after which it expires)
    /// @param proposalId ID of the proposal
    /// @return Latest execution timestamp in microseconds (0 if not yet resolved)
    function getLatestExecutionTime(
        uint64 proposalId
    ) external view returns (uint64);

    /// @notice Get all authorized executors
    /// @return Array of executor addresses
    function getExecutors() external view returns (address[] memory);

    /// @notice Get the number of authorized executors
    /// @return Number of executors
    function getExecutorCount() external view returns (uint256);

    // ========================================================================
    // PROPOSAL MANAGEMENT
    // ========================================================================

    /// @notice Create a new governance proposal
    /// @dev Caller must be the voter address of the stake pool.
    ///      Pool must have sufficient voting power and lockup >= voting duration.
    ///      Execution hash is computed as keccak256(abi.encode(targets, datas)).
    /// @param stakePool Address of the stake pool to use for proposer stake
    /// @param targets Array of contract addresses to call during execution
    /// @param datas Array of calldata to send to each target
    /// @param metadataUri URI pointing to proposal metadata
    /// @return proposalId The ID of the newly created proposal
    function createProposal(
        address stakePool,
        address[] calldata targets,
        bytes[] calldata datas,
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

    /// @notice Vote on a proposal using full voting power from multiple stake pools
    /// @dev Caller must be the voter address of all stake pools.
    ///      Pools' lockups must extend past proposal expiration.
    /// @param stakePools Array of stake pool addresses to vote with
    /// @param proposalId ID of the proposal to vote on
    /// @param support True to vote yes, false to vote no
    function batchVote(
        address[] calldata stakePools,
        uint64 proposalId,
        bool support
    ) external;

    /// @notice Vote on a proposal using specified voting power from multiple stake pools
    /// @dev Caller must be the voter address of all stake pools.
    ///      Pools' lockups must extend past proposal expiration.
    ///      If votingPower exceeds remaining power for a pool, uses all remaining power.
    /// @param stakePools Array of stake pool addresses to vote with
    /// @param proposalId ID of the proposal to vote on
    /// @param votingPowers Amount of voting power to use from each pool (must match stakePools length)
    /// @param support True to vote yes, false to vote no
    function batchPartialVote(
        address[] calldata stakePools,
        uint64 proposalId,
        uint128[] calldata votingPowers,
        bool support
    ) external;

    /// @notice Resolve a proposal after voting ends or early threshold is met
    /// @dev Anyone can call this function.
    /// @param proposalId ID of the proposal to resolve
    function resolve(
        uint64 proposalId
    ) external;

    /// @notice Cancel a pending proposal
    /// @dev Only the original proposer can cancel. Must be during voting period.
    /// @param proposalId ID of the proposal to cancel
    function cancel(
        uint64 proposalId
    ) external;

    /// @notice Execute an approved proposal
    /// @dev Only authorized executors can call this function.
    ///      The hash of keccak256(abi.encode(targets, datas)) must match the stored execution hash.
    ///      All calls are executed atomically - if any call fails, the entire execution reverts.
    /// @param proposalId ID of the proposal to execute
    /// @param targets Array of contract addresses to call
    /// @param datas Array of calldata to send to each target
    function execute(
        uint64 proposalId,
        address[] calldata targets,
        bytes[] calldata datas
    ) external;

    /// @notice Compute the execution hash for a batch of calls
    /// @dev Useful for off-chain computation before creating proposals
    /// @param targets Array of contract addresses
    /// @param datas Array of calldata
    /// @return The keccak256 hash of abi.encode(targets, datas)
    function computeExecutionHash(
        address[] calldata targets,
        bytes[] calldata datas
    ) external pure returns (bytes32);

    // ========================================================================
    // EXECUTOR MANAGEMENT
    // ========================================================================

    /// @notice Add an address to the authorized executors set
    /// @dev Only the contract owner can call this function.
    /// @param executor Address to add as an executor
    function addExecutor(
        address executor
    ) external;

    /// @notice Remove an address from the authorized executors set
    /// @dev Only the contract owner can call this function.
    /// @param executor Address to remove from executors
    function removeExecutor(
        address executor
    ) external;
}

