// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Errors
/// @author Gravity Team
/// @notice Custom errors for Gravity system contracts
/// @dev Using custom errors instead of require strings saves gas and provides structured error data
library Errors {
    // ========================================================================
    // STAKING ERRORS
    // ========================================================================

    /// @notice Staker has no stake position
    /// @param staker Address that has no stake
    error NoStakePosition(address staker);

    /// @notice Stake amount is insufficient
    /// @param required Minimum required amount
    /// @param actual Actual amount provided
    error InsufficientStake(uint256 required, uint256 actual);

    /// @notice Lockup period has not expired
    /// @param lockedUntil When the lockup expires (microseconds)
    /// @param currentTime Current timestamp (microseconds)
    error LockupNotExpired(uint64 lockedUntil, uint64 currentTime);

    /// @notice Amount cannot be zero
    error ZeroAmount();

    // ========================================================================
    // VALIDATOR ERRORS
    // ========================================================================

    /// @notice Validator does not exist
    /// @param validator Address of the non-existent validator
    error ValidatorNotFound(address validator);

    /// @notice Validator already registered
    /// @param validator Address of the existing validator
    error ValidatorAlreadyExists(address validator);

    /// @notice Invalid validator status for operation
    /// @param expected Expected status value
    /// @param actual Actual status value
    error InvalidStatus(uint8 expected, uint8 actual);

    /// @notice Bond amount is insufficient
    /// @param required Minimum required bond
    /// @param actual Actual bond amount
    error InsufficientBond(uint256 required, uint256 actual);

    /// @notice Bond exceeds maximum allowed
    /// @param maximum Maximum allowed bond
    /// @param actual Actual bond amount
    error ExceedsMaximumBond(uint256 maximum, uint256 actual);

    /// @notice Caller is not the validator owner
    /// @param expected Expected owner address
    /// @param actual Actual caller address
    error NotOwner(address expected, address actual);

    /// @notice Caller is not the validator operator
    /// @param expected Expected operator address
    /// @param actual Actual caller address
    error NotOperator(address expected, address actual);

    /// @notice Validator set changes are disabled
    error ValidatorSetChangesDisabled();

    /// @notice Maximum validator set size reached
    /// @param maxSize The maximum allowed validator set size
    error MaxValidatorSetSizeReached(uint256 maxSize);

    /// @notice Voting power increase exceeds limit
    /// @param limit Maximum allowed increase
    /// @param actual Actual increase amount
    error VotingPowerIncreaseLimitExceeded(uint256 limit, uint256 actual);

    /// @notice Moniker exceeds maximum length
    /// @param maxLength Maximum allowed length
    /// @param actualLength Actual moniker length
    error MonikerTooLong(uint256 maxLength, uint256 actualLength);

    /// @notice Unbond period has not elapsed
    /// @param availableAt When the unbond becomes available (microseconds)
    /// @param currentTime Current timestamp (microseconds)
    error UnbondNotReady(uint64 availableAt, uint64 currentTime);

    // ========================================================================
    // RECONFIGURATION ERRORS
    // ========================================================================

    /// @notice Reconfiguration is already in progress
    error ReconfigurationInProgress();

    /// @notice No reconfiguration in progress
    error ReconfigurationNotInProgress();

    /// @notice Epoch has not yet ended
    /// @param nextEpochTime When the next epoch starts (microseconds)
    /// @param currentTime Current timestamp (microseconds)
    error EpochNotYetEnded(uint64 nextEpochTime, uint64 currentTime);

    // ========================================================================
    // GOVERNANCE ERRORS
    // ========================================================================

    /// @notice Proposal not found
    /// @param proposalId ID of the non-existent proposal
    error ProposalNotFound(uint64 proposalId);

    /// @notice Voting period has ended
    /// @param expirationTime When voting ended (microseconds)
    error VotingPeriodEnded(uint64 expirationTime);

    /// @notice Voting period has not ended
    /// @param expirationTime When voting ends (microseconds)
    error VotingPeriodNotEnded(uint64 expirationTime);

    /// @notice Proposal has already been resolved
    /// @param proposalId ID of the resolved proposal
    error ProposalAlreadyResolved(uint64 proposalId);

    /// @notice Execution hash does not match
    /// @param expected Expected execution hash
    /// @param actual Actual execution hash
    error ExecutionHashMismatch(bytes32 expected, bytes32 actual);

    /// @notice Lockup duration is insufficient for operation
    /// @param required Required lockup expiration (microseconds)
    /// @param actual Actual lockup expiration (microseconds)
    error InsufficientLockup(uint64 required, uint64 actual);

    /// @notice Atomic resolution is not allowed
    error AtomicResolutionNotAllowed();

    /// @notice Voting power is insufficient
    /// @param required Required voting power
    /// @param actual Actual voting power
    error InsufficientVotingPower(uint256 required, uint256 actual);

    // ========================================================================
    // TIMESTAMP ERRORS
    // ========================================================================

    /// @notice Timestamp must advance for normal blocks
    /// @param proposed Proposed timestamp (microseconds)
    /// @param current Current timestamp (microseconds)
    error TimestampMustAdvance(uint64 proposed, uint64 current);

    /// @notice Timestamp must equal current for NIL blocks
    /// @param proposed Proposed timestamp (microseconds)
    /// @param current Current timestamp (microseconds)
    error TimestampMustEqual(uint64 proposed, uint64 current);

    // ========================================================================
    // CONFIG ERRORS
    // ========================================================================

    /// @notice Contract has already been initialized
    error AlreadyInitialized();

    /// @notice Lockup duration must be greater than zero
    error InvalidLockupDuration();

    /// @notice Unbonding delay must be greater than zero
    error InvalidUnbondingDelay();

    /// @notice Minimum bond must be greater than zero
    error InvalidMinimumBond();

    /// @notice Voting power increase limit out of range (1-50)
    /// @param value The invalid value provided
    error InvalidVotingPowerIncreaseLimit(uint64 value);

    /// @notice Validator set size out of range (1-65536)
    /// @param value The invalid value provided
    error InvalidValidatorSetSize(uint256 value);

    /// @notice Minimum bond must be less than or equal to maximum bond
    /// @param minimum The minimum bond value
    /// @param maximum The maximum bond value
    error MinimumBondExceedsMaximum(uint256 minimum, uint256 maximum);
}

