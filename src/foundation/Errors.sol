// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Errors
/// @author Gravity Team
/// @notice Custom errors for Gravity system contracts
/// @dev Using custom errors instead of require strings saves gas and provides structured error data
library Errors {
    // ========================================================================
    // STAKING FACTORY ERRORS
    // ========================================================================

    /// @notice Insufficient stake for pool creation
    /// @param sent Amount sent with transaction
    /// @param required Minimum required amount
    error InsufficientStakeForPoolCreation(uint256 sent, uint256 required);

    /// @notice Pool index out of bounds
    /// @param index Requested index
    /// @param total Total number of pools
    error PoolIndexOutOfBounds(uint256 index, uint256 total);

    /// @notice Address is not a valid pool created by the factory
    /// @dev SECURITY: Only pools created by the Staking factory are trusted
    /// @param pool The invalid pool address
    error InvalidPool(address pool);

    // ========================================================================
    // STAKE POOL ERRORS
    // ========================================================================

    /// @notice Stake amount is insufficient for withdrawal
    /// @param requested Amount requested to withdraw
    /// @param available Amount available in pool
    error InsufficientStake(uint256 requested, uint256 available);

    /// @notice Lockup period has not expired
    /// @param lockedUntil When the lockup expires (microseconds)
    /// @param currentTime Current timestamp (microseconds)
    error LockupNotExpired(uint64 lockedUntil, uint64 currentTime);

    /// @notice Lockup duration is too short
    /// @param provided Duration provided (microseconds)
    /// @param minimum Minimum required duration (microseconds)
    error LockupDurationTooShort(uint64 provided, uint64 minimum);

    /// @notice Lockup increase would overflow
    /// @param current Current lockedUntil value
    /// @param addition Duration being added
    error LockupOverflow(uint64 current, uint64 addition);

    /// @notice Amount cannot be zero
    error ZeroAmount();

    /// @notice Staker has no stake position (legacy, kept for compatibility)
    /// @param staker Address that has no stake
    error NoStakePosition(address staker);

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

    /// @notice Caller is not the pool staker
    /// @param caller Actual caller address
    /// @param staker Expected staker address
    error NotStaker(address caller, address staker);

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

    /// @notice Validator index out of bounds
    /// @param index The requested index
    /// @param total The total number of active validators
    error ValidatorIndexOutOfBounds(uint64 index, uint64 total);

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

    /// @notice Epoch interval must be greater than zero
    error InvalidEpochInterval();

    /// @notice Reconfiguration contract has not been initialized
    error ReconfigurationNotInitialized();

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

    /// @notice Caller is not the delegated voter for the stake pool
    /// @param expected Expected voter address (from StakePool)
    /// @param actual Actual caller address
    error NotDelegatedVoter(address expected, address actual);

    /// @notice Voting power usage would overflow remaining power
    /// @param requested Voting power requested
    /// @param remaining Remaining voting power available
    error VotingPowerOverflow(uint128 requested, uint128 remaining);

    /// @notice Proposal did not succeed (cannot execute)
    /// @param proposalId ID of the proposal
    error ProposalNotSucceeded(uint64 proposalId);

    /// @notice Proposal has already been executed
    /// @param proposalId ID of the proposal
    error ProposalAlreadyExecuted(uint64 proposalId);

    /// @notice Voting duration must be greater than zero
    error InvalidVotingDuration();

    /// @notice Early resolution threshold out of range (must be <= 10000 bps)
    /// @param value The invalid value provided
    error InvalidEarlyResolutionThreshold(uint128 value);

    /// @notice Proposal execution failed
    /// @param proposalId ID of the proposal
    error ExecutionFailed(uint64 proposalId);

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

    // ========================================================================
    // RANDOMNESS CONFIG ERRORS
    // ========================================================================

    /// @notice Randomness config has not been initialized
    error RandomnessNotInitialized();

    /// @notice Randomness config has already been initialized
    error RandomnessAlreadyInitialized();

    /// @notice Invalid randomness configuration
    /// @param reason Description of what's invalid
    error InvalidRandomnessConfig(string reason);

    /// @notice No pending randomness config to apply
    error NoPendingRandomnessConfig();

    // ========================================================================
    // DKG ERRORS
    // ========================================================================

    /// @notice DKG session is already in progress
    error DKGInProgress();

    /// @notice No DKG session is in progress
    error DKGNotInProgress();

    /// @notice DKG contract has not been initialized
    error DKGNotInitialized();

    // ========================================================================
    // NATIVE ORACLE ERRORS
    // ========================================================================

    /// @notice Sync ID must be strictly increasing for each source
    /// @param sourceName The source identifier
    /// @param currentSyncId The current sync ID for this source
    /// @param providedSyncId The provided sync ID that is not greater
    error SyncIdNotIncreasing(bytes32 sourceName, uint128 currentSyncId, uint128 providedSyncId);

    /// @notice Batch arrays have mismatched lengths
    /// @param hashesLength Length of dataHashes array
    /// @param payloadsLength Length of payloads array
    error ArrayLengthMismatch(uint256 hashesLength, uint256 payloadsLength);

    /// @notice Data record not found for the given hash
    /// @param dataHash The hash that was not found
    error DataRecordNotFound(bytes32 dataHash);

    /// @notice Oracle contract has not been initialized
    error OracleNotInitialized();
}

