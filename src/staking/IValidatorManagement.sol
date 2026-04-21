// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ValidatorRecord, ValidatorStatus, ValidatorConsensusInfo } from "../foundation/Types.sol";

/// @notice Genesis validator info for initialization
/// @dev Used to initialize the validator set at genesis
struct GenesisValidator {
    /// @notice Stake pool address (also serves as validator identity)
    address stakePool;
    /// @notice Display name (max 31 bytes)
    string moniker;
    /// @notice BLS public key for consensus
    bytes consensusPubkey;
    /// @notice Proof of possession for BLS key
    bytes consensusPop;
    /// @notice Network addresses for P2P
    bytes networkAddresses;
    /// @notice Fullnode addresses
    bytes fullnodeAddresses;
    /// @notice Fee recipient address
    address feeRecipient;
    /// @notice Initial voting power
    uint256 votingPower;
}

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

    /// @notice Emitted when governance forces a validator to leave the active set
    /// @param stakePool Address of the validator's stake pool
    event ValidatorForceLeaveRequested(address indexed stakePool);

    /// @notice Emitted when a validator becomes inactive (at epoch boundary)
    /// @param stakePool Address of the validator's stake pool
    event ValidatorDeactivated(address indexed stakePool);

    /// @notice Emitted when a validator is auto-evicted for underperformance
    /// @param stakePool Address of the validator's stake pool
    /// @param successfulProposals Number of successful proposals the validator had
    event ValidatorAutoEvicted(address indexed stakePool, uint256 successfulProposals);

    /// @notice Emitted when a validator is evicted for dropping below minimum bond
    /// @param stakePool Address of the validator's stake pool
    /// @param votingPower The validator's current voting power
    /// @param minimumBond The expected minimum bond threshold
    event ValidatorUnderbondedEvicted(address indexed stakePool, uint256 votingPower, uint256 minimumBond);

    /// @notice Emitted when performance data array length doesn't match active validator count
    event PerformanceLengthMismatch(uint256 activeCount, uint256 perfCount);

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

    /// @notice Emitted when the contract is initialized with genesis validators
    /// @param validatorCount Number of genesis validators
    /// @param totalVotingPower Total voting power of genesis validators
    event ValidatorManagementInitialized(uint256 validatorCount, uint256 totalVotingPower);

    /// @notice Emitted when a pending fee recipient change is applied at epoch boundary
    /// @param stakePool Address of the validator's stake pool
    /// @param oldRecipient Previous fee recipient address
    /// @param newRecipient New fee recipient address
    event FeeRecipientApplied(address indexed stakePool, address oldRecipient, address newRecipient);

    /// @notice Emitted when a validator is reverted to inactive due to insufficient bond
    /// @param stakePool Address of the validator's stake pool
    event ValidatorRevertedInactive(address indexed stakePool);

    /// @notice Emitted when a stake pool's whitelist entry is added or removed by governance
    /// @param stakePool Address of the stake pool
    /// @param allowed True if now on the whitelist, false if removed
    event ValidatorPoolAllowed(address indexed stakePool, bool allowed);

    /// @notice Emitted when governance flips the permissionless-join flag
    /// @param enabled True if permissionless join is now active (whitelist bypassed)
    event PermissionlessJoinEnabledUpdated(bool enabled);

    /// @notice Emitted when a caller commits to a future consensus pubkey registration/rotation
    /// @param committer Address that submitted the commitment (must later be msg.sender of register/rotate)
    /// @param commitment keccak256(abi.encode(pubkey, stakePool, chainid))
    /// @param blockNumber Block number at which the commitment was recorded
    event ConsensusPubkeyCommitted(address indexed committer, bytes32 indexed commitment, uint256 blockNumber);

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the validator set with genesis validators
    /// @dev Only callable by GENESIS contract. Can only be called once.
    ///      Genesis validators are added directly to the active set.
    /// @param validators Array of genesis validator info
    function initialize(
        GenesisValidator[] calldata validators
    ) external;

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool);

    // ========================================================================
    // REGISTRATION
    // ========================================================================

    /// @notice Commit to a future consensus-pubkey registration or rotation
    /// @dev Audit #580 mitigation. The BLS PoP precompile only proves "someone has sk",
    ///      not "this sender has sk" — so a front-runner that observes a victim's
    ///      (pubkey, pop) in the mempool can replay the pair into their own pool and
    ///      DoS the victim's registration. The commit-reveal flow forces registration
    ///      to be preceded by an opaque `keccak256(pubkey, stakePool, chainid)` commit
    ///      from the same `msg.sender`, so the registrant is bound to the pubkey
    ///      before the pubkey is publicly observable.
    ///
    ///      The commit is keyed by msg.sender; it is consumed (deleted) on the matching
    ///      `registerValidator` / `rotateConsensusKey` call. A subsequent call that
    ///      re-uses the same (pubkey, stakePool) needs a fresh commit.
    /// @param commitment keccak256(abi.encode(pubkey, stakePool, chainid))
    function commitConsensusPubkey(
        bytes32 commitment
    ) external;

    /// @notice Register a new validator with a stake pool
    /// @dev Only callable by the stake pool's operator.
    ///      Requires stake pool to have voting power >= minimumBond.
    ///      The stakePool address becomes the validator identity.
    ///      Caller must have previously submitted a matching `commitConsensusPubkey`
    ///      in a strictly earlier block (see audit #580).
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

    /// @notice Force a validator to leave the active set (governance only)
    /// @dev Only callable by GOVERNANCE contract.
    ///      If validator is PENDING_ACTIVE: immediately reverts to INACTIVE.
    ///      If validator is ACTIVE: sets to PENDING_INACTIVE for deactivation at next epoch.
    ///      Unlike voluntary leaveValidatorSet, this can remove the last validator (emergency).
    /// @param stakePool Address of the validator's stake pool
    function forceLeaveValidatorSet(
        address stakePool
    ) external;

    // ========================================================================
    // WHITELIST (GOVERNANCE only)
    // ========================================================================

    /// @notice Add or remove a stake pool from the validator whitelist
    /// @dev Only callable by GOVERNANCE. Takes effect immediately for subsequent
    ///      registerValidator() and joinValidatorSet() calls. Does not affect
    ///      already-registered or already-active validators; use forceLeaveValidatorSet
    ///      to remove an active validator.
    /// @param stakePool The stake pool to add or remove
    /// @param allowed True to add to whitelist, false to remove
    function setValidatorPoolAllowed(
        address stakePool,
        bool allowed
    ) external;

    /// @notice Set whether any stake pool may register/join without being whitelisted
    /// @dev Only callable by GOVERNANCE. When true, the whitelist is bypassed and
    ///      any stake pool with sufficient stake may become a validator. This is the
    ///      one-way-ish switch from permissioned launch to permissionless operation.
    /// @param enabled True to disable whitelist checks, false to require whitelist
    function setPermissionlessJoinEnabled(
        bool enabled
    ) external;

    // ========================================================================
    // OPERATOR FUNCTIONS
    // ========================================================================

    /// @notice Rotate the validator's consensus key
    /// @dev Only callable by the validator's operator.
    ///      Rotation uses the same commit-reveal flow as registration (audit #580):
    ///      caller must have previously submitted a matching `commitConsensusPubkey`
    ///      for (newPubkey, stakePool) in a strictly earlier block.
    ///      The new key is reserved immediately but only takes effect at the next
    ///      epoch boundary (see rotateConsensusKey implementation).
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
    ///      Called BEFORE Reconfiguration increments its epoch counter (Aptos pattern).
    ///      - Processes PENDING_INACTIVE → INACTIVE transitions
    ///      - Processes PENDING_ACTIVE → ACTIVE transitions (respecting voting power limits)
    ///      - Reassigns validator indices
    ///      - Updates total voting power
    ///      - Increments internal epoch counter
    function onNewEpoch() external;

    /// @notice Auto-evict underperforming validators at epoch boundary
    /// @dev Only callable by RECONFIGURATION during epoch transition.
    ///      Reads performance data from ValidatorPerformanceTracker and marks validators
    ///      with success rate < autoEvictThresholdPct as PENDING_INACTIVE.
    ///      Note: Unlike leaveValidatorSet, this happens DURING reconfiguration (not between epochs),
    ///      so evicted validators are immediately processed by onNewEpoch() in the same call,
    ///      going directly from ACTIVE → PENDING_INACTIVE → INACTIVE in one epoch transition.
    ///      This is intentionally different from voluntary leave (which has a 1-epoch buffer)
    ///      because the validator already demonstrated zero productivity in the completed epoch.
    function evictUnderperformingValidators() external;

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

    /// @notice Get pending active validators with full consensus info
    /// @return Array of ValidatorConsensusInfo for validators pending activation
    function getPendingActiveValidators() external view returns (ValidatorConsensusInfo[] memory);

    /// @notice Get pending inactive validators with full consensus info
    /// @return Array of ValidatorConsensusInfo for validators pending deactivation
    function getPendingInactiveValidators() external view returns (ValidatorConsensusInfo[] memory);

    // ========================================================================
    // DKG SUPPORT FUNCTIONS
    // ========================================================================

    /// @notice Get current validators for DKG dealers (active + pending_inactive)
    /// @dev Used for DKG: validators who can participate in running DKG.
    ///      Indices are their CURRENT epoch indices (position in array matches validatorIndex).
    ///      Aptos pattern: pending_inactive can still participate in current epoch DKG.
    /// @return Array of ValidatorConsensusInfo for dealers, ordered by current validator index
    function getCurValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory);

    /// @notice Get projected next epoch validators for DKG targets
    /// @dev Used for DKG: validators who will receive DKG keys.
    ///      Returns (active - pending_inactive) + pending_active (subject to min stake).
    ///      IMPORTANT: Indices are FRESHLY ASSIGNED (0, 1, 2, ...) based on position in array,
    ///      NOT their current epoch indices. This matches Aptos's next_validator_consensus_infos().
    /// @return Array of ValidatorConsensusInfo for targets with projected indices
    function getNextValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory);

    // ========================================================================
    // WHITELIST VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check whether a stake pool is on the validator whitelist
    /// @param stakePool The pool to query
    /// @return True if the pool is whitelisted
    function isValidatorPoolAllowed(
        address stakePool
    ) external view returns (bool);

    /// @notice Check whether permissionless joining is enabled
    /// @return True if the whitelist is bypassed
    function isPermissionlessJoinEnabled() external view returns (bool);
}

