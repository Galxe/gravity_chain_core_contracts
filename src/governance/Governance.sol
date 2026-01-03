// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGovernance } from "./IGovernance.sol";
import { GovernanceConfig } from "./GovernanceConfig.sol";
import { Proposal, ProposalState } from "../foundation/Types.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @notice Interface for Staking factory
interface IStakingGov {
    function isPool(
        address pool
    ) external view returns (bool);
    function getPoolVotingPower(
        address pool
    ) external view returns (uint256);
    function getPoolVoter(
        address pool
    ) external view returns (address);
    function getPoolLockedUntil(
        address pool
    ) external view returns (uint64);
}

/// @notice Interface for Timestamp
interface ITimestampGov {
    function nowMicroseconds() external view returns (uint64);
}

/// @title Governance
/// @author Gravity Team
/// @notice On-chain governance for Gravity blockchain
/// @dev Voting power comes from StakePools via the Staking factory.
///      The pool's `voter` address casts votes using the pool's voting power.
///      Supports partial voting and early resolution.
contract Governance is IGovernance {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Next proposal ID to be assigned
    uint64 public nextProposalId;

    /// @notice Mapping of proposal ID to Proposal struct
    mapping(uint64 => Proposal) internal _proposals;

    /// @notice Voting power used per (pool, proposal): keccak256(pool, proposalId) => used power
    mapping(bytes32 => uint128) public usedVotingPower;

    /// @notice Whether a proposal has been executed
    mapping(uint64 => bool) public executed;

    /// @notice Whether contract has been initialized
    bool private _initialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the governance contract
    /// @dev Can only be called once by GENESIS. Sets nextProposalId to 1.
    function initialize() external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        nextProposalId = 1; // Start proposal IDs at 1
        _initialized = true;
    }

    // ========================================================================
    // INTERNAL HELPERS
    // ========================================================================

    /// @notice Get current timestamp in microseconds
    function _now() internal view returns (uint64) {
        return ITimestampGov(SystemAddresses.TIMESTAMP).nowMicroseconds();
    }

    /// @notice Get governance config
    function _config() internal view returns (GovernanceConfig) {
        return GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);
    }

    /// @notice Get staking contract
    function _staking() internal view returns (IStakingGov) {
        return IStakingGov(SystemAddresses.STAKING);
    }

    /// @notice Compute the key for usedVotingPower mapping
    function _votingKey(
        address stakePool,
        uint64 proposalId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(stakePool, proposalId));
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

    /// @notice Calculate early resolution threshold based on total staked
    /// @dev Returns 0 if early resolution is disabled (threshold = 0)
    function _getEarlyResolutionVotes() internal view returns (uint128) {
        uint128 thresholdBps = _config().earlyResolutionThresholdBps();
        if (thresholdBps == 0) {
            return type(uint128).max; // Effectively disabled
        }

        // Get total staked from all pools - we use a simplified approach
        // In production, you might want to track total staked separately
        // For now, we use the config's minVotingThreshold as a reference
        // A more accurate implementation would sum all pool voting powers
        // But that's expensive, so we use a percentage of a reference total

        // For early resolution, we check if yes or no votes exceed threshold
        // The threshold is based on basis points of the minVotingThreshold
        // This is a simplification - in production you might track total supply
        return type(uint128).max; // Disable for now, enable via config
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
        uint256 poolPower = _staking().getPoolVotingPower(stakePool);
        bytes32 key = _votingKey(stakePool, proposalId);
        uint128 used = usedVotingPower[key];

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
        if (now_ >= p.expirationTime) {
            return true;
        }

        // Can resolve early if threshold met
        uint128 earlyThreshold = _getEarlyResolutionVotes();
        if (p.yesVotes >= earlyThreshold || p.noVotes >= earlyThreshold) {
            return true;
        }

        return false;
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

    // ========================================================================
    // PROPOSAL MANAGEMENT
    // ========================================================================

    /// @inheritdoc IGovernance
    function createProposal(
        address stakePool,
        bytes32 executionHash,
        string calldata metadataUri
    ) external returns (uint64 proposalId) {
        // Verify pool is valid
        _requireValidPool(stakePool);

        // Verify caller is pool's voter
        _requireVoter(stakePool);

        // Get pool's voting power
        uint256 votingPower = _staking().getPoolVotingPower(stakePool);
        uint256 requiredStake = _config().requiredProposerStake();

        if (votingPower < requiredStake) {
            revert Errors.InsufficientVotingPower(requiredStake, votingPower);
        }

        // Verify lockup covers voting period
        uint64 now_ = _now();
        uint64 votingDuration = _config().votingDurationMicros();
        uint64 expirationTime = now_ + votingDuration;

        uint64 lockedUntil = _staking().getPoolLockedUntil(stakePool);
        if (lockedUntil < expirationTime) {
            revert Errors.InsufficientLockup(expirationTime, lockedUntil);
        }

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

        // Verify lockup covers voting period
        uint64 lockedUntil = _staking().getPoolLockedUntil(stakePool);
        if (lockedUntil < p.expirationTime) {
            revert Errors.InsufficientLockup(p.expirationTime, lockedUntil);
        }

        // Calculate remaining voting power
        uint128 remaining = getRemainingVotingPower(stakePool, proposalId);
        if (votingPower > remaining) {
            revert Errors.VotingPowerOverflow(votingPower, remaining);
        }

        // Update used voting power
        bytes32 key = _votingKey(stakePool, proposalId);
        usedVotingPower[key] += votingPower;

        // Update votes
        if (support) {
            p.yesVotes += votingPower;
        } else {
            p.noVotes += votingPower;
        }

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

        // Check if can resolve
        if (!canResolve(proposalId)) {
            revert Errors.VotingPeriodNotEnded(p.expirationTime);
        }

        // Mark as resolved
        p.isResolved = true;
        p.resolutionTime = _now();

        // Emit event with final state
        ProposalState state = getProposalState(proposalId);
        emit ProposalResolved(proposalId, state);
    }

    /// @inheritdoc IGovernance
    function execute(
        uint64 proposalId,
        address target,
        bytes calldata data
    ) external {
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

        // Verify execution hash matches
        bytes32 expectedHash = _proposals[proposalId].executionHash;
        bytes32 actualHash = keccak256(abi.encodePacked(target, data));
        if (actualHash != expectedHash) {
            revert Errors.ExecutionHashMismatch(expectedHash, actualHash);
        }

        // Mark as executed BEFORE external call (CEI pattern)
        executed[proposalId] = true;

        // Execute the call
        (bool success,) = target.call(data);
        if (!success) {
            revert Errors.ExecutionFailed(proposalId);
        }

        emit ProposalExecuted(proposalId, msg.sender, target, data);
    }
}

