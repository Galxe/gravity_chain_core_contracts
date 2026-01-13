// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Staking } from "../../../src/staking/Staking.sol";
import { IStaking } from "../../../src/staking/IStaking.sol";
import { IStakePool } from "../../../src/staking/IStakePool.sol";
import { StakePool } from "../../../src/staking/StakePool.sol";
import { StakingConfig } from "../../../src/runtime/StakingConfig.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorStatus } from "../../../src/foundation/Types.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";

/// @notice Mock ValidatorManagement for testing - all pools are non-validators
contract MockValidatorManagement {
    function isValidator(
        address /* stakePool */
    ) external pure returns (bool) {
        return false;
    }

    function getValidatorStatus(
        address /* stakePool */
    ) external pure returns (ValidatorStatus) {
        return ValidatorStatus.INACTIVE;
    }
}

/// @notice Mock Reconfiguration for testing - always returns not in progress
contract MockReconfiguration {
    function isTransitionInProgress() external pure returns (bool) {
        return false;
    }
}

/// @title StakingTest
/// @notice Unit tests for Staking factory and StakePool contracts with O(log n) bucket-based withdrawals
contract StakingTest is Test {
    Staking public staking;
    StakingConfig public stakingConfig;
    Timestamp public timestamp;

    // Test addresses
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public stakerContract = makeAddr("stakerContract");

    // Test constants
    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000; // 14 days in microseconds
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000; // 7 days in microseconds
    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000; // Initial time in microseconds

    function setUp() public {
        // Deploy contracts at system addresses
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        // Deploy mock ValidatorManagement - returns false for isValidator() so pools can withdraw
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new MockValidatorManagement()).code);

        // Deploy mock Reconfiguration - returns false for isTransitionInProgress() so staking operations work
        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfiguration()).code);

        // Initialize StakingConfig with unbonding delay
        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 10 ether);

        // Set initial timestamp
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP);

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(charlie, 1000 ether);
        vm.deal(stakerContract, 1000 ether);
    }

    // Helper to create a pool with default parameters (all roles = owner)
    function _createPool(
        address owner,
        uint256 value
    ) internal returns (address) {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;
        return staking.createPool{ value: value }(owner, owner, owner, owner, lockedUntil);
    }

    // Helper to create a pool with explicit staker
    function _createPoolWithStaker(
        address owner,
        address staker,
        uint256 value
    ) internal returns (address) {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;
        return staking.createPool{ value: value }(owner, staker, owner, owner, lockedUntil);
    }

    // ========================================================================
    // STAKING FACTORY TESTS
    // ========================================================================

    function test_createPool_createsNewPool() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        assertNotEq(pool, address(0), "Pool should be created");
        assertEq(staking.getPoolCount(), 1, "Pool count should be 1");
        assertEq(staking.getPool(0), pool, "Pool at index 0 should match");
    }

    function test_createPool_setsAllParameters() public {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        vm.prank(alice);
        address pool = staking.createPool{
            value: MIN_STAKE
        }(
            alice, // owner
            bob, // staker
            charlie, // operator
            alice, // voter
            lockedUntil
        );

        assertEq(Ownable(pool).owner(), alice, "Owner should be alice");
        assertEq(IStakePool(pool).getStaker(), bob, "Staker should be bob");
        assertEq(IStakePool(pool).getOperator(), charlie, "Operator should be charlie");
        assertEq(IStakePool(pool).getVoter(), alice, "Voter should be alice");
        assertEq(IStakePool(pool).getLockedUntil(), lockedUntil, "LockedUntil should match");
    }

    function test_createPool_setsInitialActiveStake() public {
        uint256 initialStake = 10 ether;
        vm.prank(alice);
        address pool = _createPool(alice, initialStake);

        assertEq(IStakePool(pool).getActiveStake(), initialStake, "ActiveStake should match initial value");
    }

    function test_createPool_emitsPoolCreatedEvent() public {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        vm.prank(alice);
        vm.expectEmit(true, false, true, false);
        emit IStaking.PoolCreated(alice, address(0), alice, bob, 0);
        staking.createPool{ value: MIN_STAKE }(alice, bob, alice, alice, lockedUntil);
    }

    function test_createPool_incrementsNonce() public {
        assertEq(staking.getPoolNonce(), 0, "Initial nonce should be 0");

        vm.prank(alice);
        _createPool(alice, MIN_STAKE);
        assertEq(staking.getPoolNonce(), 1, "Nonce should be 1");

        vm.prank(bob);
        _createPool(bob, MIN_STAKE);
        assertEq(staking.getPoolNonce(), 2, "Nonce should be 2");
    }

    function test_createPool_allowsMultiplePoolsPerOwner() public {
        vm.startPrank(alice);
        address pool1 = _createPool(alice, MIN_STAKE);
        address pool2 = _createPool(alice, MIN_STAKE);
        address pool3 = _createPool(alice, MIN_STAKE);
        vm.stopPrank();

        assertNotEq(pool1, pool2, "Pools should have different addresses");
        assertNotEq(pool2, pool3, "Pools should have different addresses");
        assertEq(staking.getPoolCount(), 3, "Pool count should be 3");
    }

    function test_createPool_anyoneCanCreate() public {
        vm.prank(alice);
        address pool1 = _createPool(alice, MIN_STAKE);

        vm.prank(bob);
        address pool2 = _createPool(alice, MIN_STAKE);

        assertEq(Ownable(pool1).owner(), alice);
        assertEq(Ownable(pool2).owner(), alice);
        assertEq(staking.getPoolCount(), 2);
    }

    function test_RevertWhen_createPool_insufficientStake() public {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientStakeForPoolCreation.selector, 0.5 ether, MIN_STAKE));
        staking.createPool{ value: 0.5 ether }(alice, alice, alice, alice, lockedUntil);
    }

    function test_RevertWhen_createPool_invalidLockedUntil() public {
        uint64 invalidLockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION / 2; // Too short
        uint64 minRequired = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LockupDurationTooShort.selector, invalidLockedUntil, minRequired));
        staking.createPool{ value: MIN_STAKE }(alice, alice, alice, alice, invalidLockedUntil);
    }

    function test_getPool_revertsOnInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolIndexOutOfBounds.selector, 0, 0));
        staking.getPool(0);
    }

    function test_getAllPools_returnsAllPools() public {
        vm.prank(alice);
        address pool1 = _createPool(alice, MIN_STAKE);
        vm.prank(bob);
        address pool2 = _createPool(bob, MIN_STAKE);

        address[] memory allPools = staking.getAllPools();
        assertEq(allPools.length, 2);
        assertEq(allPools[0], pool1);
        assertEq(allPools[1], pool2);
    }

    function test_getMinimumStake_returnsConfigValue() public view {
        assertEq(staking.getMinimumStake(), MIN_STAKE);
    }

    // ========================================================================
    // STAKING FACTORY - Pool Validation & Status Queries
    // ========================================================================

    function test_isPool_returnsTrueForValidPool() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        assertTrue(staking.isPool(pool), "Should return true for valid pool");
    }

    function test_isPool_returnsFalseForInvalidPool() public view {
        assertFalse(staking.isPool(alice), "Should return false for non-pool address");
        assertFalse(staking.isPool(address(0)), "Should return false for zero address");
        assertFalse(staking.isPool(address(staking)), "Should return false for staking contract");
    }

    function test_getPoolVotingPower_returnsCorrectValue() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        address pool = _createPool(alice, stakeAmount);

        uint64 now_ = timestamp.microseconds();
        assertEq(staking.getPoolVotingPower(pool, now_), stakeAmount, "Should return voting power via factory");
        assertEq(
            staking.getPoolVotingPowerNow(pool), stakeAmount, "Should return voting power via convenience function"
        );
    }

    function test_getPoolVotingPower_returnsZeroWhenUnlocked() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);

        uint64 now_ = timestamp.microseconds();
        // When lockup expires, voting power is 0 (activeStake is not effective)
        assertEq(staking.getPoolVotingPower(pool, now_), 0, "Voting power is 0 when unlocked");
    }

    function test_RevertWhen_getPoolVotingPower_invalidPool() public {
        uint64 now_ = timestamp.microseconds();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolVotingPower(alice, now_);
    }

    function test_getPoolStaker_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        assertEq(staking.getPoolStaker(pool), bob, "Should return staker via factory");
    }

    function test_RevertWhen_getPoolStaker_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolStaker(alice);
    }

    function test_getPoolActiveStake_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        assertEq(staking.getPoolActiveStake(pool), 10 ether, "Should return active stake via factory");
    }

    function test_getPoolTotalPending_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        assertEq(staking.getPoolTotalPending(pool), 0, "Should return 0 initially");

        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        assertEq(staking.getPoolTotalPending(pool), 3 ether, "Should return pending amount");
    }

    // ========================================================================
    // STAKE POOL TESTS - Staker Role (addStake)
    // ========================================================================

    function test_addStake_increasesActiveStake() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint256 additionalStake = 5 ether;
        vm.prank(alice);
        IStakePool(pool).addStake{ value: additionalStake }();

        assertEq(IStakePool(pool).getActiveStake(), MIN_STAKE + additionalStake);
    }

    function test_addStake_extendsLockupIfNeeded() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint64 initialLockedUntil = IStakePool(pool).getLockedUntil();

        // Advance time by half the lockup
        _advanceTime(LOCKUP_DURATION / 2);

        vm.prank(alice);
        IStakePool(pool).addStake{ value: 1 ether }();

        uint64 newLockedUntil = IStakePool(pool).getLockedUntil();
        assertGt(newLockedUntil, initialLockedUntil, "Lockup should be extended");
    }

    function test_addStake_emitsStakeAddedEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.StakeAdded(pool, 5 ether);
        IStakePool(pool).addStake{ value: 5 ether }();
    }

    function test_RevertWhen_addStake_zeroAmount() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        IStakePool(pool).addStake{ value: 0 }();
    }

    function test_RevertWhen_addStake_notStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, charlie, bob));
        IStakePool(pool).addStake{ value: 1 ether }();
    }

    function test_addStake_worksWithDifferentStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        // Bob (staker) can add stake
        vm.prank(bob);
        IStakePool(pool).addStake{ value: 1 ether }();

        assertEq(IStakePool(pool).getActiveStake(), MIN_STAKE + 1 ether);
    }

    // ========================================================================
    // STAKE POOL TESTS - Voting Power
    // ========================================================================

    function test_getVotingPower_returnsActiveStakeWhenLocked() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        address pool = _createPool(alice, stakeAmount);

        uint64 now_ = timestamp.microseconds();
        assertEq(IStakePool(pool).getVotingPower(now_), stakeAmount);
        assertEq(IStakePool(pool).getVotingPowerNow(), stakeAmount);
    }

    function test_getVotingPower_returnsZeroWhenUnlocked() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);

        uint64 now_ = timestamp.microseconds();
        // When lockup expires, voting power is 0 (activeStake is not effective)
        assertEq(IStakePool(pool).getVotingPower(now_), 0, "Voting power is 0 when unlocked");
        assertEq(IStakePool(pool).getVotingPowerNow(), 0, "Voting power is 0 when unlocked");
    }

    function test_isLocked_returnsTrueWhenLocked() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        assertTrue(IStakePool(pool).isLocked());
    }

    function test_isLocked_returnsFalseWhenUnlocked() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);

        assertFalse(IStakePool(pool).isLocked());
    }

    // ========================================================================
    // STAKE POOL TESTS - Unstake (O(log n) bucket model)
    // ========================================================================

    function test_unstake_movesToPendingBucket() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        IStakePool(pool).unstake(5 ether);

        assertEq(IStakePool(pool).getActiveStake(), 5 ether, "Active stake should be reduced");
        assertEq(IStakePool(pool).getTotalPending(), 5 ether, "Pending should be 5 ether");
        assertEq(IStakePool(pool).getPendingBucketCount(), 1, "Should have 1 bucket");
    }

    function test_unstake_emitsUnstakedEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        uint64 lockedUntil = IStakePool(pool).getLockedUntil();

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.Unstaked(pool, 5 ether, lockedUntil);
        IStakePool(pool).unstake(5 ether);
    }

    function test_unstake_mergesIntoBucketWithSameLockedUntil() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.startPrank(alice);
        IStakePool(pool).unstake(2 ether);
        IStakePool(pool).unstake(3 ether);
        vm.stopPrank();

        // Both unstakes have the same lockedUntil, so should merge into 1 bucket
        assertEq(IStakePool(pool).getPendingBucketCount(), 1, "Should merge into 1 bucket");
        assertEq(IStakePool(pool).getTotalPending(), 5 ether, "Total pending should be 5 ether");

        IStakePool.PendingBucket memory bucket = IStakePool(pool).getPendingBucket(0);
        assertEq(bucket.cumulativeAmount, 5 ether, "Bucket cumulative should be 5 ether");
    }

    function test_unstake_createsNewBucketWhenLockedUntilDifferent() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // First unstake
        vm.prank(alice);
        IStakePool(pool).unstake(2 ether);

        // Extend lockup to create different lockedUntil
        vm.prank(alice);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);

        // Second unstake with new lockedUntil
        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        assertEq(IStakePool(pool).getPendingBucketCount(), 2, "Should have 2 buckets");
        assertEq(IStakePool(pool).getTotalPending(), 5 ether, "Total pending should be 5 ether");

        // Check prefix sum
        IStakePool.PendingBucket memory bucket0 = IStakePool(pool).getPendingBucket(0);
        IStakePool.PendingBucket memory bucket1 = IStakePool(pool).getPendingBucket(1);
        assertEq(bucket0.cumulativeAmount, 2 ether, "First bucket cumulative should be 2 ether");
        assertEq(bucket1.cumulativeAmount, 5 ether, "Second bucket cumulative should be 5 ether (prefix sum)");
    }

    function test_RevertWhen_unstake_zeroAmount() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        IStakePool(pool).unstake(0);
    }

    function test_RevertWhen_unstake_notStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, charlie, bob));
        IStakePool(pool).unstake(MIN_STAKE);
    }

    function test_RevertWhen_unstake_insufficientActiveStake() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientAvailableStake.selector, 11 ether, 10 ether));
        IStakePool(pool).unstake(11 ether);
    }

    // ========================================================================
    // STAKE POOL TESTS - withdrawAvailable (O(log n) claim pointer model)
    // ========================================================================

    function test_withdrawAvailable_withdrawsClaimablePending() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        IStakePool(pool).unstake(5 ether);

        // Advance past lockup + unbonding delay
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        uint256 balanceBefore = bob.balance;
        vm.prank(alice);
        uint256 claimed = IStakePool(pool).withdrawAvailable(bob);

        assertEq(claimed, 5 ether, "Should claim 5 ether");
        assertEq(bob.balance, balanceBefore + 5 ether, "Bob should receive funds");
        assertEq(IStakePool(pool).getClaimedAmount(), 5 ether, "Claimed amount should be 5 ether");
    }

    function test_withdrawAvailable_emitsWithdrawalClaimedEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        IStakePool(pool).unstake(5 ether);

        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IStakePool.WithdrawalClaimed(pool, 5 ether, bob);
        IStakePool(pool).withdrawAvailable(bob);
    }

    function test_withdrawAvailable_returnsZeroWhenNothingClaimable() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        IStakePool(pool).unstake(5 ether);

        // Don't advance time - nothing is claimable yet
        vm.prank(alice);
        uint256 claimed = IStakePool(pool).withdrawAvailable(bob);

        assertEq(claimed, 0, "Should return 0 when nothing claimable");
    }

    function test_withdrawAvailable_notClaimableAtExactBoundary() public {
        // Tests that stake is NOT claimable when now == lockedUntil + unbondingDelay (strict inequality)
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        IStakePool(pool).unstake(5 ether);

        // Advance to exactly lockedUntil + unbondingDelay
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY);

        // At exact boundary, should NOT be claimable (spec requires now > lockedUntil + unbondingDelay)
        assertEq(IStakePool(pool).getClaimableAmount(), 0, "Should not be claimable at exact boundary");
        vm.prank(alice);
        uint256 claimed = IStakePool(pool).withdrawAvailable(bob);
        assertEq(claimed, 0, "Should return 0 at exact boundary");

        // Advance 1 more microsecond
        _advanceTime(1);

        // Now should be claimable (now > lockedUntil + unbondingDelay)
        assertEq(IStakePool(pool).getClaimableAmount(), 5 ether, "Should be claimable 1 microsecond after boundary");
        vm.prank(alice);
        claimed = IStakePool(pool).withdrawAvailable(bob);
        assertEq(claimed, 5 ether, "Should claim 5 ether 1 microsecond after boundary");
    }

    function test_withdrawAvailable_partialClaim_withMultipleBuckets() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // First unstake
        vm.prank(alice);
        IStakePool(pool).unstake(2 ether);
        uint64 firstLockedUntil = IStakePool(pool).getLockedUntil();

        // Extend lockup
        vm.prank(alice);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);

        // Second unstake with new lockedUntil
        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        // Advance only enough to claim first bucket
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Only first bucket should be claimable
        vm.prank(alice);
        uint256 claimed = IStakePool(pool).withdrawAvailable(bob);

        assertEq(claimed, 2 ether, "Should only claim first bucket");
        assertEq(IStakePool(pool).getTotalPending(), 3 ether, "Second bucket still pending");
    }

    function test_RevertWhen_withdrawAvailable_notStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, charlie, bob));
        IStakePool(pool).withdrawAvailable(charlie);
    }

    // ========================================================================
    // STAKE POOL TESTS - unstakeAndWithdraw (helper combining unstake + withdrawAvailable)
    // ========================================================================

    function test_unstakeAndWithdraw_unstakesAndWithdrawsClaimable() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // First unstake some amount
        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        // Advance past lockup + unbonding delay to make it claimable
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Note: lockedUntil hasn't changed, so any new unstake will merge into the same bucket
        // unstakeAndWithdraw will: 1) unstake 2 ether (merged with first bucket), 2) withdraw all claimable
        // Since both have the same lockedUntil, total claimable = 3 + 2 = 5 ether
        uint256 balanceBefore = bob.balance;
        vm.prank(alice);
        uint256 withdrawn = IStakePool(pool).unstakeAndWithdraw(2 ether, bob);

        // Both the 3 ether and the newly unstaked 2 ether are claimable (same lockedUntil)
        assertEq(withdrawn, 5 ether, "Should withdraw 5 ether (both buckets merged)");
        assertEq(bob.balance, balanceBefore + 5 ether, "Bob should receive 5 ether");

        // Active stake should be reduced by the 2 ether unstaked
        // Original: 10 ether, first unstake: 3 ether -> 7 ether, second unstake: 2 ether -> 5 ether
        assertEq(IStakePool(pool).getActiveStake(), 5 ether, "Active stake should be 5 ether");

        // Only 1 bucket since they merged (same lockedUntil)
        assertEq(IStakePool(pool).getPendingBucketCount(), 1, "Should have 1 pending bucket (merged)");
    }

    function test_unstakeAndWithdraw_returnsZeroWhenNothingClaimable() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // Use unstakeAndWithdraw without any previous pending
        uint256 balanceBefore = bob.balance;
        vm.prank(alice);
        uint256 withdrawn = IStakePool(pool).unstakeAndWithdraw(3 ether, bob);

        // Nothing claimable yet (just created pending)
        assertEq(withdrawn, 0, "Should return 0 when nothing claimable");
        assertEq(bob.balance, balanceBefore, "Bob should receive nothing");
        assertEq(IStakePool(pool).getActiveStake(), 7 ether, "Active stake should be 7 ether");
        assertEq(IStakePool(pool).getTotalPending(), 3 ether, "Should have 3 ether pending");
    }

    function test_unstakeAndWithdraw_emitsUnstakedAndWithdrawalClaimedEvents() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // First unstake
        vm.prank(alice);
        IStakePool(pool).unstake(2 ether);

        // Advance past lockup + unbonding
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Get lockedUntil before the call (it doesn't change)
        uint64 currentLockedUntil = IStakePool(pool).getLockedUntil();

        // Expect both Unstaked and WithdrawalClaimed events
        // Note: since lockedUntil hasn't changed, the new unstake merges with the previous bucket
        // So total claimable = 2 + 3 = 5 ether
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.Unstaked(pool, 3 ether, currentLockedUntil);
        vm.expectEmit(true, true, false, true);
        emit IStakePool.WithdrawalClaimed(pool, 5 ether, bob);
        IStakePool(pool).unstakeAndWithdraw(3 ether, bob);
    }

    function test_RevertWhen_unstakeAndWithdraw_zeroAmount() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        IStakePool(pool).unstakeAndWithdraw(0, alice);
    }

    function test_RevertWhen_unstakeAndWithdraw_notStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, charlie, bob));
        IStakePool(pool).unstakeAndWithdraw(MIN_STAKE, charlie);
    }

    function test_RevertWhen_unstakeAndWithdraw_insufficientActiveStake() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientAvailableStake.selector, 11 ether, 10 ether));
        IStakePool(pool).unstakeAndWithdraw(11 ether, alice);
    }

    // ========================================================================
    // STAKE POOL TESTS - Voting Power with Pending (O(log n) binary search)
    // ========================================================================

    function test_getVotingPower_excludesIneffectivePending() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // Unstake 3 ether
        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        // Right now, lockedUntil is in the future, so pending is still effective
        uint64 now_ = timestamp.microseconds();
        // Voting power = activeStake + effective pending = 7 + 3 = 10
        assertEq(IStakePool(pool).getVotingPower(now_), 10 ether, "All stake should be effective when locked");

        // Advance to just past lockedUntil - both activeStake and pending become ineffective
        _advanceTime(LOCKUP_DURATION + 1);

        // Both activeStake and pending with lockedUntil <= now are ineffective, so voting power = 0
        assertEq(IStakePool(pool).getVotingPowerNow(), 0, "Voting power is 0 when lockup expired");
    }

    function test_getEffectiveStake_excludesIneffectivePending() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // Unstake 3 ether
        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        uint64 now_ = timestamp.microseconds();

        // Effective stake includes pending that's still locked
        assertEq(IStakePool(pool).getEffectiveStake(now_), 10 ether, "All stake effective when pending still locked");

        // Check at a future time when pending and lockup would be unlocked
        uint64 futureTime = IStakePool(pool).getLockedUntil() + 1;
        // At futureTime, both activeStake and pending become ineffective (lockup expired)
        assertEq(IStakePool(pool).getEffectiveStake(futureTime), 0, "No stake effective when lockup expired");
    }

    function test_getClaimableAmount_returnsCorrectAmount() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        vm.prank(alice);
        IStakePool(pool).unstake(5 ether);

        // Not claimable yet
        assertEq(IStakePool(pool).getClaimableAmount(), 0, "Nothing claimable initially");

        // Advance past lockup + unbonding
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        assertEq(IStakePool(pool).getClaimableAmount(), 5 ether, "5 ether should be claimable");
    }

    // ========================================================================
    // STAKE POOL TESTS - Lockup Management (renewLockUntil - Staker Only)
    // ========================================================================

    function test_renewLockUntil_extendsLockup() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint64 oldLockedUntil = IStakePool(pool).getLockedUntil();
        uint64 extension = LOCKUP_DURATION;

        vm.prank(alice);
        IStakePool(pool).renewLockUntil(extension);

        uint64 newLockedUntil = IStakePool(pool).getLockedUntil();
        assertEq(newLockedUntil, oldLockedUntil + extension);
    }

    function test_renewLockUntil_emitsLockupRenewedEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint64 oldLockedUntil = IStakePool(pool).getLockedUntil();
        uint64 extension = LOCKUP_DURATION;

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.LockupRenewed(pool, oldLockedUntil, oldLockedUntil + extension);
        IStakePool(pool).renewLockUntil(extension);
    }

    function test_renewLockUntil_extendsLockupPeriod() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint64 oldLockedUntil = IStakePool(pool).getLockedUntil();
        _advanceTime(LOCKUP_DURATION + 1);

        // When lockup expired, voting power is 0
        assertEq(IStakePool(pool).getVotingPowerNow(), 0, "Voting power is 0 when unlocked");

        vm.prank(alice);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION * 2); // Need enough to be >= now + minLockup

        uint64 newLockedUntil = IStakePool(pool).getLockedUntil();
        assertGt(newLockedUntil, oldLockedUntil, "Lockup should be extended");
        // After renewal, voting power is restored
        assertEq(IStakePool(pool).getVotingPowerNow(), MIN_STAKE, "Voting power restored after renewal");
    }

    function test_renewLockUntil_allowsSmallExtensionWhenFarInFuture() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint64 smallExtension = 1 days * 1_000_000;

        vm.prank(alice);
        IStakePool(pool).renewLockUntil(smallExtension);

        uint64 newLockedUntil = IStakePool(pool).getLockedUntil();
        assertEq(newLockedUntil, INITIAL_TIMESTAMP + LOCKUP_DURATION + smallExtension);
    }

    function test_RevertWhen_renewLockUntil_resultTooShort() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION - 1 days * 1_000_000);

        uint64 tinyExtension = 1;

        vm.prank(alice);
        vm.expectRevert();
        IStakePool(pool).renewLockUntil(tinyExtension);
    }

    function test_RevertWhen_renewLockUntil_overflow() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectRevert();
        IStakePool(pool).renewLockUntil(type(uint64).max);
    }

    function test_RevertWhen_renewLockUntil_notStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, charlie, bob));
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);
    }

    // ========================================================================
    // STAKE POOL TESTS - Owner Functions (Role Management)
    // ========================================================================

    function test_setOperator_changesOperator() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        IStakePool(pool).setOperator(bob);

        assertEq(IStakePool(pool).getOperator(), bob);
    }

    function test_setOperator_emitsOperatorChangedEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.OperatorChanged(pool, alice, bob);
        IStakePool(pool).setOperator(bob);
    }

    function test_RevertWhen_setOperator_notOwner() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        IStakePool(pool).setOperator(charlie);
    }

    function test_setVoter_changesVoter() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        IStakePool(pool).setVoter(bob);

        assertEq(IStakePool(pool).getVoter(), bob);
    }

    function test_setVoter_emitsVoterChangedEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.VoterChanged(pool, alice, bob);
        IStakePool(pool).setVoter(bob);
    }

    function test_RevertWhen_setVoter_notOwner() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        IStakePool(pool).setVoter(charlie);
    }

    function test_setStaker_changesStaker() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        IStakePool(pool).setStaker(bob);

        assertEq(IStakePool(pool).getStaker(), bob);
    }

    function test_setStaker_emitsStakerChangedEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.StakerChanged(pool, alice, bob);
        IStakePool(pool).setStaker(bob);
    }

    function test_RevertWhen_setStaker_notOwner() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        IStakePool(pool).setStaker(charlie);
    }

    // ========================================================================
    // STAKE POOL TESTS - Ownable2Step
    // ========================================================================

    function test_transferOwnership_setsPendingOwner() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        Ownable2Step(pool).transferOwnership(bob);

        assertEq(Ownable2Step(pool).pendingOwner(), bob);
        assertEq(Ownable(pool).owner(), alice);
    }

    function test_acceptOwnership_completesTransfer() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        Ownable2Step(pool).transferOwnership(bob);

        vm.prank(bob);
        Ownable2Step(pool).acceptOwnership();

        assertEq(Ownable(pool).owner(), bob);
        assertEq(Ownable2Step(pool).pendingOwner(), address(0));
    }

    function test_RevertWhen_acceptOwnership_notPendingOwner() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        Ownable2Step(pool).transferOwnership(bob);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, charlie));
        Ownable2Step(pool).acceptOwnership();
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_createPool_variousAmounts(
        uint96 amount
    ) public {
        amount = uint96(bound(amount, MIN_STAKE, 1000 ether));

        vm.prank(alice);
        address pool = _createPool(alice, amount);

        assertEq(IStakePool(pool).getActiveStake(), amount);
        assertEq(IStakePool(pool).getVotingPowerNow(), amount);
    }

    function testFuzz_addStake_variousAmounts(
        uint96 initialStake,
        uint96 additionalStake
    ) public {
        initialStake = uint96(bound(initialStake, MIN_STAKE, 500 ether));
        additionalStake = uint96(bound(additionalStake, 1, 500 ether));

        vm.prank(alice);
        address pool = _createPool(alice, initialStake);

        vm.prank(alice);
        IStakePool(pool).addStake{ value: additionalStake }();

        assertEq(IStakePool(pool).getActiveStake(), uint256(initialStake) + uint256(additionalStake));
    }

    function testFuzz_unstake_variousAmounts(
        uint96 stakeAmount,
        uint96 unstakeAmount
    ) public {
        stakeAmount = uint96(bound(stakeAmount, MIN_STAKE, 1000 ether));
        unstakeAmount = uint96(bound(unstakeAmount, 1, stakeAmount));

        vm.prank(alice);
        address pool = _createPool(alice, stakeAmount);

        vm.prank(alice);
        IStakePool(pool).unstake(unstakeAmount);

        assertEq(IStakePool(pool).getActiveStake(), stakeAmount - unstakeAmount);
        assertEq(IStakePool(pool).getTotalPending(), unstakeAmount);
    }

    function testFuzz_withdrawAvailable_afterUnbonding(
        uint96 stakeAmount,
        uint96 unstakeAmount
    ) public {
        stakeAmount = uint96(bound(stakeAmount, MIN_STAKE, 1000 ether));
        unstakeAmount = uint96(bound(unstakeAmount, 1, stakeAmount));

        vm.prank(alice);
        address pool = _createPool(alice, stakeAmount);

        vm.prank(alice);
        IStakePool(pool).unstake(unstakeAmount);

        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        uint256 claimed = IStakePool(pool).withdrawAvailable(alice);

        assertEq(claimed, unstakeAmount);
        assertEq(alice.balance, balanceBefore + unstakeAmount);
    }

    function testFuzz_multiplePools_concurrentOperations(
        uint8 numPools
    ) public {
        numPools = uint8(bound(numPools, 1, 10));

        address[] memory pools = new address[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            vm.prank(alice);
            pools[i] = _createPool(alice, MIN_STAKE);
        }

        assertEq(staking.getPoolCount(), numPools);

        for (uint256 i = 0; i < numPools; i++) {
            assertEq(IStakePool(pools[i]).getActiveStake(), MIN_STAKE);
            assertEq(Ownable(pools[i]).owner(), alice);
        }
    }

    // ========================================================================
    // INVARIANT TESTS
    // ========================================================================

    function test_invariant_votingPowerMatchesEffectiveStake() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // When locked: votingPower == activeStake + effective pending
        assertTrue(IStakePool(pool).isLocked());
        assertEq(IStakePool(pool).getVotingPowerNow(), IStakePool(pool).getActiveStake());

        // When unlocked: votingPower is 0 (activeStake is not effective when lockup expired)
        _advanceTime(LOCKUP_DURATION + 1);
        assertFalse(IStakePool(pool).isLocked());
        assertEq(IStakePool(pool).getVotingPowerNow(), 0, "Voting power is 0 when unlocked");
    }

    function test_invariant_lockupNeverDecreases() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint64 lockedUntil1 = IStakePool(pool).getLockedUntil();

        // addStake should only increase or maintain lockup
        _advanceTime(LOCKUP_DURATION / 4);
        vm.prank(alice);
        IStakePool(pool).addStake{ value: 1 ether }();
        uint64 lockedUntil2 = IStakePool(pool).getLockedUntil();
        assertGe(lockedUntil2, lockedUntil1, "Lockup should not decrease");

        // renewLockUntil should always increase
        vm.prank(alice);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);
        uint64 lockedUntil3 = IStakePool(pool).getLockedUntil();
        assertGt(lockedUntil3, lockedUntil2, "Lockup should increase");
    }

    function test_invariant_prefixSumMonotonic() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // Create multiple buckets with different lockedUntil
        vm.prank(alice);
        IStakePool(pool).unstake(1 ether);

        vm.prank(alice);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);

        vm.prank(alice);
        IStakePool(pool).unstake(2 ether);

        vm.prank(alice);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);

        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        // Verify prefix sums are monotonic
        uint256 prevCumulative = 0;
        uint64 prevLockedUntil = 0;
        for (uint256 i = 0; i < IStakePool(pool).getPendingBucketCount(); i++) {
            IStakePool.PendingBucket memory bucket = IStakePool(pool).getPendingBucket(i);
            assertGt(bucket.lockedUntil, prevLockedUntil, "lockedUntil must be strictly increasing");
            assertGt(bucket.cumulativeAmount, prevCumulative, "cumulativeAmount must be strictly increasing");
            prevLockedUntil = bucket.lockedUntil;
            prevCumulative = bucket.cumulativeAmount;
        }
    }

    function test_invariant_balanceConservation() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        uint256 initialBalance = address(pool).balance;
        assertEq(initialBalance, 10 ether);

        // Unstake some
        vm.prank(alice);
        IStakePool(pool).unstake(3 ether);

        // Balance should be the same (tokens don't move)
        assertEq(address(pool).balance, 10 ether);
        assertEq(IStakePool(pool).getActiveStake() + IStakePool(pool).getTotalPending(), 10 ether);

        // Advance and withdraw
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        vm.prank(alice);
        IStakePool(pool).withdrawAvailable(alice);

        // Now balance is reduced
        assertEq(address(pool).balance, 7 ether);
        assertEq(IStakePool(pool).getActiveStake(), 7 ether);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _advanceTime(
        uint64 duration
    ) internal {
        uint64 currentTime = timestamp.microseconds();
        uint64 newTime = currentTime + duration;
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, newTime);
    }
}
