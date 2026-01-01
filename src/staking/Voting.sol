// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IVoting} from "./IVoting.sol";
import {Proposal, ProposalState} from "../foundation/Types.sol";
import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {requireAllowed} from "../foundation/SystemAccessControl.sol";
import {Errors} from "../foundation/Errors.sol";

/// @notice Interface for Timestamp contract
interface ITimestampVoting {
    function nowMicroseconds() external view returns (uint64);
}

/// @title Voting
/// @author Gravity Team
/// @notice Generic proposal/vote/resolve engine for governance
/// @dev Provides core voting mechanics used by higher-level governance contracts
contract Voting is IVoting {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Next proposal ID to be assigned
    uint64 public nextProposalId;

    /// @notice Mapping of proposal ID to proposal data
    mapping(uint64 => Proposal) internal _proposals;

    /// @notice Early resolution threshold
    /// @dev If yes or no votes exceed this threshold, proposal can be resolved early
    ///      Set to 0 to disable early resolution
    uint128 public earlyResolutionThreshold;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    constructor() {
        nextProposalId = 1; // Start proposal IDs at 1
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IVoting
    function getProposal(uint64 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    /// @inheritdoc IVoting
    function getProposalState(uint64 proposalId) public view returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];

        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        // If already resolved, return the appropriate state
        if (p.isResolved) {
            // Check if it passed
            if (p.yesVotes > p.noVotes && (p.yesVotes + p.noVotes) >= p.minVoteThreshold) {
                return ProposalState.EXECUTED;
            }
            return ProposalState.FAILED;
        }

        uint64 now_ = ITimestampVoting(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // Still in voting period
        if (now_ < p.expirationTime) {
            return ProposalState.PENDING;
        }

        // Voting ended, determine outcome
        if (p.yesVotes > p.noVotes && (p.yesVotes + p.noVotes) >= p.minVoteThreshold) {
            return ProposalState.SUCCEEDED;
        }

        return ProposalState.FAILED;
    }

    /// @inheritdoc IVoting
    function isVotingClosed(uint64 proposalId) public view returns (bool) {
        Proposal storage p = _proposals[proposalId];

        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        if (p.isResolved) {
            return true;
        }

        uint64 now_ = ITimestampVoting(SystemAddresses.TIMESTAMP).nowMicroseconds();
        return now_ >= p.expirationTime;
    }

    /// @inheritdoc IVoting
    function canBeResolvedEarly(uint64 proposalId) public view returns (bool) {
        if (earlyResolutionThreshold == 0) {
            return false;
        }

        Proposal storage p = _proposals[proposalId];

        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        if (p.isResolved) {
            return false;
        }

        return p.yesVotes >= earlyResolutionThreshold || p.noVotes >= earlyResolutionThreshold;
    }

    /// @inheritdoc IVoting
    function getNextProposalId() external view returns (uint64) {
        return nextProposalId;
    }

    /// @inheritdoc IVoting
    function getEarlyResolutionThreshold() external view returns (uint128) {
        return earlyResolutionThreshold;
    }

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @inheritdoc IVoting
    function createProposal(
        address proposer,
        bytes32 executionHash,
        string calldata metadataUri,
        uint128 minVoteThreshold,
        uint64 votingDurationMicros
    ) external returns (uint64 proposalId) {
        proposalId = nextProposalId++;

        uint64 now_ = ITimestampVoting(SystemAddresses.TIMESTAMP).nowMicroseconds();

        _proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: proposer,
            executionHash: executionHash,
            metadataUri: metadataUri,
            creationTime: now_,
            expirationTime: now_ + votingDurationMicros,
            minVoteThreshold: minVoteThreshold,
            yesVotes: 0,
            noVotes: 0,
            isResolved: false,
            resolutionTime: 0
        });

        emit ProposalCreated(proposalId, proposer, executionHash);
    }

    /// @inheritdoc IVoting
    function vote(uint64 proposalId, address voter, uint128 votingPower, bool support) external {
        Proposal storage p = _proposals[proposalId];

        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        if (isVotingClosed(proposalId)) {
            revert Errors.VotingPeriodEnded(p.expirationTime);
        }

        if (support) {
            p.yesVotes += votingPower;
        } else {
            p.noVotes += votingPower;
        }

        emit VoteCast(proposalId, voter, support, votingPower);
    }

    /// @inheritdoc IVoting
    function resolve(uint64 proposalId) external returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];

        if (p.id == 0) {
            revert Errors.ProposalNotFound(proposalId);
        }

        if (p.isResolved) {
            revert Errors.ProposalAlreadyResolved(proposalId);
        }

        uint64 now_ = ITimestampVoting(SystemAddresses.TIMESTAMP).nowMicroseconds();
        bool votingEnded = now_ >= p.expirationTime;
        bool canResolveEarly = canBeResolvedEarly(proposalId);

        if (!votingEnded && !canResolveEarly) {
            revert Errors.VotingPeriodNotEnded(p.expirationTime);
        }

        p.isResolved = true;
        p.resolutionTime = now_;

        ProposalState state = getProposalState(proposalId);

        emit ProposalResolved(proposalId, state);

        return state;
    }

    /// @inheritdoc IVoting
    function setEarlyResolutionThreshold(uint128 threshold) external {
        requireAllowed(SystemAddresses.TIMELOCK);
        earlyResolutionThreshold = threshold;
    }
}

