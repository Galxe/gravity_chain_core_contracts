// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Types
/// @author Gravity Team
/// @notice Core data types for Gravity system contracts

// ============================================================================
// STAKING TYPES (for governance participation — anyone can stake)
// ============================================================================

/// @notice Stake position for governance voting
/// @dev Anyone can stake tokens and participate in governance.
///      All timestamps are in microseconds (from Timestamp contract).
struct StakePosition {
    /// @notice Staked token amount
    uint256 amount;
    /// @notice Lockup expiration timestamp (microseconds)
    uint64 lockedUntil;
    /// @notice When stake was first deposited (microseconds)
    uint64 stakedAt;
}

// ============================================================================
// VALIDATOR TYPES (for consensus participation)
// ============================================================================

/// @notice Validator lifecycle status
enum ValidatorStatus {
    INACTIVE, // 0: Not in validator set
    PENDING_ACTIVE, // 1: Queued to join next epoch
    ACTIVE, // 2: Currently validating
    PENDING_INACTIVE // 3: Queued to leave next epoch
}

/// @notice Validator consensus info (packed for consensus engine)
/// @dev Used to communicate validator set to consensus layer
struct ValidatorConsensusInfo {
    /// @notice Validator identity address
    address validator;
    /// @notice BLS public key for consensus
    bytes consensusPubkey;
    /// @notice Proof of possession for BLS key
    bytes consensusPop;
    /// @notice Voting power derived from bond
    uint256 votingPower;
    /// @notice Index in active validator array of an epoch.
    uint64 validatorIndex;
    /// @notice Network addresses for P2P communication
    bytes networkAddresses;
    /// @notice Fullnode addresses for sync
    bytes fullnodeAddresses;
}

/// @notice Full validator record
/// @dev Contains all validator state, stored in ValidatorManager.
///      All timestamps are in microseconds (from Timestamp contract).
struct ValidatorRecord {
    /// @notice Immutable validator identity address
    address validator;
    /// @notice Display name (max 31 bytes)
    string moniker;
    /// @notice Current lifecycle status
    ValidatorStatus status;
    // === Bond Management ===
    /// @notice Current validator bond amount (voting power snapshot at epoch boundary)
    uint256 bond;
    // === Consensus Key Material ===
    /// @notice BLS consensus public key
    bytes consensusPubkey;
    /// @notice Proof of possession for BLS key
    bytes consensusPop;
    /// @notice Network addresses for P2P
    bytes networkAddresses;
    /// @notice Fullnode addresses
    bytes fullnodeAddresses;
    // === Fee Distribution ===
    /// @notice Current fee recipient address
    address feeRecipient;
    /// @notice Pending fee recipient (applied next epoch)
    address pendingFeeRecipient;
    // === Optional External Staking Pool ===
    /// @notice Address of IValidatorStakingPool (address(0) if none)
    address stakingPool;
    // === Indexing ===
    /// @notice Index in active validator array (only valid when ACTIVE/PENDING_INACTIVE)
    uint64 validatorIndex;
}

// ============================================================================
// GOVERNANCE TYPES
// ============================================================================

/// @notice Governance proposal lifecycle state
enum ProposalState {
    PENDING, // 0: Voting active
    SUCCEEDED, // 1: Passed, ready to execute
    FAILED, // 2: Did not pass
    EXECUTED, // 3: Already executed
    CANCELLED // 4: Cancelled
}

/// @notice Governance proposal
/// @dev Stored in Voting contract.
///      All timestamps are in microseconds (from Timestamp contract).
struct Proposal {
    /// @notice Unique proposal identifier
    uint64 id;
    /// @notice Address that created the proposal
    address proposer;
    /// @notice Hash of execution script/payload
    bytes32 executionHash;
    /// @notice IPFS/URL to proposal metadata
    string metadataUri;
    /// @notice When proposal was created (microseconds)
    uint64 creationTime;
    /// @notice When voting ends (microseconds)
    uint64 expirationTime;
    /// @notice Minimum votes required for quorum
    uint128 minVoteThreshold;
    /// @notice Total yes votes
    uint128 yesVotes;
    /// @notice Total no votes
    uint128 noVotes;
    /// @notice Whether proposal has been resolved
    bool isResolved;
    /// @notice When proposal was resolved (microseconds)
    uint64 resolutionTime;
}
