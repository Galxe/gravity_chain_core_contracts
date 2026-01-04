// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ValidatorRecord, ValidatorStatus, ValidatorConsensusInfo } from "../foundation/Types.sol";

/// @title IValidatorManagement
/// @author Gravity Team
/// @notice Interface for the ValidatorManager contract
/// @dev Manages validator registration, lifecycle transitions, and validator set state.
///      Validators must have a StakePool with sufficient voting power to register.
///      ValidatorManager only interacts with the Staking factory contract, never StakePool directly.
interface IValidatorManagement {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new validator is registered
    /// @param stakePool Address of the validator's stake pool (also serves as validator identity)
    /// @param moniker Display name for the validator
    event ValidatorRegistered(address indexed stakePool, string moniker);

    /// @notice Emitted when a validator requests to join the active set
    /// @param stakePool Address of the validator's stake pool
    event ValidatorJoinRequested(address indexed stakePool);

    /// @notice Emitted when a validator becomes active (at epoch boundary)
    /// @param stakePool Address of the validator's stake pool
    /// @param validatorIndex Index assigned to the validator for this epoch
    /// @param votingPower Voting power snapshot for this epoch
    event ValidatorActivated(address indexed stakePool, uint64 validatorIndex, uint256 votingPower);

    /// @notice Emitted when a validator requests to leave the active set
    /// @param stakePool Address of the validator's stake pool
    event ValidatorLeaveRequested(address indexed stakePool);

    /// @notice Emitted when a validator becomes inactive (at epoch boundary)
    /// @param stakePool Address of the validator's stake pool
    event ValidatorDeactivated(address indexed stakePool);

    /// @notice Emitted when a validator's consensus key is rotated
    /// @param stakePool Address of the validator's stake pool
    /// @param newPubkey New BLS public key
    event ConsensusKeyRotated(address indexed stakePool, bytes newPubkey);

    /// @notice Emitted when a validator's fee recipient is updated
    /// @param stakePool Address of the validator's stake pool
    /// @param newRecipient New fee recipient address
    event FeeRecipientUpdated(address indexed stakePool, address newRecipient);

    /// @notice Emitted when a new epoch is processed
    /// @param epoch The new epoch number
    /// @param activeCount Number of active validators
    /// @param totalVotingPower Total voting power of active validators
    event EpochProcessed(uint64 epoch, uint256 activeCount, uint256 totalVotingPower);

    // ========================================================================
    // REGISTRATION
    // ========================================================================

    /// @notice Register a new validator with a stake pool
    /// @dev Only callable by the stake pool's operator.
    ///      Requires stake pool to have voting power >= minimumBond.
    ///      The stakePool address becomes the validator identity.
    /// @param stakePool Address of the stake pool (must be created by Staking factory)
    /// @param moniker Display name for the validator (max 31 bytes)
    /// @param consensusPubkey BLS public key for consensus
    /// @param consensusPop Proof of possession for the BLS key
    /// @param networkAddresses Network addresses for P2P communication
    /// @param fullnodeAddresses Fullnode addresses
    function registerValidator(
        address stakePool,
        string calldata moniker,
        bytes calldata consensusPubkey,
        bytes calldata consensusPop,
        bytes calldata networkAddresses,
        bytes calldata fullnodeAddresses
    ) external;

    // ========================================================================
    // LIFECYCLE
    // ========================================================================

    /// @notice Request to join the active validator set
    /// @dev Only callable by the validator's operator.
    ///      Validator must be in INACTIVE status.
    ///      Transition to ACTIVE happens at next epoch boundary via onNewEpoch().
    /// @param stakePool Address of the validator's stake pool
    function joinValidatorSet(
        address stakePool
    ) external;

    /// @notice Request to leave the active validator set
    /// @dev Only callable by the validator's operator.
    ///      Validator must be in ACTIVE status.
    ///      Transition to INACTIVE happens at next epoch boundary via onNewEpoch().
    /// @param stakePool Address of the validator's stake pool
    function leaveValidatorSet(
        address stakePool
    ) external;

    // ========================================================================
    // OPERATOR FUNCTIONS
    // ========================================================================

    /// @notice Rotate the validator's consensus key
    /// @dev Only callable by the validator's operator.
    ///      New key takes effect immediately (no epoch delay).
    /// @param stakePool Address of the validator's stake pool
    /// @param newPubkey New BLS public key
    /// @param newPop New proof of possession
    function rotateConsensusKey(
        address stakePool,
        bytes calldata newPubkey,
        bytes calldata newPop
    ) external;

    /// @notice Set a new fee recipient address
    /// @dev Only callable by the validator's operator.
    ///      New recipient takes effect at next epoch.
    /// @param stakePool Address of the validator's stake pool
    /// @param newRecipient New fee recipient address
    function setFeeRecipient(
        address stakePool,
        address newRecipient
    ) external;

    // ========================================================================
    // EPOCH PROCESSING
    // ========================================================================

    /// @notice Process epoch transition
    /// @dev Only callable by RECONFIGURATION contract.
    ///      - Processes PENDING_INACTIVE → INACTIVE transitions
    ///      - Processes PENDING_ACTIVE → ACTIVE transitions (respecting voting power limits)
    ///      - Reassigns validator indices
    ///      - Updates total voting power
    /// @param newEpoch The new epoch number to set
    function onNewEpoch(
        uint64 newEpoch
    ) external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the full validator record
    /// @param stakePool Address of the validator's stake pool
    /// @return The validator record
    function getValidator(
        address stakePool
    ) external view returns (ValidatorRecord memory);

    /// @notice Get all active validators with consensus info
    /// @dev Returns validators in index order (index 0 first)
    /// @return Array of ValidatorConsensusInfo for all active validators
    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory);

    /// @notice Get a specific active validator by index
    /// @param index Validator index (0 to activeCount-1)
    /// @return ValidatorConsensusInfo for the validator at that index
    function getActiveValidatorByIndex(
        uint64 index
    ) external view returns (ValidatorConsensusInfo memory);

    /// @notice Get total voting power of active validators
    /// @return Total voting power
    function getTotalVotingPower() external view returns (uint256);

    /// @notice Get the number of active validators
    /// @return Count of active validators
    function getActiveValidatorCount() external view returns (uint256);

    /// @notice Check if an address is a registered validator
    /// @param stakePool Address to check
    /// @return True if the address is a registered validator
    function isValidator(
        address stakePool
    ) external view returns (bool);

    /// @notice Get the status of a validator
    /// @param stakePool Address of the validator's stake pool
    /// @return The validator's current status
    function getValidatorStatus(
        address stakePool
    ) external view returns (ValidatorStatus);

    /// @notice Get the current epoch number
    /// @return Current epoch
    function getCurrentEpoch() external view returns (uint64);

    /// @notice Get pending active validators
    /// @return Array of stake pool addresses pending activation
    function getPendingActiveValidators() external view returns (address[] memory);

    /// @notice Get pending inactive validators
    /// @return Array of stake pool addresses pending deactivation
    function getPendingInactiveValidators() external view returns (address[] memory);
}

