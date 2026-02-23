// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IValidatorManagement, GenesisValidator } from "./IValidatorManagement.sol";
import { IStaking } from "./IStaking.sol";
import { ValidatorRecord, ValidatorStatus, ValidatorConsensusInfo } from "../foundation/Types.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";
import { IValidatorConfig } from "../runtime/IValidatorConfig.sol";
import { IReconfiguration } from "../blocker/IReconfiguration.sol";
import { ITimestamp } from "../runtime/ITimestamp.sol";
import { IValidatorPerformanceTracker } from "../blocker/IValidatorPerformanceTracker.sol";

/// @title ValidatorManagement
/// @author Gravity Team
/// @notice Manages validator registration, lifecycle transitions, and validator set state
/// @dev Validators must have a StakePool with sufficient voting power to register.
///      ValidatorManager only interacts with the Staking factory contract, never StakePool directly.
///      Validator indices are assigned at each epoch boundary like Aptos.
///
/// ## Security Properties (Aptos Parity)
///
/// 1. **Withdrawal Protection**: Active validators (status ACTIVE or PENDING_INACTIVE) cannot
///    withdraw stake from their StakePool. This is enforced by StakePool.withdraw() checking
///    validator status. Validators must call leaveValidatorSet() and wait for epoch transition
///    to become INACTIVE before withdrawing.
///
/// 2. **Lockup Auto-Renewal**: Active validators have their lockup automatically renewed at
///    each epoch boundary via _renewActiveValidatorLockups(). This ensures voting power never
///    drops to zero due to lockup expiration while actively participating in consensus.
///
/// 3. **Excessive Stake Protection**: Even stake amounts exceeding maximumBond cannot be
///    withdrawn while the validator is active. The entire stake is locked, not just the portion
///    contributing to voting power.
///
/// 4. **Default Status**: Unregistered pools return false for isValidator(). Querying status
///    of an unregistered pool via getValidatorStatus() reverts with ValidatorNotFound.
contract ValidatorManagement is IValidatorManagement {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum moniker length in bytes
    uint256 public constant MAX_MONIKER_LENGTH = 31;

    /// @notice Expected BLS12-381 G1 compressed public key length in bytes
    uint256 public constant BLS12381_PUBKEY_LENGTH = 48;

    /// @notice Precision factor for percentage calculations
    uint256 internal constant PRECISION_FACTOR = 1e4;

    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Complete next epoch validator set with state transition info
    /// @dev Single source of truth for both getNextValidatorConsensusInfos() and onNewEpoch()
    ///      This struct captures:
    ///      1. The exact validator set for the next epoch (validators array)
    ///      2. State transition information for onNewEpoch() to apply changes
    struct NextEpochValidatorSet {
        /// @notice The complete next epoch validator set
        /// @dev This is exactly what getNextValidatorConsensusInfos() returns
        ValidatorConsensusInfo[] validators;
        /// @notice Validators to deactivate (PENDING_INACTIVE -> INACTIVE)
        address[] toDeactivate;
        /// @notice Number of validators to deactivate
        uint256 deactivateCount;
        /// @notice Validators to activate (PENDING_ACTIVE -> ACTIVE)
        address[] toActivate;
        /// @notice Number of validators to activate
        uint256 activateCount;
        /// @notice Validators that dropped below minimum bond (PENDING_ACTIVE -> INACTIVE)
        address[] toRevertInactive;
        /// @notice Number of validators to revert to inactive
        uint256 revertInactiveCount;
        /// @notice Validators that remain pending (voting power limit exceeded)
        address[] toKeepPending;
        /// @notice Number of validators to keep pending
        uint256 keepPendingCount;
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Validator records by stakePool address
    mapping(address => ValidatorRecord) internal _validators;

    /// @notice Active validator addresses (ordered, index = validatorIndex)
    address[] internal _activeValidators;

    /// @notice Validators pending activation (will become ACTIVE at next epoch)
    address[] internal _pendingActive;

    /// @notice Validators pending deactivation (will become INACTIVE at next epoch)
    address[] internal _pendingInactive;

    /// @notice Total voting power of active validators (snapshotted at epoch boundary)
    uint256 public totalVotingPower;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    /// @notice Tracks which validator is using each consensus pubkey
    /// @dev keccak256(pubkey) => stakePool address (address(0) if unused)
    mapping(bytes32 => address) internal _pubkeyToValidator;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function initialize(
        GenesisValidator[] calldata validators
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        uint256 length = validators.length;
        uint256 totalPower = 0;

        for (uint256 i = 0; i < length; i++) {
            GenesisValidator calldata v = validators[i];

            // Validate moniker length
            if (bytes(v.moniker).length > MAX_MONIKER_LENGTH) {
                revert Errors.MonikerTooLong(MAX_MONIKER_LENGTH, bytes(v.moniker).length);
            }

            // Create validator record
            ValidatorRecord storage record = _validators[v.stakePool];
            record.validator = v.stakePool;
            record.moniker = v.moniker;
            record.stakingPool = v.stakePool;
            record.status = ValidatorStatus.ACTIVE;
            record.bond = v.votingPower;
            record.consensusPubkey = v.consensusPubkey;
            record.consensusPop = v.consensusPop;

            // Register pubkey in the mapping
            _pubkeyToValidator[keccak256(v.consensusPubkey)] = v.stakePool;
            record.networkAddresses = v.networkAddresses;
            record.fullnodeAddresses = v.fullnodeAddresses;
            record.feeRecipient = v.feeRecipient;
            record.validatorIndex = uint64(i);

            // Add to active validators
            _activeValidators.push(v.stakePool);
            totalPower += v.votingPower;

            emit ValidatorRegistered(v.stakePool, v.moniker);
            emit ValidatorActivated(v.stakePool, uint64(i), v.votingPower);
        }

        totalVotingPower = totalPower;
        _initialized = true;

        emit ValidatorManagementInitialized(length, totalPower);
    }

    /// @inheritdoc IValidatorManagement
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Ensures the caller is the operator of the given stake pool
    modifier onlyOperator(
        address stakePool
    ) {
        address operator = IStaking(SystemAddresses.STAKING).getPoolOperator(stakePool);
        if (msg.sender != operator) {
            revert Errors.NotOperator(operator, msg.sender);
        }
        _;
    }

    /// @notice Ensures the validator exists
    modifier validatorExists(
        address stakePool
    ) {
        if (_validators[stakePool].validator == address(0)) {
            revert Errors.ValidatorNotFound(stakePool);
        }
        _;
    }

    /// @notice Ensures no reconfiguration (epoch transition) is in progress
    /// @dev Mirrors Aptos's assert_reconfig_not_in_progress() - blocks during entire DKG period
    modifier whenNotReconfiguring() {
        if (IReconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress()) {
            revert Errors.ReconfigurationInProgress();
        }
        _;
    }

    // ========================================================================
    // REGISTRATION
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function registerValidator(
        address stakePool,
        string calldata moniker,
        bytes calldata consensusPubkey,
        bytes calldata consensusPop,
        bytes calldata networkAddresses,
        bytes calldata fullnodeAddresses
    ) external {
        // Validate inputs and get required data
        _validateRegistration(stakePool, moniker);

        // Create validator record
        _createValidatorRecord(stakePool, moniker, consensusPubkey, consensusPop, networkAddresses, fullnodeAddresses);

        emit ValidatorRegistered(stakePool, moniker);
    }

    /// @notice Validate registration inputs
    function _validateRegistration(
        address stakePool,
        string calldata moniker
    ) internal view {
        // Verify stake pool is valid (created by Staking factory)
        if (!IStaking(SystemAddresses.STAKING).isPool(stakePool)) {
            revert Errors.InvalidPool(stakePool);
        }

        // Verify caller is the stake pool's operator
        address operator = IStaking(SystemAddresses.STAKING).getPoolOperator(stakePool);
        if (msg.sender != operator) {
            revert Errors.NotOperator(operator, msg.sender);
        }

        // Verify validator doesn't already exist
        if (_validators[stakePool].validator != address(0)) {
            revert Errors.ValidatorAlreadyExists(stakePool);
        }

        // Verify voting power meets minimum bond requirement
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint256 votingPower = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool, now_);
        uint256 minimumBond = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).minimumBond();
        if (votingPower < minimumBond) {
            revert Errors.InsufficientBond(minimumBond, votingPower);
        }

        // Note: Stake drops below minimum are handled in _processPendingActive()
        // Lockup is auto-renewed for active validators via _renewActiveValidatorLockups()

        // Verify moniker length
        if (bytes(moniker).length > MAX_MONIKER_LENGTH) {
            revert Errors.MonikerTooLong(MAX_MONIKER_LENGTH, bytes(moniker).length);
        }
    }

    /// @notice Validate consensus public key with proof of possession
    /// @dev Calls the BLS12-381 PoP verification precompile at 0x1625F5001.
    ///      Input: pubkey (48 bytes) || pop (96 bytes) = 144 bytes
    ///      Output: ABI-encoded uint256 (32 bytes): 1 = valid, 0 = invalid
    ///      The precompile performs full validation: deserialization, subgroup check,
    ///      and PoP signature verification.
    function _validateConsensusPubkey(
        bytes calldata consensusPubkey,
        bytes calldata consensusPop
    ) internal view {
        bytes memory input = abi.encodePacked(consensusPubkey, consensusPop);
        (bool success, bytes memory result) = SystemAddresses.BLS_POP_VERIFY_PRECOMPILE.staticcall(input);
        if (!success || result.length < 32 || abi.decode(result, (uint256)) == 0) {
            revert Errors.InvalidConsensusPopVerification();
        }
    }

    /// @notice Create the validator record
    function _createValidatorRecord(
        address stakePool,
        string calldata moniker,
        bytes calldata consensusPubkey,
        bytes calldata consensusPop,
        bytes calldata networkAddresses,
        bytes calldata fullnodeAddresses
    ) internal {
        // Validate consensus pubkey with proof of possession
        _validateConsensusPubkey(consensusPubkey, consensusPop);

        ValidatorRecord storage record = _validators[stakePool];

        // Set identity and metadata
        record.validator = stakePool;
        record.moniker = moniker;
        record.stakingPool = stakePool;

        // Set fee recipient from staking contract
        record.feeRecipient = IStaking(SystemAddresses.STAKING).getPoolOwner(stakePool); // TODO(yxia): the fee recipient should be a parameter.

        // Set status and bond
        record.status = ValidatorStatus.INACTIVE;
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        record.bond = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool, now_);

        // Check consensus pubkey is unique
        bytes32 keyHash = keccak256(consensusPubkey);
        if (_pubkeyToValidator[keyHash] != address(0)) {
            revert Errors.DuplicateConsensusPubkey(consensusPubkey);
        }

        // Set consensus keys and register in mapping
        record.consensusPubkey = consensusPubkey;
        record.consensusPop = consensusPop;
        _pubkeyToValidator[keyHash] = stakePool;
        record.networkAddresses = networkAddresses;
        record.fullnodeAddresses = fullnodeAddresses;
    }

    // ========================================================================
    // LIFECYCLE
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function joinValidatorSet(
        address stakePool
    ) external validatorExists(stakePool) onlyOperator(stakePool) whenNotReconfiguring {
        ValidatorRecord storage validator = _validators[stakePool];

        // Verify validator set changes are allowed
        if (!IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).allowValidatorSetChange()) {
            revert Errors.ValidatorSetChangesDisabled();
        }

        // Verify validator is INACTIVE
        if (validator.status != ValidatorStatus.INACTIVE) {
            revert Errors.InvalidStatus(uint8(ValidatorStatus.INACTIVE), uint8(validator.status));
        }

        // Verify voting power still meets minimum
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint256 votingPower = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool, now_);
        uint256 minimumBond = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).minimumBond();
        if (votingPower < minimumBond) {
            revert Errors.InsufficientBond(minimumBond, votingPower);
        }

        // Verify max validator set size won't be exceeded
        uint256 maxSize = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).maxValidatorSetSize();
        if (_activeValidators.length + _pendingActive.length >= maxSize) {
            revert Errors.MaxValidatorSetSizeReached(maxSize);
        }

        // Change status to PENDING_ACTIVE
        validator.status = ValidatorStatus.PENDING_ACTIVE;
        _pendingActive.push(stakePool);

        emit ValidatorJoinRequested(stakePool);
    }

    /// @inheritdoc IValidatorManagement
    function leaveValidatorSet(
        address stakePool
    ) external validatorExists(stakePool) onlyOperator(stakePool) whenNotReconfiguring {
        ValidatorRecord storage validator = _validators[stakePool];

        // Verify validator set changes are allowed
        if (!IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).allowValidatorSetChange()) {
            revert Errors.ValidatorSetChangesDisabled();
        }

        // Handle leaving from PENDING_ACTIVE state (Aptos-style: remove from queue, revert to INACTIVE)
        if (validator.status == ValidatorStatus.PENDING_ACTIVE) {
            _removeFromPendingActive(stakePool);
            validator.status = ValidatorStatus.INACTIVE;
            emit ValidatorLeaveRequested(stakePool);
            return;
        }

        // Verify validator is ACTIVE
        if (validator.status != ValidatorStatus.ACTIVE) {
            revert Errors.InvalidStatus(uint8(ValidatorStatus.ACTIVE), uint8(validator.status));
        }

        // GRAV-005: Prevent removing the last active validator (would halt consensus).
        // Must count by status, not array length, because _activeValidators still
        // contains PENDING_INACTIVE validators until the next epoch boundary.
        if (_countActiveValidators() <= 1) {
            revert Errors.CannotRemoveLastValidator();
        }

        // Change status to PENDING_INACTIVE
        validator.status = ValidatorStatus.PENDING_INACTIVE;
        _pendingInactive.push(stakePool);

        emit ValidatorLeaveRequested(stakePool);
    }

    /// @inheritdoc IValidatorManagement
    function forceLeaveValidatorSet(
        address stakePool
    ) external validatorExists(stakePool) whenNotReconfiguring {
        requireAllowed(SystemAddresses.GOVERNANCE);

        ValidatorRecord storage validator = _validators[stakePool];

        // Handle from PENDING_ACTIVE: remove from queue, revert to INACTIVE
        if (validator.status == ValidatorStatus.PENDING_ACTIVE) {
            _removeFromPendingActive(stakePool);
            validator.status = ValidatorStatus.INACTIVE;
            emit ValidatorForceLeaveRequested(stakePool);
            return;
        }

        // Must be ACTIVE to force leave (PENDING_INACTIVE already leaving, INACTIVE already left)
        if (validator.status != ValidatorStatus.ACTIVE) {
            revert Errors.InvalidStatus(uint8(ValidatorStatus.ACTIVE), uint8(validator.status));
        }

        // Unlike voluntary leave, governance CAN remove the last validator
        // (emergency scenario where even consensus halt is acceptable)

        // Change status to PENDING_INACTIVE
        validator.status = ValidatorStatus.PENDING_INACTIVE;
        _pendingInactive.push(stakePool);

        emit ValidatorForceLeaveRequested(stakePool);
    }

    // ========================================================================
    // OPERATOR FUNCTIONS
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function rotateConsensusKey(
        address stakePool,
        bytes calldata newPubkey,
        bytes calldata newPop
    ) external validatorExists(stakePool) onlyOperator(stakePool) whenNotReconfiguring {
        // Validate consensus pubkey with proof of possession
        _validateConsensusPubkey(newPubkey, newPop);

        ValidatorRecord storage validator = _validators[stakePool];

        // Check new pubkey is unique
        bytes32 newKeyHash = keccak256(newPubkey);
        if (_pubkeyToValidator[newKeyHash] != address(0)) {
            revert Errors.DuplicateConsensusPubkey(newPubkey);
        }

        // Clear old pubkey from mapping and register new one
        bytes32 oldKeyHash = keccak256(validator.consensusPubkey);
        delete _pubkeyToValidator[oldKeyHash];
        _pubkeyToValidator[newKeyHash] = stakePool;

        // TODO(yxia): it wont take effect immediately i think, it has to wait until the next epoch.
        // check if aptos has some fancy way to make it take effect immediately.
        // Update consensus key material (takes effect immediately)
        validator.consensusPubkey = newPubkey;
        validator.consensusPop = newPop;

        emit ConsensusKeyRotated(stakePool, newPubkey);
    }

    /// @inheritdoc IValidatorManagement
    function setFeeRecipient(
        address stakePool,
        address newRecipient
    ) external validatorExists(stakePool) onlyOperator(stakePool) whenNotReconfiguring {
        ValidatorRecord storage validator = _validators[stakePool];

        // Set pending fee recipient (will take effect at next epoch)
        validator.pendingFeeRecipient = newRecipient;

        emit FeeRecipientUpdated(stakePool, newRecipient);
    }

    // ========================================================================
    // EPOCH PROCESSING
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    /// @dev Uses _computeNextEpochValidatorSet() as single source of truth.
    ///      This ensures getNextValidatorConsensusInfos() and onNewEpoch() produce identical results.
    function onNewEpoch() external {
        requireAllowed(SystemAddresses.RECONFIGURATION);

        // 1. Compute next validator set (single source of truth)
        //    This is the SAME computation used by getNextValidatorConsensusInfos()
        NextEpochValidatorSet memory nextSet = _computeNextEpochValidatorSet();

        // 2. Apply deactivations (PENDING_INACTIVE → INACTIVE)
        _applyDeactivations(nextSet.toDeactivate, nextSet.deactivateCount);

        // 3. Apply activations (PENDING_ACTIVE → ACTIVE)
        _applyActivations(nextSet.toActivate, nextSet.activateCount);

        // 4. Handle validators that dropped below minimum bond
        _applyRevertInactive(nextSet.toRevertInactive, nextSet.revertInactiveCount);

        // 5. Update pending active array (keep those that couldn't be activated)
        _updatePendingActive(nextSet.toKeepPending, nextSet.keepPendingCount);

        // 6. Overwrite _activeValidators with computed set
        //    This ensures _activeValidators matches exactly what getNextValidatorConsensusInfos() returned
        _setActiveValidators(nextSet.validators);

        // 7. Auto-renew lockups for active validators (Aptos-style)
        _renewActiveValidatorLockups();

        // 8. Apply pending fee recipient changes for all active validators
        _applyPendingFeeRecipients();

        // 9. Update bond (voting power) for all active validators
        //    This captures post-lockup-renewal voting power
        _syncValidatorBonds();

        // 10. Update total voting power
        //     Note: Epoch is managed by Reconfiguration contract (single source of truth)
        totalVotingPower = _calculateTotalVotingPower();

        // TODO(lightman): validator's voting power needs to be uint64 on the consensus engine.
        // NOTE: The NewEpochEvent (emitted by Reconfiguration._applyReconfiguration) contains
        // the full validator set for the consensus engine. EpochProcessed is for internal tracking.
        // Get next epoch from Reconfiguration (will be incremented after this call)
        uint64 nextEpoch = IReconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch() + 1;
        emit EpochProcessed(nextEpoch, _activeValidators.length, totalVotingPower);
    }

    /// @inheritdoc IValidatorManagement
    /// @dev Called by Reconfiguration BEFORE onNewEpoch() during epoch transition.
    ///      Reads the completed epoch's performance data and marks validators
    ///      with successfulProposals <= autoEvictThreshold as PENDING_INACTIVE.
    ///
    ///      ## Timing Difference from leaveValidatorSet
    ///
    ///      Voluntary leave (leaveValidatorSet):
    ///        Epoch N: operator calls leaveValidatorSet() → PENDING_INACTIVE
    ///                 validator stays in active set, continues consensus for remainder of epoch N
    ///        Epoch N+1 boundary: onNewEpoch() → INACTIVE
    ///
    ///      Auto-eviction (this function):
    ///        Epoch N→N+1 boundary: evictUnderperformingValidators() → PENDING_INACTIVE
    ///                              onNewEpoch() (same call) → INACTIVE
    ///        Result: ACTIVE → PENDING_INACTIVE → INACTIVE in ONE epoch transition
    ///
    ///      This is intentional: a validator with 0 proposals in epoch N is non-functional,
    ///      so there's no benefit to keeping it active for another epoch as a buffer.
    function evictUnderperformingValidators() external {
        requireAllowed(SystemAddresses.RECONFIGURATION);

        // Check if auto-eviction is enabled
        bool enabled = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).autoEvictEnabled();
        if (!enabled) {
            return;
        }

        uint256 threshold = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).autoEvictThreshold();

        // Read performance data from the completed epoch
        IValidatorPerformanceTracker.IndividualPerformance[] memory perfs =
            IValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER).getAllPerformances();

        uint256 activeLen = _activeValidators.length;
        uint256 perfLen = perfs.length;

        // Safety: perf array length should match active validator count.
        // Use min to avoid out-of-bounds if there's a mismatch.
        uint256 checkLen = activeLen < perfLen ? activeLen : perfLen;

        for (uint256 i = 0; i < checkLen; i++) {
            address pool = _activeValidators[i];
            ValidatorRecord storage validator = _validators[pool];

            // Only evict ACTIVE validators (skip if already PENDING_INACTIVE from manual leave)
            if (validator.status != ValidatorStatus.ACTIVE) {
                continue;
            }

            // Check if validator meets eviction criteria
            if (perfs[i].successfulProposals <= threshold) {
                // Preserve liveness: never evict the last active validator
                // Count remaining active validators (those not already pending inactive)
                uint256 remainingActive = 0;
                for (uint256 j = 0; j < activeLen; j++) {
                    if (_validators[_activeValidators[j]].status == ValidatorStatus.ACTIVE) {
                        remainingActive++;
                    }
                }
                if (remainingActive <= 1) {
                    // Cannot evict the last active validator — would halt consensus
                    break;
                }

                // Mark as PENDING_INACTIVE for processing by onNewEpoch()
                validator.status = ValidatorStatus.PENDING_INACTIVE;
                _pendingInactive.push(pool);

                emit ValidatorAutoEvicted(pool, perfs[i].successfulProposals);
            }
        }
    }

    /// @notice Apply deactivations for validators leaving the active set
    /// @param validators Array of validators to deactivate
    /// @param count Number of validators to process
    function _applyDeactivations(
        address[] memory validators,
        uint256 count
    ) internal {
        for (uint256 i = 0; i < count; i++) {
            address pool = validators[i];
            ValidatorRecord storage validator = _validators[pool];

            validator.status = ValidatorStatus.INACTIVE;
            validator.validatorIndex = type(uint64).max; // Clear index

            emit ValidatorDeactivated(pool);
        }
        delete _pendingInactive;
    }

    /// @notice Apply activations for validators joining the active set
    /// @param validators Array of validators to activate
    /// @param count Number of validators to process
    function _applyActivations(
        address[] memory validators,
        uint256 count
    ) internal {
        for (uint256 i = 0; i < count; i++) {
            address pool = validators[i];
            ValidatorRecord storage validator = _validators[pool];

            validator.status = ValidatorStatus.ACTIVE;
            // Note: bond and validatorIndex will be set in _setActiveValidators

            emit ValidatorActivated(pool, 0, _getValidatorVotingPower(pool));
        }
    }

    /// @notice Handle validators that dropped below minimum bond
    /// @param validators Array of validators to revert to inactive
    /// @param count Number of validators to process
    function _applyRevertInactive(
        address[] memory validators,
        uint256 count
    ) internal {
        for (uint256 i = 0; i < count; i++) {
            _validators[validators[i]].status = ValidatorStatus.INACTIVE;
        }
    }

    /// @notice Update pending active array with validators that remain pending
    /// @param validators Array of validators to keep pending
    /// @param count Number of validators to keep
    function _updatePendingActive(
        address[] memory validators,
        uint256 count
    ) internal {
        delete _pendingActive;
        for (uint256 i = 0; i < count; i++) {
            _pendingActive.push(validators[i]);
        }
    }

    /// @notice Overwrite _activeValidators with the computed validator set
    /// @dev This ensures _activeValidators matches exactly what _computeNextEpochValidatorSet() computed
    /// @param validators The computed validator set with fresh indices
    function _setActiveValidators(
        ValidatorConsensusInfo[] memory validators
    ) internal {
        delete _activeValidators;
        for (uint256 i = 0; i < validators.length; i++) {
            address pool = validators[i].validator;
            _activeValidators.push(pool);

            // Update validator record with computed values
            ValidatorRecord storage record = _validators[pool];
            record.validatorIndex = validators[i].validatorIndex;
            record.bond = validators[i].votingPower;
        }
    }

    /// @notice Auto-renew lockups for active validators (Aptos-style)
    /// @dev Calls Staking.renewPoolLockup() for each active validator.
    ///      This ensures active validators always have valid lockups for voting power.
    ///      Matches Aptos behavior in stake.move lines 1435-1449.
    function _renewActiveValidatorLockups() internal {
        uint256 length = _activeValidators.length;
        for (uint256 i = 0; i < length; i++) {
            address pool = _activeValidators[i];
            // Renew lockup via Staking factory (which calls StakePool.systemRenewLockup)
            IStaking(SystemAddresses.STAKING).renewPoolLockup(pool);
        }
    }

    /// @notice Apply pending fee recipient changes
    function _applyPendingFeeRecipients() internal {
        uint256 length = _activeValidators.length;
        for (uint256 i = 0; i < length; i++) {
            ValidatorRecord storage validator = _validators[_activeValidators[i]];
            if (validator.pendingFeeRecipient != address(0)) {
                validator.feeRecipient = validator.pendingFeeRecipient;
                validator.pendingFeeRecipient = address(0);
            }
        }
    }

    /// @notice Update bond (voting power) for all active validators
    /// @dev Called after lockup renewal to capture post-renewal voting power.
    ///      Note: owner/operator are not synced here - they are set during registration
    ///      and the authoritative source is always the StakePool contract.
    function _syncValidatorBonds() internal {
        uint256 length = _activeValidators.length;
        for (uint256 i = 0; i < length; i++) {
            address pool = _activeValidators[i];
            // Update bond (voting power snapshot after lockup renewal)
            _validators[pool].bond = _getValidatorVotingPower(pool);
        }
    }

    /// @notice Remove a validator from the pending active array
    /// @dev Used when a validator cancels their join request (leaves from PENDING_ACTIVE state)
    function _removeFromPendingActive(
        address pool
    ) internal {
        uint256 length = _pendingActive.length;
        for (uint256 i = 0; i < length; i++) {
            if (_pendingActive[i] == pool) {
                // Swap with last element and pop
                _pendingActive[i] = _pendingActive[length - 1];
                _pendingActive.pop();
                return;
            }
        }
    }

    /// @notice Count validators with ACTIVE status in the current active set
    /// @dev GRAV-005: _activeValidators.length includes PENDING_INACTIVE validators
    ///      that haven't been removed yet. This function counts only truly ACTIVE ones.
    function _countActiveValidators() internal view returns (uint256) {
        uint256 count = 0;
        uint256 length = _activeValidators.length;
        for (uint256 i = 0; i < length; i++) {
            if (_validators[_activeValidators[i]].status == ValidatorStatus.ACTIVE) {
                count++;
            }
        }
        return count;
    }

    /// @notice Calculate total voting power of active validators
    function _calculateTotalVotingPower() internal view returns (uint256) {
        uint256 total = 0;
        uint256 length = _activeValidators.length;
        for (uint256 i = 0; i < length; i++) {
            total += _getValidatorVotingPower(_activeValidators[i]);
        }
        return total;
    }

    /// @notice Get validator's voting power (capped at maximumBond)
    function _getValidatorVotingPower(
        address stakePool
    ) internal view returns (uint256) {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint256 power = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool, now_);
        uint256 maxBond = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).maximumBond();
        return power > maxBond ? maxBond : power;
    }

    /// @notice Compute the complete next epoch validator set
    /// @dev Single source of truth for both getNextValidatorConsensusInfos() and onNewEpoch().
    ///      This function computes:
    ///      1. Validators to deactivate (from _pendingInactive)
    ///      2. Active validators that stay (active minus pending_inactive)
    ///      3. Pending validators to activate (with min bond and voting power limit checks)
    ///      4. The complete validators array with fresh indices (0, 1, 2, ...)
    /// @return result The complete next epoch validator set with all transition info
    function _computeNextEpochValidatorSet() internal view returns (NextEpochValidatorSet memory result) {
        uint256 activeLen = _activeValidators.length;
        uint256 pendingActiveLen = _pendingActive.length;
        uint256 pendingInactiveLen = _pendingInactive.length;

        // Pre-allocate transition arrays
        result.toDeactivate = new address[](pendingInactiveLen);
        result.deactivateCount = pendingInactiveLen;
        result.toActivate = new address[](pendingActiveLen);
        result.toRevertInactive = new address[](pendingActiveLen);
        result.toKeepPending = new address[](pendingActiveLen);

        // Step 1: Identify validators to deactivate (all pending_inactive)
        for (uint256 i = 0; i < pendingInactiveLen; i++) {
            result.toDeactivate[i] = _pendingInactive[i];
        }

        // Step 2: Count staying active validators (active minus pending_inactive)
        uint256 stayingActiveCount = 0;
        for (uint256 i = 0; i < activeLen; i++) {
            if (!_isInPendingInactive(_activeValidators[i])) {
                stayingActiveCount++;
            }
        }

        // Step 3: Compute pending activation with voting power limits
        uint256 currentTotal = _calculateTotalVotingPower();
        uint64 limitPct = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).votingPowerIncreaseLimitPct();
        uint256 maxIncrease = (currentTotal * limitPct * PRECISION_FACTOR) / (100 * PRECISION_FACTOR);
        uint256 minimumBond = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).minimumBond();
        uint256 addedPower = 0;

        for (uint256 i = 0; i < pendingActiveLen; i++) {
            address pool = _pendingActive[i];
            uint256 power = _getValidatorVotingPower(pool);

            // Check minimum bond requirement
            if (power < minimumBond) {
                result.toRevertInactive[result.revertInactiveCount] = pool;
                result.revertInactiveCount++;
                continue;
            }

            // Check voting power increase limit
            // Note: if currentTotal is 0 (first validators), no limit applies
            if (currentTotal > 0 && addedPower + power > maxIncrease) {
                result.toKeepPending[result.keepPendingCount] = pool;
                result.keepPendingCount++;
                continue;
            }

            // Will be activated
            result.toActivate[result.activateCount] = pool;
            result.activateCount++;
            addedPower += power;
        }

        // Step 4: Build complete validators array with fresh indices
        uint256 totalValidators = stayingActiveCount + result.activateCount;
        result.validators = new ValidatorConsensusInfo[](totalValidators);
        uint256 idx = 0;

        // Add staying active validators (excluding pending_inactive)
        for (uint256 i = 0; i < activeLen; i++) {
            address pool = _activeValidators[i];
            if (!_isInPendingInactive(pool)) {
                ValidatorRecord storage validator = _validators[pool];
                result.validators[idx] = ValidatorConsensusInfo({
                    validator: pool,
                    consensusPubkey: validator.consensusPubkey,
                    consensusPop: validator.consensusPop,
                    votingPower: _getValidatorVotingPower(pool),
                    validatorIndex: uint64(idx),
                    networkAddresses: validator.networkAddresses,
                    fullnodeAddresses: validator.fullnodeAddresses
                });
                idx++;
            }
        }

        // Add validators being activated
        for (uint256 i = 0; i < result.activateCount; i++) {
            address pool = result.toActivate[i];
            ValidatorRecord storage validator = _validators[pool];
            result.validators[idx] = ValidatorConsensusInfo({
                validator: pool,
                consensusPubkey: validator.consensusPubkey,
                consensusPop: validator.consensusPop,
                votingPower: _getValidatorVotingPower(pool),
                validatorIndex: uint64(idx),
                networkAddresses: validator.networkAddresses,
                fullnodeAddresses: validator.fullnodeAddresses
            });
            idx++;
        }

        return result;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function getValidator(
        address stakePool
    ) external view returns (ValidatorRecord memory) {
        if (_validators[stakePool].validator == address(0)) {
            revert Errors.ValidatorNotFound(stakePool);
        }
        return _validators[stakePool];
    }

    /// @inheritdoc IValidatorManagement
    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        uint256 length = _activeValidators.length;
        ValidatorConsensusInfo[] memory result = new ValidatorConsensusInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            address pool = _activeValidators[i];
            ValidatorRecord storage validator = _validators[pool];

            result[i] = ValidatorConsensusInfo({
                validator: pool,
                consensusPubkey: validator.consensusPubkey,
                consensusPop: validator.consensusPop,
                votingPower: validator.bond,
                validatorIndex: validator.validatorIndex,
                networkAddresses: validator.networkAddresses,
                fullnodeAddresses: validator.fullnodeAddresses
            });
        }

        return result;
    }

    /// @inheritdoc IValidatorManagement
    function getActiveValidatorByIndex(
        uint64 index
    ) external view returns (ValidatorConsensusInfo memory) {
        if (index >= _activeValidators.length) {
            revert Errors.ValidatorIndexOutOfBounds(index, uint64(_activeValidators.length));
        }

        address pool = _activeValidators[index];
        ValidatorRecord storage validator = _validators[pool];

        return ValidatorConsensusInfo({
            validator: pool,
            consensusPubkey: validator.consensusPubkey,
            consensusPop: validator.consensusPop,
            votingPower: validator.bond,
            validatorIndex: validator.validatorIndex,
            networkAddresses: validator.networkAddresses,
            fullnodeAddresses: validator.fullnodeAddresses
        });
    }

    /// @inheritdoc IValidatorManagement
    function getTotalVotingPower() external view returns (uint256) {
        return totalVotingPower;
    }

    /// @inheritdoc IValidatorManagement
    function getActiveValidatorCount() external view returns (uint256) {
        return _activeValidators.length;
    }

    /// @inheritdoc IValidatorManagement
    /// @dev Returns false for pools that have never registered as validators.
    ///      This is the correct way to check if a pool can be queried for validator info.
    function isValidator(
        address stakePool
    ) external view returns (bool) {
        return _validators[stakePool].validator != address(0);
    }

    /// @inheritdoc IValidatorManagement
    /// @dev Reverts for unregistered pools. Use isValidator() to check registration first.
    ///      Registered validators default to INACTIVE status until they join the validator set.
    function getValidatorStatus(
        address stakePool
    ) external view returns (ValidatorStatus) {
        if (_validators[stakePool].validator == address(0)) {
            revert Errors.ValidatorNotFound(stakePool);
        }
        return _validators[stakePool].status;
    }

    /// @inheritdoc IValidatorManagement
    /// @dev Queries Reconfiguration contract as the single source of truth for epoch number
    function getCurrentEpoch() external view returns (uint64) {
        return IReconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch();
    }

    /// @inheritdoc IValidatorManagement
    function getPendingActiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        uint256 length = _pendingActive.length;
        ValidatorConsensusInfo[] memory result = new ValidatorConsensusInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            address pool = _pendingActive[i];
            ValidatorRecord storage validator = _validators[pool];

            result[i] = ValidatorConsensusInfo({
                validator: pool,
                consensusPubkey: validator.consensusPubkey,
                consensusPop: validator.consensusPop,
                votingPower: _getValidatorVotingPower(pool),
                validatorIndex: type(uint64).max, // Not yet assigned
                networkAddresses: validator.networkAddresses,
                fullnodeAddresses: validator.fullnodeAddresses
            });
        }

        return result;
    }

    /// @inheritdoc IValidatorManagement
    function getPendingInactiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        uint256 length = _pendingInactive.length;
        ValidatorConsensusInfo[] memory result = new ValidatorConsensusInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            address pool = _pendingInactive[i];
            ValidatorRecord storage validator = _validators[pool];

            result[i] = ValidatorConsensusInfo({
                validator: pool,
                consensusPubkey: validator.consensusPubkey,
                consensusPop: validator.consensusPop,
                votingPower: validator.bond,
                validatorIndex: validator.validatorIndex,
                networkAddresses: validator.networkAddresses,
                fullnodeAddresses: validator.fullnodeAddresses
            });
        }

        return result;
    }

    // ========================================================================
    // Reconfiguration Support Functions
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    /// @dev Returns active + pending_inactive validators, ordered by their current validator index.
    ///      The position in the returned array matches the validator's stored validatorIndex.
    ///      This is used for DKG dealers - validators who can participate in running DKG.
    ///      Note: _activeValidators already contains pending_inactive validators until epoch boundary.
    function getCurValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory) {
        // _activeValidators already contains all current epoch validators
        // including those with PENDING_INACTIVE status (they stay in active set until epoch boundary)
        uint256 activeLen = _activeValidators.length;

        if (activeLen == 0) {
            return new ValidatorConsensusInfo[](0);
        }

        // Pre-allocate result array sized for all current validators
        ValidatorConsensusInfo[] memory result = new ValidatorConsensusInfo[](activeLen);

        // Active validators are already ordered by index in _activeValidators
        // Their validatorIndex matches their position in the array
        for (uint256 i = 0; i < activeLen; i++) {
            address pool = _activeValidators[i];
            ValidatorRecord storage validator = _validators[pool];

            result[i] = ValidatorConsensusInfo({
                validator: pool,
                consensusPubkey: validator.consensusPubkey,
                consensusPop: validator.consensusPop,
                votingPower: validator.bond,
                validatorIndex: uint64(i),
                networkAddresses: validator.networkAddresses,
                fullnodeAddresses: validator.fullnodeAddresses
            });
        }

        return result;
    }

    /// @inheritdoc IValidatorManagement
    /// @dev Computes the projected next epoch validator set for DKG targets.
    ///      Uses _computeNextEpochValidatorSet() as single source of truth.
    ///      IMPORTANT: Indices are FRESHLY ASSIGNED (0, 1, 2, ...) based on position in the
    ///      returned array. This matches Aptos's next_validator_consensus_infos() behavior.
    ///
    ///      NOTE: This function reads current voting power which depends on lockup state.
    ///      During reconfiguration, all staking operations are blocked (see whenNotReconfiguring),
    ///      so the validator set is effectively frozen. The DKG captures validators at the start
    ///      of reconfiguration via the DKGStartEvent, ensuring immutability during the DKG window.
    function getNextValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory) {
        return _computeNextEpochValidatorSet().validators;
    }

    /// @notice Check if a pool is in the pending_inactive array
    /// @param pool The pool address to check
    /// @return True if the pool is pending deactivation
    function _isInPendingInactive(
        address pool
    ) internal view returns (bool) {
        uint256 length = _pendingInactive.length;
        for (uint256 i = 0; i < length; i++) {
            if (_pendingInactive[i] == pool) {
                return true;
            }
        }
        return false;
    }
}

