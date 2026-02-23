// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGovernance } from "./IGovernance.sol";
import { GovernanceConfig } from "../runtime/GovernanceConfig.sol";
import { Proposal, ProposalState } from "../foundation/Types.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { Errors } from "../foundation/Errors.sol";
import { IStaking } from "../staking/IStaking.sol";
import { ITimestamp } from "../runtime/ITimestamp.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";
import { EnumerableSet } from "@openzeppelin/utils/structs/EnumerableSet.sol";

/// @title Governance
/// @author Gravity Team
/// @notice On-chain governance for Gravity blockchain
/// @dev Voting power comes from StakePools via the Staking factory.
///      The pool's `voter` address casts votes using the pool's voting power.
///      Supports partial voting.
///      Proposal execution is restricted to authorized executors managed by the owner.
contract Governance is IGovernance, Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Next proposal ID to be assigned
    uint64 public nextProposalId = 1;

    /// @notice Mapping of proposal ID to Proposal struct
    mapping(uint64 => Proposal) internal _proposals;

    /// @notice Voting power used per pool per proposal: pool => proposalId => used power
    mapping(address => mapping(uint64 => uint128)) public usedVotingPower;

    /// @notice Whether a proposal has been executed
    mapping(uint64 => bool) public executed;

    /// @notice Last vote time for each proposal (for atomicity guard / flash loan protection)
    /// @dev Resolution must happen in a later timestamp than the last vote
    mapping(uint64 => uint64) public lastVoteTime;

    /// @notice Whether a proposal has been cancelled
    mapping(uint64 => bool) public cancelled;

    /// @notice Set of authorized executors
    EnumerableSet.AddressSet private _executors;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Initialize the Governance contract with an owner
    /// @param initialOwner Address of the initial contract owner
    constructor(
        address initialOwner
    ) Ownable(initialOwner) { }

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Restricts function access to authorized executors
    modifier onlyExecutor() {
        if (!_executors.contains(msg.sender)) {
            revert Errors.NotExecutor(msg.sender);
        }
        _;
    }

    // ========================================================================
    // INTERNAL HELPERS
    // ========================================================================

    /// @notice Get current timestamp in microseconds
    function _now() internal view returns (uint64) {
        return ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
    }

    /// @notice Get governance config
    function _config() internal pure returns (GovernanceConfig) {
        return GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);
    }

    /// @notice Get staking contract
    function _staking() internal pure returns (IStaking) {
        return IStaking(SystemAddresses.STAKING);
    }

    /// @notice Verify caller is the pool's voter
    function _requireVoter(
        address stakePool
    ) internal view {
        address voter = _staking().getPoolVoter(stakePool);
        if (msg.sender != voter) {
            revert Errors.NotDelegatedVoter(voter, msg.sender);
        }
    }

    /// @notice Verify pool is valid
    function _requireValidPool(
        address stakePool
    ) internal view {
        if (!_staking().isPool(stakePool)) {
            revert Errors.InvalidPool(stakePool);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGovernance
    function getProposal(
        uint64 proposalId
    ) external view returns (Proposal memory) {
        if (_proposals[proposalId].id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }
        return _proposals[proposalId];
    }

    /// @inheritdoc IGovernance
    function getProposalState(
        uint64 proposalId
    ) public view returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];
        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        // Check if executed
        if (executed[proposalId]) {
            return ProposalState.EXECUTED;
        }

        // Check if cancelled
        if (cancelled[proposalId]) {
            return ProposalState.CANCELLED;
        }

        // Check if resolved
        if (p.isResolved) {
            // Determine if it passed
            if (p.yesVotes > p.noVotes && p.yesVotes + p.noVotes >= p.minVoteThreshold) {
                return ProposalState.SUCCEEDED;
            }
            return ProposalState.FAILED;
        }

        // Not resolved yet
        uint64 now_ = _now();
        if (now_ < p.expirationTime) {
            return ProposalState.PENDING;
        }

        // Voting ended but not resolved - determine outcome
        if (p.yesVotes > p.noVotes && p.yesVotes + p.noVotes >= p.minVoteThreshold) {
            return ProposalState.SUCCEEDED;
        }
        return ProposalState.FAILED;
    }

    /// @inheritdoc IGovernance
    function getRemainingVotingPower(
        address stakePool,
        uint64 proposalId
    ) public view returns (uint128) {
        Proposal storage p = _proposals[proposalId];
        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        // Get voting power at proposal's creation time (snapshot-based)
        uint256 poolPower = _staking().getPoolVotingPower(stakePool, p.creationTime);
        uint128 used = usedVotingPower[stakePool][proposalId];

        if (poolPower <= used) {
            return 0;
        }
        return uint128(poolPower - used);
    }

    /// @inheritdoc IGovernance
    function canResolve(
        uint64 proposalId
    ) public view returns (bool) {
        Proposal storage p = _proposals[proposalId];
        if (p.id == 0 || p.isResolved) {
            return false;
        }

        uint64 now_ = _now();

        // Can resolve if voting period ended
        if (now_ < p.expirationTime) {
            return false;
        }

        // Atomicity guard: resolution must happen strictly after the last vote
        // This prevents flash loan attacks where someone borrows tokens, votes, and resolves in the same tx
        uint64 lastVote = lastVoteTime[proposalId];
        if (lastVote > 0 && now_ <= lastVote) {
            return false;
        }

        return true;
    }

    /// @inheritdoc IGovernance
    function getExecutionHash(
        uint64 proposalId
    ) external view returns (bytes32) {
        if (_proposals[proposalId].id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }
        return _proposals[proposalId].executionHash;
    }

    /// @inheritdoc IGovernance
    function getNextProposalId() external view returns (uint64) {
        return nextProposalId;
    }

    /// @inheritdoc IGovernance
    function isExecuted(
        uint64 proposalId
    ) external view returns (bool) {
        return executed[proposalId];
    }

    /// @inheritdoc IGovernance
    function isExecutor(
        address account
    ) external view returns (bool) {
        return _executors.contains(account);
    }

    /// @inheritdoc IGovernance
    function getExecutors() external view returns (address[] memory) {
        return _executors.values();
    }

    /// @inheritdoc IGovernance
    function getExecutorCount() external view returns (uint256) {
        return _executors.length();
    }

    /// @inheritdoc IGovernance
    function getLastVoteTime(
        uint64 proposalId
    ) external view returns (uint64) {
        return lastVoteTime[proposalId];
    }

    /// @inheritdoc IGovernance
    function getEarliestExecutionTime(
        uint64 proposalId
    ) external view returns (uint64) {
        Proposal storage p = _proposals[proposalId];
        if (p.id == 0) revert Errors.ProposalNotFound(proposalId);
        if (!p.isResolved) return 0;
        return p.resolutionTime + _config().executionDelayMicros();
    }

    /// @inheritdoc IGovernance
    function getLatestExecutionTime(
        uint64 proposalId
    ) external view returns (uint64) {
        Proposal storage p = _proposals[proposalId];
        if (p.id == 0) revert Errors.ProposalNotFound(proposalId);
        if (!p.isResolved) return 0;
        return p.resolutionTime + _config().executionDelayMicros() + _config().executionWindowMicros();
    }

    // ========================================================================
    // PROPOSAL MANAGEMENT
    // ========================================================================

    /// @inheritdoc IGovernance
    function createProposal(
        address stakePool,
        address[] calldata targets,
        bytes[] calldata datas,
        string calldata metadataUri
    ) external returns (uint64 proposalId) {
        // Validate batch arrays
        if (targets.length != datas.length) {
            revert Errors.ProposalArrayLengthMismatch(targets.length, datas.length);
        }
        if (targets.length == 0) {
            revert Errors.EmptyProposalBatch();
        }

        // Verify pool is valid
        _requireValidPool(stakePool);

        // Verify caller is pool's voter
        _requireVoter(stakePool);

        // Calculate proposal expiration time
        uint64 now_ = _now();
        uint64 votingDuration = _config().votingDurationMicros();
        uint64 expirationTime = now_ + votingDuration;

        // Get pool's voting power at creation time (snapshot-based)
        uint256 votingPower = _staking().getPoolVotingPower(stakePool, now_);
        uint256 requiredStake = _config().requiredProposerStake();

        if (votingPower < requiredStake) {
            revert Errors.InsufficientVotingPower(requiredStake, votingPower);
        }

        // Compute execution hash from batch arrays
        bytes32 executionHash = keccak256(abi.encode(targets, datas));

        // Create proposal
        proposalId = nextProposalId++;

        _proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            executionHash: executionHash,
            metadataUri: metadataUri,
            creationTime: now_,
            expirationTime: expirationTime,
            minVoteThreshold: _config().minVotingThreshold(),
            yesVotes: 0,
            noVotes: 0,
            isResolved: false,
            resolutionTime: 0
        });

        emit ProposalCreated(proposalId, msg.sender, stakePool, executionHash, metadataUri);
    }

    /// @inheritdoc IGovernance
    function vote(
        address stakePool,
        uint64 proposalId,
        uint128 votingPower,
        bool support
    ) external {
        _voteInternal(stakePool, proposalId, votingPower, support);
    }

    /// @inheritdoc IGovernance
    function batchVote(
        address[] calldata stakePools,
        uint64 proposalId,
        bool support
    ) external {
        uint256 len = stakePools.length;
        for (uint256 i = 0; i < len; ++i) {
            // Use type(uint128).max to vote with all remaining power (similar to Aptos's MAX_U64)
            _voteInternal(stakePools[i], proposalId, type(uint128).max, support);
        }
    }

    /// @inheritdoc IGovernance
    function batchPartialVote(
        address[] calldata stakePools,
        uint64 proposalId,
        uint128 votingPower,
        bool support
    ) external {
        uint256 len = stakePools.length;
        for (uint256 i = 0; i < len; ++i) {
            _voteInternal(stakePools[i], proposalId, votingPower, support);
        }
    }

    /// @notice Internal voting logic for a single stake pool
    /// @dev If votingPower exceeds remaining power, uses all remaining power (no revert).
    /// @param stakePool Address of the stake pool to vote with
    /// @param proposalId ID of the proposal to vote on
    /// @param votingPower Amount of voting power to use (capped at remaining power)
    /// @param support True to vote yes, false to vote no
    function _voteInternal(
        address stakePool,
        uint64 proposalId,
        uint128 votingPower,
        bool support
    ) internal {
        Proposal storage p = _proposals[proposalId];

        // Verify proposal exists
        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        // Verify voting period not ended
        uint64 now_ = _now();
        if (now_ >= p.expirationTime) {
            revert Errors.VotingPeriodEnded(p.expirationTime);
        }

        // Verify proposal not already resolved
        if (p.isResolved) {
            revert Errors.ProposalAlreadyResolved(proposalId);
        }

        // Verify pool is valid
        _requireValidPool(stakePool);

        // Verify caller is pool's voter
        _requireVoter(stakePool);

        // Calculate remaining voting power (uses voting power at expiration time,
        // which inherently checks that lockup covers the voting period)
        uint128 remaining = getRemainingVotingPower(stakePool, proposalId);

        // Cap voting power at remaining (similar to Aptos's min(voting_power, staking_pool_voting_power))
        if (votingPower > remaining) {
            votingPower = remaining;
        }

        // Skip if no voting power to use
        if (votingPower == 0) {
            return;
        }

        // Update used voting power
        usedVotingPower[stakePool][proposalId] += votingPower;

        // Update votes
        if (support) {
            p.yesVotes += votingPower;
        } else {
            p.noVotes += votingPower;
        }

        // Record last vote time for atomicity guard (flash loan protection)
        // Resolution cannot happen in the same timestamp as the last vote
        lastVoteTime[proposalId] = now_;

        emit VoteCast(proposalId, msg.sender, stakePool, votingPower, support);
    }

    /// @inheritdoc IGovernance
    function resolve(
        uint64 proposalId
    ) external {
        Proposal storage p = _proposals[proposalId];

        // Verify proposal exists
        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        // Verify not already resolved
        if (p.isResolved) {
            revert Errors.ProposalAlreadyResolved(proposalId);
        }

        uint64 now_ = _now();

        // Check voting period has ended
        if (now_ < p.expirationTime) {
            revert Errors.VotingPeriodNotEnded(p.expirationTime);
        }

        // Atomicity guard: resolution must happen strictly after the last vote
        // This prevents flash loan attacks where someone borrows tokens, votes, and resolves in the same tx
        uint64 lastVote = lastVoteTime[proposalId];
        if (lastVote > 0 && now_ <= lastVote) {
            revert Errors.ResolutionCannotBeAtomic(lastVote);
        }

        // Mark as resolved
        p.isResolved = true;
        p.resolutionTime = now_;

        // Emit event with final state
        ProposalState state = getProposalState(proposalId);
        emit ProposalResolved(proposalId, state);
    }

    /// @inheritdoc IGovernance
    function cancel(
        uint64 proposalId
    ) external {
        Proposal storage p = _proposals[proposalId];
        if (p.id == 0) revert Errors.ProposalNotFound(proposalId);
        if (p.isResolved) revert Errors.ProposalAlreadyResolved(proposalId);
        if (executed[proposalId]) revert Errors.ProposalAlreadyExecuted(proposalId);
        if (msg.sender != p.proposer) revert Errors.NotAuthorizedToCancel(msg.sender);

        uint64 now_ = _now();
        if (now_ >= p.expirationTime) revert Errors.VotingPeriodEnded(p.expirationTime);

        cancelled[proposalId] = true;
        p.isResolved = true;
        p.resolutionTime = now_;

        emit ProposalCancelled(proposalId);
    }

    /// @inheritdoc IGovernance
    function execute(
        uint64 proposalId,
        address[] calldata targets,
        bytes[] calldata datas
    ) external onlyExecutor {
        // Validate batch arrays
        if (targets.length != datas.length) {
            revert Errors.ProposalArrayLengthMismatch(targets.length, datas.length);
        }
        if (targets.length == 0) {
            revert Errors.EmptyProposalBatch();
        }

        // Verify proposal exists
        if (_proposals[proposalId].id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        // Verify not already executed (check this before state to get correct error)
        if (executed[proposalId]) {
            revert Errors.ProposalAlreadyExecuted(proposalId);
        }

        // Verify proposal succeeded
        ProposalState state = getProposalState(proposalId);
        if (state != ProposalState.SUCCEEDED) {
            revert Errors.ProposalNotSucceeded(proposalId);
        }

        // Verify execution delay has passed (timelock)
        uint64 executionDelay = _config().executionDelayMicros();
        uint64 earliestExecution = _proposals[proposalId].resolutionTime + executionDelay;
        uint64 now_ = _now();
        if (now_ < earliestExecution) {
            revert Errors.ExecutionDelayNotMet(earliestExecution, now_);
        }

        // Verify execution window has not expired
        uint64 executionWindow = _config().executionWindowMicros();
        uint64 latestExecution = earliestExecution + executionWindow;
        if (now_ > latestExecution) {
            revert Errors.ProposalExecutionExpired(proposalId);
        }

        // Verify execution hash matches
        bytes32 expectedHash = _proposals[proposalId].executionHash;
        bytes32 actualHash = keccak256(abi.encode(targets, datas));
        if (actualHash != expectedHash) {
            revert Errors.ExecutionHashMismatch(expectedHash, actualHash);
        }

        // Mark as executed BEFORE external calls (CEI pattern)
        executed[proposalId] = true;

        // Execute all calls atomically
        uint256 len = targets.length;
        for (uint256 i = 0; i < len; ++i) {
            (bool success,) = targets[i].call(datas[i]);
            if (!success) {
                revert Errors.ExecutionFailed(proposalId);
            }
        }

        emit ProposalExecuted(proposalId, msg.sender, targets, datas);
    }

    /// @notice Compute the execution hash for a batch of calls
    /// @dev Useful for off-chain computation before creating proposals
    /// @param targets Array of contract addresses
    /// @param datas Array of calldata
    /// @return The keccak256 hash of abi.encode(targets, datas)
    function computeExecutionHash(
        address[] calldata targets,
        bytes[] calldata datas
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(targets, datas));
    }

    // ========================================================================
    // EXECUTOR MANAGEMENT
    // ========================================================================

    /// @inheritdoc IGovernance
    function addExecutor(
        address executor
    ) external onlyOwner {
        if (_executors.add(executor)) {
            emit ExecutorAdded(executor);
        }
    }

    /// @inheritdoc IGovernance
    function removeExecutor(
        address executor
    ) external onlyOwner {
        if (_executors.remove(executor)) {
            emit ExecutorRemoved(executor);
        }
    }
}

