// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IValidatorManagement} from "./IValidatorManagement.sol";
import {IStaking} from "./IStaking.sol";
import {ValidatorRecord, ValidatorStatus, ValidatorConsensusInfo} from "../foundation/Types.sol";
import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {requireAllowed} from "../foundation/SystemAccessControl.sol";
import {Errors} from "../foundation/Errors.sol";

/// @notice Interface for ValidatorConfig contract
interface IValidatorConfigVM {
    function minimumBond() external view returns (uint256);
    function maximumBond() external view returns (uint256);
    function allowValidatorSetChange() external view returns (bool);
    function votingPowerIncreaseLimitPct() external view returns (uint64);
    function maxValidatorSetSize() external view returns (uint256);
}

/// @title ValidatorManagement
/// @author Gravity Team
/// @notice Manages validator registration, lifecycle transitions, and validator set state
/// @dev Validators must have a StakePool with sufficient voting power to register.
///      ValidatorManager only interacts with the Staking factory contract, never StakePool directly.
///      Validator indices are assigned at each epoch boundary like Aptos.
contract ValidatorManagement is IValidatorManagement {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum moniker length in bytes
    uint256 public constant MAX_MONIKER_LENGTH = 31;

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

    /// @notice Current epoch number
    uint64 public currentEpoch;

    /// @notice Total voting power of active validators (snapshotted at epoch boundary)
    uint256 public totalVotingPower;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Ensures the caller is the operator of the given stake pool
    modifier onlyOperator(address stakePool) {
        address operator = IStaking(SystemAddresses.STAKING).getPoolOperator(stakePool);
        if (msg.sender != operator) {
            revert Errors.NotOperator(operator, msg.sender);
        }
        _;
    }

    /// @notice Ensures the validator exists
    modifier validatorExists(address stakePool) {
        if (_validators[stakePool].validator == address(0)) {
            revert Errors.ValidatorNotFound(stakePool);
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
    function _validateRegistration(address stakePool, string calldata moniker) internal view {
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
        uint256 votingPower = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool);
        uint256 minimumBond = IValidatorConfigVM(SystemAddresses.VALIDATOR_CONFIG).minimumBond();
        if (votingPower < minimumBond) {
            revert Errors.InsufficientBond(minimumBond, votingPower);
        }

        // Verify moniker length
        if (bytes(moniker).length > MAX_MONIKER_LENGTH) {
            revert Errors.MonikerTooLong(MAX_MONIKER_LENGTH, bytes(moniker).length);
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
        ValidatorRecord storage record = _validators[stakePool];

        // Set identity and metadata
        record.validator = stakePool;
        record.moniker = moniker;
        record.stakingPool = stakePool;

        // Set roles from staking contract
        record.owner = IStaking(SystemAddresses.STAKING).getPoolOwner(stakePool);
        record.operator = IStaking(SystemAddresses.STAKING).getPoolOperator(stakePool);
        record.feeRecipient = record.owner;

        // Set status and bond
        record.status = ValidatorStatus.INACTIVE;
        record.bond = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool);

        // Set consensus keys
        record.consensusPubkey = consensusPubkey;
        record.consensusPop = consensusPop;
        record.networkAddresses = networkAddresses;
        record.fullnodeAddresses = fullnodeAddresses;
    }

    // ========================================================================
    // LIFECYCLE
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function joinValidatorSet(address stakePool) external validatorExists(stakePool) onlyOperator(stakePool) {
        ValidatorRecord storage validator = _validators[stakePool];

        // Verify validator set changes are allowed
        if (!IValidatorConfigVM(SystemAddresses.VALIDATOR_CONFIG).allowValidatorSetChange()) {
            revert Errors.ValidatorSetChangesDisabled();
        }

        // Verify validator is INACTIVE
        if (validator.status != ValidatorStatus.INACTIVE) {
            revert Errors.InvalidStatus(uint8(ValidatorStatus.INACTIVE), uint8(validator.status));
        }

        // Verify voting power still meets minimum
        uint256 votingPower = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool);
        uint256 minimumBond = IValidatorConfigVM(SystemAddresses.VALIDATOR_CONFIG).minimumBond();
        if (votingPower < minimumBond) {
            revert Errors.InsufficientBond(minimumBond, votingPower);
        }

        // Verify max validator set size won't be exceeded
        uint256 maxSize = IValidatorConfigVM(SystemAddresses.VALIDATOR_CONFIG).maxValidatorSetSize();
        if (_activeValidators.length + _pendingActive.length >= maxSize) {
            revert Errors.MaxValidatorSetSizeReached(maxSize);
        }

        // Change status to PENDING_ACTIVE
        validator.status = ValidatorStatus.PENDING_ACTIVE;
        _pendingActive.push(stakePool);

        emit ValidatorJoinRequested(stakePool);
    }

    /// @inheritdoc IValidatorManagement
    function leaveValidatorSet(address stakePool) external validatorExists(stakePool) onlyOperator(stakePool) {
        ValidatorRecord storage validator = _validators[stakePool];

        // Verify validator is ACTIVE
        if (validator.status != ValidatorStatus.ACTIVE) {
            revert Errors.InvalidStatus(uint8(ValidatorStatus.ACTIVE), uint8(validator.status));
        }

        // Change status to PENDING_INACTIVE
        validator.status = ValidatorStatus.PENDING_INACTIVE;
        _pendingInactive.push(stakePool);

        emit ValidatorLeaveRequested(stakePool);
    }

    // ========================================================================
    // OPERATOR FUNCTIONS
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function rotateConsensusKey(address stakePool, bytes calldata newPubkey, bytes calldata newPop)
        external
        validatorExists(stakePool)
        onlyOperator(stakePool)
    {
        ValidatorRecord storage validator = _validators[stakePool];

        // Update consensus key material (takes effect immediately)
        validator.consensusPubkey = newPubkey;
        validator.consensusPop = newPop;

        emit ConsensusKeyRotated(stakePool, newPubkey);
    }

    /// @inheritdoc IValidatorManagement
    function setFeeRecipient(address stakePool, address newRecipient)
        external
        validatorExists(stakePool)
        onlyOperator(stakePool)
    {
        ValidatorRecord storage validator = _validators[stakePool];

        // Set pending fee recipient (will take effect at next epoch)
        validator.pendingFeeRecipient = newRecipient;

        emit FeeRecipientUpdated(stakePool, newRecipient);
    }

    // ========================================================================
    // EPOCH PROCESSING
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function onNewEpoch() external {
        requireAllowed(SystemAddresses.EPOCH_MANAGER);

        // 1. Process PENDING_INACTIVE → INACTIVE (clear indices, remove from active)
        _processPendingInactive();

        // 2. Process PENDING_ACTIVE → ACTIVE (with voting power limit check)
        _processPendingActive();

        // 3. Apply pending fee recipient changes for all active validators
        _applyPendingFeeRecipients();

        // 4. Update owner/operator from stake pool for all active validators
        _syncValidatorRoles();

        // 5. Reassign indices for all active validators
        _reassignValidatorIndices();

        // 6. Update epoch state
        currentEpoch++;
        totalVotingPower = _calculateTotalVotingPower();

        emit EpochProcessed(currentEpoch, _activeValidators.length, totalVotingPower);
    }

    /// @notice Process validators leaving the active set
    function _processPendingInactive() internal {
        uint256 length = _pendingInactive.length;
        for (uint256 i = 0; i < length; i++) {
            address pool = _pendingInactive[i];
            ValidatorRecord storage validator = _validators[pool];

            // Update status
            validator.status = ValidatorStatus.INACTIVE;
            validator.validatorIndex = 0; // Clear index

            // Remove from active validators array
            _removeFromActiveValidators(pool);

            emit ValidatorDeactivated(pool);
        }
        delete _pendingInactive;
    }

    /// @notice Process validators joining the active set (with voting power limit)
    function _processPendingActive() internal {
        if (_pendingActive.length == 0) return;

        // Calculate current total voting power (before adding new validators)
        uint256 currentTotal = _calculateTotalVotingPower();
        uint64 limitPct = IValidatorConfigVM(SystemAddresses.VALIDATOR_CONFIG).votingPowerIncreaseLimitPct();
        uint256 maxIncrease = currentTotal * limitPct / 100;
        uint256 addedPower = 0;

        // Track which validators we activate and which remain pending
        address[] memory toActivate = new address[](_pendingActive.length);
        address[] memory toKeepPending = new address[](_pendingActive.length);
        uint256 activateCount = 0;
        uint256 keepPendingCount = 0;

        uint256 length = _pendingActive.length;
        uint256 minimumBond = IValidatorConfigVM(SystemAddresses.VALIDATOR_CONFIG).minimumBond();

        for (uint256 i = 0; i < length; i++) {
            address pool = _pendingActive[i];

            // Get current voting power (may have changed since join request)
            uint256 power = _getValidatorVotingPower(pool);

            // Check minimum bond still met
            if (power < minimumBond) {
                // Validator dropped below minimum, revert to INACTIVE
                _validators[pool].status = ValidatorStatus.INACTIVE;
                continue;
            }

            // Check voting power increase limit
            // Note: if currentTotal is 0 (first validators), no limit applies
            if (currentTotal > 0 && addedPower + power > maxIncrease) {
                // Keep in pending for next epoch (status remains PENDING_ACTIVE)
                toKeepPending[keepPendingCount] = pool;
                keepPendingCount++;
                continue;
            }

            // Mark for activation
            toActivate[activateCount] = pool;
            activateCount++;
            addedPower += power;
        }

        // Clear pending active array and repopulate with those that couldn't be activated
        delete _pendingActive;
        for (uint256 i = 0; i < keepPendingCount; i++) {
            _pendingActive.push(toKeepPending[i]);
        }

        // Activate validators
        for (uint256 i = 0; i < activateCount; i++) {
            address pool = toActivate[i];
            ValidatorRecord storage validator = _validators[pool];

            validator.status = ValidatorStatus.ACTIVE;
            validator.bond = _getValidatorVotingPower(pool); // Snapshot voting power
            _activeValidators.push(pool);

            // Index will be assigned in _reassignValidatorIndices
            emit ValidatorActivated(pool, 0, validator.bond); // Index updated after reassignment
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

    /// @notice Sync owner/operator from stake pool
    function _syncValidatorRoles() internal {
        uint256 length = _activeValidators.length;
        for (uint256 i = 0; i < length; i++) {
            address pool = _activeValidators[i];
            ValidatorRecord storage validator = _validators[pool];

            // Update owner and operator from stake pool
            validator.owner = IStaking(SystemAddresses.STAKING).getPoolOwner(pool);
            validator.operator = IStaking(SystemAddresses.STAKING).getPoolOperator(pool);

            // Update bond (voting power snapshot)
            validator.bond = _getValidatorVotingPower(pool);
        }
    }

    /// @notice Reassign validator indices (0 to n-1)
    function _reassignValidatorIndices() internal {
        uint256 length = _activeValidators.length;
        for (uint64 i = 0; i < length; i++) {
            _validators[_activeValidators[i]].validatorIndex = i;
        }
    }

    /// @notice Remove a validator from the active validators array
    function _removeFromActiveValidators(address pool) internal {
        uint256 length = _activeValidators.length;
        for (uint256 i = 0; i < length; i++) {
            if (_activeValidators[i] == pool) {
                // Swap with last element and pop
                _activeValidators[i] = _activeValidators[length - 1];
                _activeValidators.pop();
                return;
            }
        }
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
    function _getValidatorVotingPower(address stakePool) internal view returns (uint256) {
        uint256 power = IStaking(SystemAddresses.STAKING).getPoolVotingPower(stakePool);
        uint256 maxBond = IValidatorConfigVM(SystemAddresses.VALIDATOR_CONFIG).maximumBond();
        return power > maxBond ? maxBond : power;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IValidatorManagement
    function getValidator(address stakePool) external view returns (ValidatorRecord memory) {
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
                votingPower: validator.bond
            });
        }

        return result;
    }

    /// @inheritdoc IValidatorManagement
    function getActiveValidatorByIndex(uint64 index) external view returns (ValidatorConsensusInfo memory) {
        if (index >= _activeValidators.length) {
            revert Errors.ValidatorIndexOutOfBounds(index, uint64(_activeValidators.length));
        }

        address pool = _activeValidators[index];
        ValidatorRecord storage validator = _validators[pool];

        return ValidatorConsensusInfo({
            validator: pool,
            consensusPubkey: validator.consensusPubkey,
            consensusPop: validator.consensusPop,
            votingPower: validator.bond
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
    function isValidator(address stakePool) external view returns (bool) {
        return _validators[stakePool].validator != address(0);
    }

    /// @inheritdoc IValidatorManagement
    function getValidatorStatus(address stakePool) external view returns (ValidatorStatus) {
        if (_validators[stakePool].validator == address(0)) {
            revert Errors.ValidatorNotFound(stakePool);
        }
        return _validators[stakePool].status;
    }

    /// @inheritdoc IValidatorManagement
    function getCurrentEpoch() external view returns (uint64) {
        return currentEpoch;
    }

    /// @inheritdoc IValidatorManagement
    function getPendingActiveValidators() external view returns (address[] memory) {
        return _pendingActive;
    }

    /// @inheritdoc IValidatorManagement
    function getPendingInactiveValidators() external view returns (address[] memory) {
        return _pendingInactive;
    }
}

