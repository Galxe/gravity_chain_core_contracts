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

/// @title StakePool
/// @author Gravity Team
/// @notice Individual stake pool contract with two-role separation
/// @dev Created via CREATE2 by the Staking factory. Each user creates their own pool.
///      Implements two-role separation:
///      - Owner: Administrative control (set voter/operator/staker, ownership via Ownable2Step)
///      - Staker: Fund management (stake/unstake/renewLockUntil) - can be a contract for DPOS, LSD, etc.
contract StakePool is IStakePool, Ownable2Step {
    // ========================================================================
    // IMMUTABLES
    // ========================================================================

    /// @notice Address of the Staking factory that created this pool
    address public immutable FACTORY;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Staker address (manages funds: stake/unstake/renewLockUntil)
    address public staker;

    /// @notice Operator address (reserved for validator operations)
    address public operator;

    /// @notice Delegated voter address (votes in governance using pool's stake)
    address public voter;

    /// @notice Total staked amount
    uint256 public stake;

    /// @notice Lockup expiration timestamp (microseconds)
    uint64 public lockedUntil;

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
    function getVotingPower() external view returns (uint256) {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        if (lockedUntil > now_) {
            return stake;
        }
        return 0;
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
    function withdraw(
        uint256 amount,
        address recipient
    ) external onlyStaker {
        // Check if this pool is an active validator (ACTIVE or PENDING_INACTIVE)
        // Active validators must leave the validator set before withdrawing
        IValidatorManagement validatorMgmt = IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);
        if (validatorMgmt.isValidator(address(this))) {
            ValidatorStatus status = validatorMgmt.getValidatorStatus(address(this));
            if (status == ValidatorStatus.ACTIVE || status == ValidatorStatus.PENDING_INACTIVE) {
                revert Errors.CannotWithdrawWhileActiveValidator(address(this));
            }
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // Check lockup expired
        if (lockedUntil > now_) {
            revert Errors.LockupNotExpired(lockedUntil, now_);
        }

        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        if (amount > stake) {
            revert Errors.InsufficientStake(amount, stake);
        }

        stake -= amount;

        emit StakeWithdrawn(address(this), amount, recipient);

        // Transfer tokens to recipient (CEI pattern - effects before interactions)
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
        if (newLockedUntil > lockedUntil) {
            uint64 oldLockedUntil = lockedUntil;
            lockedUntil = newLockedUntil;
            emit LockupRenewed(address(this), oldLockedUntil, newLockedUntil);
        }
    }
}
