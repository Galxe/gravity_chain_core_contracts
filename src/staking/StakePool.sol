// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IStakePool } from "./IStakePool.sol";
import { IValidatorManagement } from "./IValidatorManagement.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { Errors } from "../foundation/Errors.sol";
import { ValidatorStatus } from "../foundation/Types.sol";
import { ITimestamp } from "../runtime/ITimestamp.sol";
import { IStakingConfig } from "../runtime/IStakingConfig.sol";
import { IValidatorConfig } from "../runtime/IValidatorConfig.sol";

/// @title StakePool
/// @author Gravity Team
/// @notice Individual stake pool contract with queue-based withdrawals
/// @dev Created via CREATE2 by the Staking factory. Each user creates their own pool.
///      Implements two-role separation:
///      - Owner: Administrative control (set voter/operator/staker, ownership via Ownable2Step)
///      - Staker: Fund management (stake/requestWithdrawal/claimWithdrawal)
///
///      Withdrawal Model:
///      - requestWithdrawal() creates a pending entry with claimableTime = lockedUntil
///      - claimWithdrawal() transfers tokens when claimableTime is reached
///      - Voting power = stake - pending (where claimableTime < atTime + minLockupDuration)
contract StakePool is IStakePool, Ownable2Step {
    // ========================================================================
    // IMMUTABLES
    // ========================================================================

    /// @notice Address of the Staking factory that created this pool
    address public immutable FACTORY;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Staker address (manages funds: stake/requestWithdrawal/claimWithdrawal)
    address public staker;

    /// @notice Operator address (reserved for validator operations)
    address public operator;

    /// @notice Delegated voter address (votes in governance using pool's stake)
    address public voter;

    /// @notice Total staked amount (includes pending withdrawals until claimed)
    uint256 public stake;

    /// @notice Lockup expiration timestamp (microseconds)
    uint64 public lockedUntil;

    /// @notice Pending withdrawal requests by nonce
    mapping(uint256 => PendingWithdrawal) public pendingWithdrawals;

    /// @notice Next nonce to assign for withdrawal requests
    uint256 public withdrawalNonce;

    /// @notice Sum of all pending withdrawal amounts
    uint256 public totalPendingWithdrawals;

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Restricts function to staker only
    modifier onlyStaker() {
        if (msg.sender != staker) {
            revert Errors.NotStaker(msg.sender, staker);
        }
        _;
    }

    /// @notice Restricts function to the Staking factory only
    modifier onlyFactory() {
        if (msg.sender != FACTORY) {
            revert Errors.OnlyStakingFactory(msg.sender);
        }
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Initialize the stake pool with all parameters
    /// @param _owner Owner address for this pool (administrative control)
    /// @param _staker Staker address for this pool (fund management)
    /// @param _operator Operator address (for validator operations)
    /// @param _voter Voter address (for governance voting)
    /// @param _lockedUntil Initial lockup expiration (must be >= now + minLockup)
    /// @dev Called by factory during CREATE2 deployment
    constructor(
        address _owner,
        address _staker,
        address _operator,
        address _voter,
        uint64 _lockedUntil
    ) payable Ownable(_owner) {
        FACTORY = msg.sender;

        // Validate lockedUntil >= now + minLockup
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 minLockup = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        if (_lockedUntil < now_ + minLockup) {
            revert Errors.LockupDurationTooShort(_lockedUntil, now_ + minLockup);
        }

        staker = _staker;
        operator = _operator;
        voter = _voter;
        lockedUntil = _lockedUntil;
        stake = msg.value;

        emit StakeAdded(address(this), msg.value);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStakePool
    function getStaker() external view returns (address) {
        return staker;
    }

    /// @inheritdoc IStakePool
    function getOperator() external view returns (address) {
        return operator;
    }

    /// @inheritdoc IStakePool
    function getVoter() external view returns (address) {
        return voter;
    }

    /// @inheritdoc IStakePool
    function getStake() external view returns (uint256) {
        return stake;
    }

    /// @inheritdoc IStakePool
    function getVotingPower(
        uint64 atTime
    ) external view returns (uint256) {
        // Main stake must be locked at time T
        if (lockedUntil <= atTime) {
            return 0;
        }

        // Calculate effective stake (stake minus ineffective pending)
        uint256 effective = _getEffectiveStakeAt(atTime);
        return effective;
    }

    /// @inheritdoc IStakePool
    function getVotingPowerNow() external view returns (uint256) {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        return this.getVotingPower(now_);
    }

    /// @inheritdoc IStakePool
    function getEffectiveStake(
        uint64 atTime
    ) external view returns (uint256) {
        return _getEffectiveStakeAt(atTime);
    }

    /// @inheritdoc IStakePool
    function getLockedUntil() external view returns (uint64) {
        return lockedUntil;
    }

    /// @inheritdoc IStakePool
    function getRemainingLockup() external view returns (uint64) {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        if (lockedUntil > now_) {
            return lockedUntil - now_;
        }
        return 0;
    }

    /// @inheritdoc IStakePool
    function isLocked() external view returns (bool) {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        return lockedUntil > now_;
    }

    /// @inheritdoc IStakePool
    function getPendingWithdrawal(
        uint256 nonce
    ) external view returns (PendingWithdrawal memory) {
        return pendingWithdrawals[nonce];
    }

    /// @inheritdoc IStakePool
    function getTotalPendingWithdrawals() external view returns (uint256) {
        return totalPendingWithdrawals;
    }

    /// @inheritdoc IStakePool
    function getWithdrawalNonce() external view returns (uint256) {
        return withdrawalNonce;
    }

    // ========================================================================
    // OWNER FUNCTIONS (via Ownable2Step)
    // ========================================================================

    /// @inheritdoc IStakePool
    function setOperator(
        address newOperator
    ) external onlyOwner {
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorChanged(address(this), oldOperator, newOperator);
    }

    /// @inheritdoc IStakePool
    function setVoter(
        address newVoter
    ) external onlyOwner {
        address oldVoter = voter;
        voter = newVoter;
        emit VoterChanged(address(this), oldVoter, newVoter);
    }

    /// @inheritdoc IStakePool
    function setStaker(
        address newStaker
    ) external onlyOwner {
        address oldStaker = staker;
        staker = newStaker;
        emit StakerChanged(address(this), oldStaker, newStaker);
    }

    // ========================================================================
    // STAKER FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStakePool
    function addStake() external payable onlyStaker {
        if (msg.value == 0) {
            revert Errors.ZeroAmount();
        }

        stake += msg.value;

        // Extend lockup if needed: lockedUntil = max(current, now + minLockupDuration)
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 minLockup = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        uint64 newLockedUntil = now_ + minLockup;

        if (newLockedUntil > lockedUntil) {
            lockedUntil = newLockedUntil;
        }

        emit StakeAdded(address(this), msg.value);
    }

    /// @inheritdoc IStakePool
    function requestWithdrawal(
        uint256 amount
    ) external onlyStaker returns (uint256 nonce) {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Check available stake (stake - already pending withdrawals)
        uint256 available = stake - totalPendingWithdrawals;
        if (amount > available) {
            revert Errors.InsufficientAvailableStake(amount, available);
        }

        // For validators, check that effective stake after withdrawal >= minimumBond
        IValidatorManagement validatorMgmt = IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);
        if (validatorMgmt.isValidator(address(this))) {
            ValidatorStatus status = validatorMgmt.getValidatorStatus(address(this));
            if (status == ValidatorStatus.ACTIVE || status == ValidatorStatus.PENDING_INACTIVE) {
                uint256 minBond = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).minimumBond();
                uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

                // Calculate effective stake after this withdrawal
                // The new pending withdrawal will have claimableTime = lockedUntil
                // It becomes "ineffective" when (lockedUntil - atTime) < minLockupDuration
                uint256 currentEffective = _getEffectiveStakeAt(now_);

                // This withdrawal will reduce effective stake when it becomes "ineffective"
                // For simplicity, we check the worst case: effective stake minus requested amount
                if (currentEffective < amount + minBond) {
                    revert Errors.WithdrawalWouldBreachMinimumBond(currentEffective - amount, minBond);
                }
            }
        }

        // Create pending withdrawal with claimableTime = lockedUntil
        nonce = withdrawalNonce++;
        pendingWithdrawals[nonce] = PendingWithdrawal({ amount: amount, claimableTime: lockedUntil });
        totalPendingWithdrawals += amount;

        emit WithdrawalRequested(address(this), nonce, amount, lockedUntil);
    }

    /// @inheritdoc IStakePool
    function claimWithdrawal(
        uint256 nonce,
        address recipient
    ) external onlyStaker {
        PendingWithdrawal memory pending = pendingWithdrawals[nonce];

        // Check withdrawal exists
        if (pending.amount == 0) {
            revert Errors.WithdrawalNotFound(nonce);
        }

        // Check claimable time reached
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        if (pending.claimableTime > now_) {
            revert Errors.WithdrawalNotClaimable(pending.claimableTime, now_);
        }

        // Update state (CEI pattern)
        uint256 amount = pending.amount;
        delete pendingWithdrawals[nonce];
        stake -= amount;
        totalPendingWithdrawals -= amount;

        emit WithdrawalClaimed(address(this), nonce, amount, recipient);

        // Transfer tokens to recipient
        (bool success,) = payable(recipient).call{ value: amount }("");
        require(success, "StakePool: transfer failed");
    }

    /// @inheritdoc IStakePool
    function renewLockUntil(
        uint64 durationMicros
    ) external onlyStaker {
        // Check for overflow
        uint64 newLockedUntil = lockedUntil + durationMicros;
        if (newLockedUntil <= lockedUntil) {
            revert Errors.LockupOverflow(lockedUntil, durationMicros);
        }

        // Validate result >= now + minLockup
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 minLockup = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        if (newLockedUntil < now_ + minLockup) {
            revert Errors.LockupDurationTooShort(newLockedUntil, now_ + minLockup);
        }

        uint64 oldLockedUntil = lockedUntil;
        lockedUntil = newLockedUntil;

        emit LockupRenewed(address(this), oldLockedUntil, newLockedUntil);
    }

    // ========================================================================
    // SYSTEM FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStakePool
    function systemRenewLockup() external onlyFactory {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 lockupDuration = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        uint64 newLockedUntil = now_ + lockupDuration;

        // Only renew if lockup has expired or would expire soon
        // This matches Aptos behavior: auto-renew at epoch boundary if expired
        // Note: This does NOT affect existing pending withdrawals
        if (newLockedUntil > lockedUntil) {
            uint64 oldLockedUntil = lockedUntil;
            lockedUntil = newLockedUntil;
            emit LockupRenewed(address(this), oldLockedUntil, newLockedUntil);
        }
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Calculate effective stake at a given time
    /// @dev Effective stake = stake - pending withdrawals where remaining lockup < minLockupDuration
    /// @param atTime The timestamp to calculate at (microseconds)
    /// @return Effective stake amount
    function _getEffectiveStakeAt(
        uint64 atTime
    ) internal view returns (uint256) {
        uint64 minLockup = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();

        // Calculate threshold: pending withdrawals with claimableTime < (atTime + minLockup) are ineffective
        uint64 threshold = atTime + minLockup;

        // Sum up ineffective pending withdrawals
        uint256 ineffective = 0;
        for (uint256 i = 0; i < withdrawalNonce; i++) {
            PendingWithdrawal memory pending = pendingWithdrawals[i];
            if (pending.amount > 0 && pending.claimableTime < threshold) {
                ineffective += pending.amount;
            }
        }

        // Return effective stake
        if (ineffective >= stake) {
            return 0;
        }
        return stake - ineffective;
    }
}
