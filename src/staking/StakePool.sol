// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IStakePool } from "./IStakePool.sol";
import { IValidatorManagement } from "./IValidatorManagement.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { Errors } from "../foundation/Errors.sol";
import { ValidatorStatus } from "../foundation/Types.sol";
import { ITimestamp } from "../runtime/ITimestamp.sol";
import { IStakingConfig } from "../runtime/IStakingConfig.sol";
import { IValidatorConfig } from "../runtime/IValidatorConfig.sol";
import { IReconfiguration } from "../blocker/IReconfiguration.sol";

/// @title StakePool
/// @author Gravity Team
/// @notice Individual stake pool contract with O(log n) bucket-based withdrawals
/// @dev Created via CREATE2 by the Staking factory. Each user creates their own pool.
///      Implements two-role separation:
///      - Owner: Administrative control (set voter/operator/staker, ownership via Ownable2Step)
///      - Staker: Fund management (stake/unstake/withdraw)
///
///      Withdrawal Model:
///      - unstake() creates pending buckets sorted by lockedUntil with prefix-sum cumulativeAmount
///      - withdrawAvailable() claims all pending where (now > lockedUntil + unbondingDelay)
///      - unstakeAndWithdraw() helper combines both operations
///      - Voting power = activeStake + effective pending (via O(log n) binary search)
contract StakePool is IStakePool, Ownable2Step, ReentrancyGuard {
    // ========================================================================
    // IMMUTABLES
    // ========================================================================

    /// @notice Maximum lockup duration (4 years in microseconds)
    uint64 public constant MAX_LOCKUP_DURATION = uint64(4 * 365 days) * 1_000_000;

    /// @notice Maximum number of pending withdrawal buckets
    uint256 public constant MAX_PENDING_BUCKETS = 1000;

    /// @notice Address of the Staking factory that created this pool
    address public immutable FACTORY;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Staker address (manages funds: stake/unstake/withdraw)
    address public staker;

    /// @notice Operator address (reserved for validator operations)
    address public operator;

    /// @notice Delegated voter address (votes in governance using pool's stake)
    address public voter;

    /// @notice Active staked amount (not including pending withdrawals)
    uint256 public activeStake;

    /// @notice Lockup expiration timestamp (microseconds)
    uint64 public lockedUntil;

    /// @notice Pending withdrawal buckets sorted by lockedUntil (strictly increasing)
    /// @dev Each bucket stores cumulativeAmount as prefix sum for O(log n) lookups
    PendingBucket[] internal _pendingBuckets;

    /// @notice Cumulative amount that has been claimed from pending buckets
    /// @dev Acts as a claim pointer - no need to delete buckets
    uint256 public claimedAmount;

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

    /// @notice Prevents operations during epoch transition (DKG in progress)
    /// @dev Mirrors Aptos's assert_reconfig_not_in_progress() - blocks staking operations during DKG.
    ///      This ensures consistent validator set state during the reconfiguration window.
    modifier whenNotReconfiguring() {
        if (IReconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress()) {
            revert Errors.ReconfigurationInProgress();
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
        activeStake = msg.value;

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
    function getActiveStake() external view returns (uint256) {
        return activeStake;
    }

    /// @inheritdoc IStakePool
    function getTotalPending() external view returns (uint256) {
        if (_pendingBuckets.length == 0) {
            return 0;
        }
        // Total pending = last bucket's cumulativeAmount - claimedAmount
        return _pendingBuckets[_pendingBuckets.length - 1].cumulativeAmount - claimedAmount;
    }

    /// @inheritdoc IStakePool
    function getVotingPower(
        uint64 atTime
    ) external view returns (uint256) {
        // Voting power = effective stake at time T
        return _getEffectiveStakeAt(atTime);
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
    function getPendingBucketCount() external view returns (uint256) {
        return _pendingBuckets.length;
    }

    /// @inheritdoc IStakePool
    function getPendingBucket(
        uint256 index
    ) external view returns (PendingBucket memory) {
        return _pendingBuckets[index];
    }

    /// @inheritdoc IStakePool
    function getClaimedAmount() external view returns (uint256) {
        return claimedAmount;
    }

    /// @inheritdoc IStakePool
    function getClaimableAmount() external view returns (uint256) {
        return _getClaimableAmount();
    }

    // ========================================================================
    // OWNER FUNCTIONS (via Ownable2Step)
    // ========================================================================

    /// @inheritdoc IStakePool
    function setOperator(
        address newOperator
    ) external onlyOwner {
        if (newOperator == address(0)) revert Errors.ZeroAddress();
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorChanged(address(this), oldOperator, newOperator);
    }

    /// @inheritdoc IStakePool
    function setVoter(
        address newVoter
    ) external onlyOwner {
        if (newVoter == address(0)) revert Errors.ZeroAddress();
        address oldVoter = voter;
        voter = newVoter;
        emit VoterChanged(address(this), oldVoter, newVoter);
    }

    /// @inheritdoc IStakePool
    function setStaker(
        address newStaker
    ) external onlyOwner {
        if (newStaker == address(0)) revert Errors.ZeroAddress();
        address oldStaker = staker;
        staker = newStaker;
        emit StakerChanged(address(this), oldStaker, newStaker);
    }

    // ========================================================================
    // STAKER FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStakePool
    function addStake() external payable onlyStaker whenNotReconfiguring {
        if (msg.value == 0) {
            revert Errors.ZeroAmount();
        }

        activeStake += msg.value;

        // Extend lockup if needed: lockedUntil = max(current, now + minLockupDuration)
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 minLockup = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();

        // Overflow check: ensure now_ + minLockup does not overflow uint64
        if (now_ > type(uint64).max - minLockup) {
            revert Errors.ExcessiveLockupDuration(minLockup, MAX_LOCKUP_DURATION);
        }
        uint64 newLockedUntil = now_ + minLockup;

        if (newLockedUntil > lockedUntil) {
            lockedUntil = newLockedUntil;
        }

        emit StakeAdded(address(this), msg.value);
    }

    /// @inheritdoc IStakePool
    function unstake(
        uint256 amount
    ) external onlyStaker whenNotReconfiguring {
        _unstake(amount);
    }

    /// @inheritdoc IStakePool
    function withdrawAvailable(
        address recipient
    ) external onlyStaker whenNotReconfiguring nonReentrant returns (uint256 amount) {
        amount = _withdrawAvailable(recipient);
    }

    /// @inheritdoc IStakePool
    function unstakeAndWithdraw(
        uint256 amount,
        address recipient
    ) external onlyStaker whenNotReconfiguring returns (uint256 withdrawn) {
        // First unstake the requested amount
        _unstake(amount);

        // Then withdraw any claimable pending amounts
        withdrawn = _withdrawAvailable(recipient);
    }

    /// @inheritdoc IStakePool
    function renewLockUntil(
        uint64 durationMicros
    ) external onlyStaker whenNotReconfiguring {
        // Max lockup protection
        if (durationMicros > MAX_LOCKUP_DURATION) {
            revert Errors.ExcessiveLockupDuration(durationMicros, MAX_LOCKUP_DURATION);
        }

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
        // Note: This does NOT affect existing pending buckets
        if (newLockedUntil > lockedUntil) {
            uint64 oldLockedUntil = lockedUntil;
            lockedUntil = newLockedUntil;
            emit LockupRenewed(address(this), oldLockedUntil, newLockedUntil);
        }
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Internal unstake implementation
    /// @param amount Amount to unstake
    function _unstake(
        uint256 amount
    ) internal {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Check available active stake
        if (amount > activeStake) {
            revert Errors.InsufficientAvailableStake(amount, activeStake);
        }

        // For active validators, activeStake must remain >= minimumBond after unstake
        // This is a simple, robust check that ensures the bond is always protected.
        // Combined with lockup auto-renewal at epoch boundaries, voting power is always >= minBond.
        IValidatorManagement validatorMgmt = IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);
        if (validatorMgmt.isValidator(address(this))) {
            ValidatorStatus status = validatorMgmt.getValidatorStatus(address(this));
            if (status == ValidatorStatus.ACTIVE || status == ValidatorStatus.PENDING_INACTIVE) {
                uint256 minBond = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).minimumBond();

                // Simple check: activeStake after unstake must be >= minBond
                if (activeStake - amount < minBond) {
                    revert Errors.WithdrawalWouldBreachMinimumBond(activeStake - amount, minBond);
                }
            }
        }

        // Reduce active stake
        activeStake -= amount;

        // Add to pending bucket with lockedUntil
        _addToPendingBucket(lockedUntil, amount);

        emit Unstaked(address(this), amount, lockedUntil);
    }

    /// @notice Internal withdrawAvailable implementation
    /// @param recipient Address to receive withdrawn funds
    /// @return amount Amount withdrawn
    function _withdrawAvailable(
        address recipient
    ) internal returns (uint256 amount) {
        amount = _getClaimableAmount();

        if (amount == 0) {
            return 0;
        }

        // Update claim pointer (CEI pattern)
        claimedAmount += amount;

        emit WithdrawalClaimed(address(this), amount, recipient);

        // Transfer tokens to recipient
        (bool success,) = payable(recipient).call{ value: amount }("");
        if (!success) revert Errors.TransferFailed();
    }

    /// @notice Add amount to pending bucket with given lockedUntil
    /// @dev Either merges into last bucket (if same lockedUntil) or appends new bucket
    /// @param bucketLockedUntil The lockedUntil for this pending amount
    /// @param amount Amount to add
    function _addToPendingBucket(
        uint64 bucketLockedUntil,
        uint256 amount
    ) internal {
        uint256 len = _pendingBuckets.length;

        if (len == 0) {
            // First bucket
            _pendingBuckets.push(PendingBucket({ lockedUntil: bucketLockedUntil, cumulativeAmount: amount }));
        } else {
            PendingBucket storage lastBucket = _pendingBuckets[len - 1];

            if (lastBucket.lockedUntil == bucketLockedUntil) {
                // Merge into last bucket (same lockedUntil)
                lastBucket.cumulativeAmount += amount;
            } else if (lastBucket.lockedUntil < bucketLockedUntil) {
                // Append new bucket (strictly increasing lockedUntil)
                if (len >= MAX_PENDING_BUCKETS) {
                    revert Errors.TooManyPendingBuckets(len, MAX_PENDING_BUCKETS);
                }
                uint256 newCumulative = lastBucket.cumulativeAmount + amount;
                _pendingBuckets.push(PendingBucket({ lockedUntil: bucketLockedUntil, cumulativeAmount: newCumulative }));
            } else {
                // This should not happen if lockup is always extended
                // But if it does (e.g., bug), we still need to handle it
                revert Errors.LockedUntilDecreased(lastBucket.lockedUntil, bucketLockedUntil);
            }
        }
    }

    /// @notice Calculate effective stake at a given time using O(log n) binary search
    /// @dev Effective stake = activeStake (if locked) + (pending that is still effective at time T)
    ///      Active stake is "effective" when pool's lockedUntil >= T (locked through that time)
    ///      A pending bucket is "effective" when its lockedUntil >= T
    ///      A pending bucket is "ineffective" when its lockedUntil < T (unlocked before that time)
    /// @param atTime The timestamp to calculate at (microseconds)
    /// @return Effective stake amount
    function _getEffectiveStakeAt(
        uint64 atTime
    ) internal view returns (uint256) {
        // Active stake is only effective if the pool's lockup covers atTime
        uint256 effectiveActive = (lockedUntil >= atTime) ? activeStake : 0;

        // Find cumulative amount of pending that has become ineffective (lockedUntil < atTime)
        uint256 ineffective = _getCumulativeAmountAtTime(atTime);

        // Subtract already claimed amount (those tokens are no longer in the pool)
        if (ineffective <= claimedAmount) {
            ineffective = 0;
        } else {
            ineffective -= claimedAmount;
        }

        // Effective stake for voting = effectiveActive + pending that is still "effective"
        // Pending is "effective" if its lockedUntil >= atTime (locked through that time)
        // Pending is "ineffective" if its lockedUntil < atTime (unlocked before that time)
        //
        // effectiveStake = effectiveActive + (totalPending - ineffectivePending)

        uint256 totalPending;
        if (_pendingBuckets.length > 0) {
            totalPending = _pendingBuckets[_pendingBuckets.length - 1].cumulativeAmount - claimedAmount;
        }

        if (ineffective >= totalPending) {
            // All pending is ineffective
            return effectiveActive;
        }

        return effectiveActive + (totalPending - ineffective);
    }

    /// @notice Binary search to find cumulative amount at time T
    /// @dev Finds the last bucket where lockedUntil < threshold and returns its cumulativeAmount
    /// @param threshold The time threshold (microseconds)
    /// @return Cumulative amount of pending that is ineffective (lockedUntil < threshold)
    function _getCumulativeAmountAtTime(
        uint64 threshold
    ) internal view returns (uint256) {
        uint256 len = _pendingBuckets.length;
        if (len == 0) {
            return 0;
        }

        // Binary search for the largest index where lockedUntil < threshold
        // If no such index exists, return 0

        // Check if all buckets are at or after threshold
        // This ensures that left is always strictly less than threshold
        if (_pendingBuckets[0].lockedUntil >= threshold) {
            return 0;
        }

        // Check if all buckets are strictly before threshold
        // This ensures that the right is always at or after threshold
        if (_pendingBuckets[len - 1].lockedUntil < threshold) {
            return _pendingBuckets[len - 1].cumulativeAmount;
        }

        // Binary search: find largest i where lockedUntil[i] < threshold
        // [left, right), find the largest left where left + 1 == right
        uint256 left = 0;
        uint256 right = len - 1;

        while (left + 1 < right) {
            uint256 mid = (left + right) >> 1;

            if (_pendingBuckets[mid].lockedUntil < threshold) {
                left = mid;
            } else {
                right = mid;
            }
        }

        // left now points to the largest index where lockedUntil < threshold
        return _pendingBuckets[left].cumulativeAmount;
    }

    /// @notice Calculate the amount available for withdrawal from pending buckets
    /// @dev Returns pending stake where (now > lockedUntil + unbondingDelay)
    /// @return Amount available for batch withdrawal
    function _getClaimableAmount() internal view returns (uint256) {
        if (_pendingBuckets.length == 0) {
            return 0;
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 unbondingDelay = IStakingConfig(SystemAddresses.STAKE_CONFIG).unbondingDelayMicros();

        // Calculate the threshold: lockedUntil must be such that now > lockedUntil + unbondingDelay
        // i.e., lockedUntil < now - unbondingDelay (strict inequality)
        // Binary search finds lockedUntil < threshold, so we use threshold = now - unbondingDelay directly.
        // Early return: if now <= unbondingDelay, nothing can be claimable yet (return 0, don't revert)
        if (now_ <= unbondingDelay) {
            return 0;
        }
        uint64 threshold = now_ - unbondingDelay;

        // Find cumulative amount where lockedUntil < threshold (i.e., lockedUntil < now - unbondingDelay)
        uint256 claimableCumulative = _getCumulativeAmountAtTime(threshold);

        // Subtract already claimed
        if (claimableCumulative <= claimedAmount) {
            return 0;
        }

        return claimableCumulative - claimedAmount;
    }
}
