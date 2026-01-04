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
/// @notice Individual stake pool contract with O(log n) bucket-based withdrawals
/// @dev Created via CREATE2 by the Staking factory. Each user creates their own pool.
///      Implements two-role separation:
///      - Owner: Administrative control (set voter/operator/staker, ownership via Ownable2Step)
///      - Staker: Fund management (stake/unstake/withdraw)
///
///      Withdrawal Model:
///      - unstake() creates pending buckets sorted by lockedUntil with prefix-sum cumulativeAmount
///      - withdrawAvailable() claims all pending where (now > lockedUntil + unbondingDelay)
///      - immediateWithdraw() directly withdraws unlocked+unbonded active stake
///      - Voting power = activeStake - ineffective pending (via O(log n) binary search)
contract StakePool is IStakePool, Ownable2Step {
    // ========================================================================
    // IMMUTABLES
    // ========================================================================

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
        // Main stake must be locked at time T
        if (lockedUntil <= atTime) {
            return 0;
        }

        // Calculate effective stake (activeStake minus ineffective pending)
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
    function getAvailableForImmediateWithdrawal() external view returns (uint256) {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 unbondingDelay = IStakingConfig(SystemAddresses.STAKE_CONFIG).unbondingDelayMicros();

        // Check if stake is unlocked and past unbonding delay
        if (now_ <= lockedUntil + unbondingDelay) {
            return 0;
        }

        return activeStake;
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

        activeStake += msg.value;

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
    function unstake(
        uint256 amount
    ) external onlyStaker {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Check available active stake
        if (amount > activeStake) {
            revert Errors.InsufficientAvailableStake(amount, activeStake);
        }

        // For validators, check that effective stake after unstake >= minimumBond
        IValidatorManagement validatorMgmt = IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);
        if (validatorMgmt.isValidator(address(this))) {
            ValidatorStatus status = validatorMgmt.getValidatorStatus(address(this));
            if (status == ValidatorStatus.ACTIVE || status == ValidatorStatus.PENDING_INACTIVE) {
                uint256 minBond = IValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).minimumBond();
                uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

                // Calculate effective stake after this unstake
                uint256 currentEffective = _getEffectiveStakeAt(now_);

                // After unstake, effective stake will be reduced by amount
                if (currentEffective < amount + minBond) {
                    revert Errors.WithdrawalWouldBreachMinimumBond(currentEffective - amount, minBond);
                }
            }
        }

        // Reduce active stake
        activeStake -= amount;

        // Add to pending bucket with lockedUntil
        _addToPendingBucket(lockedUntil, amount);

        emit Unstaked(address(this), amount, lockedUntil);
    }

    /// @inheritdoc IStakePool
    function immediateWithdraw(
        uint256 amount,
        address recipient
    ) external onlyStaker {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 unbondingDelay = IStakingConfig(SystemAddresses.STAKE_CONFIG).unbondingDelayMicros();

        // Check if stake is unlocked and past unbonding delay
        if (now_ <= lockedUntil + unbondingDelay) {
            revert Errors.WithdrawalNotClaimable(lockedUntil + unbondingDelay, now_);
        }

        // Check available active stake
        if (amount > activeStake) {
            revert Errors.InsufficientAvailableStake(amount, activeStake);
        }

        // Update state (CEI pattern)
        activeStake -= amount;

        emit ImmediateWithdrawal(address(this), amount, recipient);

        // Transfer tokens to recipient
        (bool success,) = payable(recipient).call{ value: amount }("");
        if (!success) revert Errors.TransferFailed();
    }

    /// @inheritdoc IStakePool
    function withdrawAvailable(
        address recipient
    ) external onlyStaker returns (uint256 amount) {
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
    /// @dev Effective stake = activeStake - (pending that has become ineffective by time T)
    ///      A pending bucket is "ineffective" when its lockedUntil <= T
    /// @param atTime The timestamp to calculate at (microseconds)
    /// @return Effective stake amount
    function _getEffectiveStakeAt(
        uint64 atTime
    ) internal view returns (uint256) {
        // Find cumulative amount of pending that has become ineffective (lockedUntil <= atTime)
        uint256 ineffective = _getCumulativeAmountAtTime(atTime);

        // Subtract already claimed amount (those tokens are no longer in the pool)
        if (ineffective <= claimedAmount) {
            ineffective = 0;
        } else {
            ineffective -= claimedAmount;
        }

        // Return activeStake (pending is already separate from activeStake)
        // The "ineffective" here means pending that should NOT count as voting power
        // Since pending is already not in activeStake, we return activeStake directly
        // Wait - let me reconsider...

        // Actually, for voting power calculation:
        // - activeStake = stake not in pending (available to stake more or withdraw immediately when unlocked)
        // - pending = stake that has been unstaked but not yet claimed

        // Effective stake for voting = activeStake + pending that is still "effective"
        // Pending is "effective" if its lockedUntil > atTime (still locked at that time)
        // Pending is "ineffective" if its lockedUntil <= atTime (will be unlocked at that time)

        // So: effectiveStake = activeStake + (totalPending - ineffectivePending)
        //                    = activeStake + totalPending - ineffectivePending

        uint256 totalPending;
        if (_pendingBuckets.length > 0) {
            totalPending = _pendingBuckets[_pendingBuckets.length - 1].cumulativeAmount - claimedAmount;
        }

        // ineffective = cumulative at atTime - claimedAmount (capped at 0)
        // effectivePending = totalPending - ineffective

        if (ineffective >= totalPending) {
            // All pending is ineffective
            return activeStake;
        }

        return activeStake + (totalPending - ineffective);
    }

    /// @notice Binary search to find cumulative amount at time T
    /// @dev Finds the last bucket where lockedUntil <= threshold and returns its cumulativeAmount
    /// @param threshold The time threshold (microseconds)
    /// @return Cumulative amount of pending that is ineffective (lockedUntil <= threshold)
    function _getCumulativeAmountAtTime(
        uint64 threshold
    ) internal view returns (uint256) {
        uint256 len = _pendingBuckets.length;
        if (len == 0) {
            return 0;
        }

        // Binary search for the largest index where lockedUntil <= threshold
        // If no such index exists, return 0

        // Check if all buckets are after threshold
        // This ensures that left is always less or equal to threshold
        if (_pendingBuckets[0].lockedUntil > threshold) {
            return 0;
        }

        // Check if all buckets are at or before threshold
        // This ensure that the right is always greater than threshold
        if (_pendingBuckets[len - 1].lockedUntil <= threshold) {
            return _pendingBuckets[len - 1].cumulativeAmount;
        }

        // Binary search: find largest i where lockedUntil[i] <= threshold
        // [left, right), find the largest left where left + 1 == right
        uint256 left = 0;
        uint256 right = len - 1;

        while (left + 1 < right) {
            uint256 mid = (left + right) >> 1;

            if (_pendingBuckets[mid].lockedUntil <= threshold) {
                left = mid;
            } else {
                right = mid;
            }
        }

        // left now points to the largest index where lockedUntil <= threshold
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
        // i.e., lockedUntil < now - unbondingDelay
        // But be careful of underflow
        if (now_ <= unbondingDelay) {
            return 0;
        }
        uint64 threshold = now_ - unbondingDelay;

        // Find cumulative amount where lockedUntil <= threshold
        uint256 claimableCumulative = _getCumulativeAmountAtTime(threshold);

        // Subtract already claimed
        if (claimableCumulative <= claimedAmount) {
            return 0;
        }

        return claimableCumulative - claimedAmount;
    }
}
