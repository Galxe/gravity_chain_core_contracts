// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Staking} from "../../../src/staking/Staking.sol";
import {IStaking} from "../../../src/staking/IStaking.sol";
import {IStakePool} from "../../../src/staking/IStakePool.sol";
import {IStakingHook} from "../../../src/staking/IStakingHook.sol";
import {StakingConfig} from "../../../src/runtime/StakingConfig.sol";
import {Timestamp} from "../../../src/runtime/Timestamp.sol";
import {SystemAddresses} from "../../../src/foundation/SystemAddresses.sol";
import {Errors} from "../../../src/foundation/Errors.sol";

/// @title MockStakingHook
/// @notice Mock hook contract for testing
contract MockStakingHook is IStakingHook {
    uint256 public lastAddedAmount;
    uint256 public lastWithdrawnAmount;
    uint64 public lastLockedUntil;
    uint256 public addedCount;
    uint256 public withdrawnCount;
    uint256 public lockupCount;

    function onStakeAdded(uint256 amount) external override {
        lastAddedAmount = amount;
        addedCount++;
    }

    function onStakeWithdrawn(uint256 amount) external override {
        lastWithdrawnAmount = amount;
        withdrawnCount++;
    }

    function onLockupIncreased(uint64 newLockedUntil) external override {
        lastLockedUntil = newLockedUntil;
        lockupCount++;
    }
}

/// @title StakingTest
/// @notice Unit tests for Staking factory and StakePool contracts
contract StakingTest is Test {
    Staking public staking;
    StakingConfig public stakingConfig;
    Timestamp public timestamp;

    // Test addresses
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    // Test constants
    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000; // 14 days in microseconds
    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000; // Initial time in microseconds

    function setUp() public {
        // Deploy contracts at system addresses
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        // Initialize StakingConfig
        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, 10 ether);

        // Set initial timestamp
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP);

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(charlie, 1000 ether);
    }

    // ========================================================================
    // STAKING FACTORY TESTS
    // ========================================================================

    function test_createPool_createsNewPool() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        assertNotEq(pool, address(0), "Pool should be created");
        assertEq(staking.getPoolCount(), 1, "Pool count should be 1");
        assertEq(staking.getPool(0), pool, "Pool at index 0 should match");
    }

    function test_createPool_setsCorrectOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(bob);

        assertEq(IStakePool(pool).getOwner(), bob, "Owner should be bob");
    }

    function test_createPool_setsInitialStake() public {
        uint256 initialStake = 10 ether;
        vm.prank(alice);
        address pool = staking.createPool{value: initialStake}(alice);

        assertEq(IStakePool(pool).getStake(), initialStake, "Stake should match initial value");
    }

    function test_createPool_setsInitialLockup() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 expectedLockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;
        assertEq(IStakePool(pool).getLockedUntil(), expectedLockedUntil, "Lockup should be set");
    }

    function test_createPool_emitsPoolCreatedEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, true, true);
        // We don't know the exact pool address before creation, so we just check the event is emitted
        emit IStaking.PoolCreated(alice, address(0), alice, 0);
        staking.createPool{value: MIN_STAKE}(alice);
    }

    function test_createPool_incrementsNonce() public {
        assertEq(staking.getPoolNonce(), 0, "Initial nonce should be 0");

        vm.prank(alice);
        staking.createPool{value: MIN_STAKE}(alice);
        assertEq(staking.getPoolNonce(), 1, "Nonce should be 1");

        vm.prank(bob);
        staking.createPool{value: MIN_STAKE}(bob);
        assertEq(staking.getPoolNonce(), 2, "Nonce should be 2");
    }

    function test_createPool_allowsMultiplePoolsPerOwner() public {
        vm.startPrank(alice);
        address pool1 = staking.createPool{value: MIN_STAKE}(alice);
        address pool2 = staking.createPool{value: MIN_STAKE}(alice);
        address pool3 = staking.createPool{value: MIN_STAKE}(alice);
        vm.stopPrank();

        assertNotEq(pool1, pool2, "Pools should have different addresses");
        assertNotEq(pool2, pool3, "Pools should have different addresses");
        assertEq(staking.getPoolCount(), 3, "Pool count should be 3");
    }

    function test_createPool_anyoneCanCreate() public {
        // Alice creates pool for herself
        vm.prank(alice);
        address pool1 = staking.createPool{value: MIN_STAKE}(alice);

        // Bob creates pool for Alice
        vm.prank(bob);
        address pool2 = staking.createPool{value: MIN_STAKE}(alice);

        assertEq(IStakePool(pool1).getOwner(), alice);
        assertEq(IStakePool(pool2).getOwner(), alice);
        assertEq(staking.getPoolCount(), 2);
    }

    function test_RevertWhen_createPool_insufficientStake() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientStakeForPoolCreation.selector, 0.5 ether, MIN_STAKE));
        staking.createPool{value: 0.5 ether}(alice);
    }

    function test_RevertWhen_createPool_zeroStake() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientStakeForPoolCreation.selector, 0, MIN_STAKE));
        staking.createPool{value: 0}(alice);
    }

    function test_getPool_revertsOnInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolIndexOutOfBounds.selector, 0, 0));
        staking.getPool(0);
    }

    function test_getAllPools_returnsAllPools() public {
        vm.prank(alice);
        address pool1 = staking.createPool{value: MIN_STAKE}(alice);
        vm.prank(bob);
        address pool2 = staking.createPool{value: MIN_STAKE}(bob);

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
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        assertTrue(staking.isPool(pool), "Should return true for valid pool");
    }

    function test_isPool_returnsFalseForInvalidPool() public view {
        assertFalse(staking.isPool(alice), "Should return false for non-pool address");
        assertFalse(staking.isPool(address(0)), "Should return false for zero address");
        assertFalse(staking.isPool(address(staking)), "Should return false for staking contract");
    }

    function test_isPool_returnsFalseForArbitraryContract() public {
        // Deploy a random contract (MockStakingHook) and check it's not a valid pool
        MockStakingHook randomContract = new MockStakingHook();
        assertFalse(staking.isPool(address(randomContract)), "Should return false for arbitrary contract");
    }

    function test_getPoolVotingPower_returnsCorrectValue() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        address pool = staking.createPool{value: stakeAmount}(alice);

        assertEq(staking.getPoolVotingPower(pool), stakeAmount, "Should return voting power via factory");
    }

    function test_getPoolVotingPower_returnsZeroWhenUnlocked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        assertEq(staking.getPoolVotingPower(pool), 0, "Should return 0 when unlocked");
    }

    function test_RevertWhen_getPoolVotingPower_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolVotingPower(alice);
    }

    function test_getPoolStake_returnsCorrectValue() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        address pool = staking.createPool{value: stakeAmount}(alice);

        assertEq(staking.getPoolStake(pool), stakeAmount, "Should return stake via factory");
    }

    function test_RevertWhen_getPoolStake_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolStake(alice);
    }

    function test_getPoolOwner_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(bob);

        assertEq(staking.getPoolOwner(pool), bob, "Should return owner via factory");
    }

    function test_RevertWhen_getPoolOwner_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolOwner(alice);
    }

    function test_getPoolVoter_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        // Change voter
        vm.prank(alice);
        IStakePool(pool).setVoter(bob);

        assertEq(staking.getPoolVoter(pool), bob, "Should return voter via factory");
    }

    function test_RevertWhen_getPoolVoter_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolVoter(alice);
    }

    function test_getPoolOperator_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        // Change operator
        vm.prank(alice);
        IStakePool(pool).setOperator(bob);

        assertEq(staking.getPoolOperator(pool), bob, "Should return operator via factory");
    }

    function test_RevertWhen_getPoolOperator_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolOperator(alice);
    }

    function test_getPoolLockedUntil_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 expectedLockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;
        assertEq(staking.getPoolLockedUntil(pool), expectedLockedUntil, "Should return lockedUntil via factory");
    }

    function test_RevertWhen_getPoolLockedUntil_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolLockedUntil(alice);
    }

    function test_isPoolLocked_returnsTrueWhenLocked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        assertTrue(staking.isPoolLocked(pool), "Should return true when locked via factory");
    }

    function test_isPoolLocked_returnsFalseWhenUnlocked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        assertFalse(staking.isPoolLocked(pool), "Should return false when unlocked via factory");
    }

    function test_RevertWhen_isPoolLocked_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.isPoolLocked(alice);
    }

    // ========================================================================
    // STAKE POOL TESTS - Basic Operations
    // ========================================================================

    function test_addStake_increasesStake() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint256 additionalStake = 5 ether;
        vm.prank(alice);
        IStakePool(pool).addStake{value: additionalStake}();

        assertEq(IStakePool(pool).getStake(), MIN_STAKE + additionalStake);
    }

    function test_addStake_extendsLockupIfNeeded() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 initialLockedUntil = IStakePool(pool).getLockedUntil();

        // Advance time by half the lockup
        _advanceTime(LOCKUP_DURATION / 2);

        vm.prank(alice);
        IStakePool(pool).addStake{value: 1 ether}();

        // Lockup should be extended from now
        uint64 newLockedUntil = IStakePool(pool).getLockedUntil();
        assertGt(newLockedUntil, initialLockedUntil, "Lockup should be extended");
    }

    function test_addStake_emitsStakeAddedEvent() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.StakeAdded(pool, 5 ether);
        IStakePool(pool).addStake{value: 5 ether}();
    }

    function test_RevertWhen_addStake_zeroAmount() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        IStakePool(pool).addStake{value: 0}();
    }

    function test_RevertWhen_addStake_notOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOwner.selector, bob, alice));
        IStakePool(pool).addStake{value: 1 ether}();
    }

    // ========================================================================
    // STAKE POOL TESTS - Voting Power
    // ========================================================================

    function test_getVotingPower_returnsStakeWhenLocked() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        address pool = staking.createPool{value: stakeAmount}(alice);

        assertEq(IStakePool(pool).getVotingPower(), stakeAmount);
    }

    function test_getVotingPower_returnsZeroWhenUnlocked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        // Advance time past lockup
        _advanceTime(LOCKUP_DURATION + 1);

        assertEq(IStakePool(pool).getVotingPower(), 0, "Voting power should be 0 when unlocked");
    }

    function test_isLocked_returnsTrueWhenLocked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        assertTrue(IStakePool(pool).isLocked());
    }

    function test_isLocked_returnsFalseWhenUnlocked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        assertFalse(IStakePool(pool).isLocked());
    }

    function test_getRemainingLockup_returnsCorrectValue() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 remaining = IStakePool(pool).getRemainingLockup();
        assertEq(remaining, LOCKUP_DURATION);

        _advanceTime(LOCKUP_DURATION / 2);

        remaining = IStakePool(pool).getRemainingLockup();
        assertEq(remaining, LOCKUP_DURATION / 2);
    }

    function test_getRemainingLockup_returnsZeroWhenExpired() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        assertEq(IStakePool(pool).getRemainingLockup(), 0);
    }

    // ========================================================================
    // STAKE POOL TESTS - Withdraw
    // ========================================================================

    function test_withdraw_withdrawsStake() public {
        vm.prank(alice);
        address pool = staking.createPool{value: 10 ether}(alice);

        // Advance time past lockup
        _advanceTime(LOCKUP_DURATION + 1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool).withdraw(5 ether);

        assertEq(IStakePool(pool).getStake(), 5 ether);
        assertEq(alice.balance, balanceBefore + 5 ether);
    }

    function test_withdraw_emitsStakeWithdrawnEvent() public {
        vm.prank(alice);
        address pool = staking.createPool{value: 10 ether}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.StakeWithdrawn(pool, 5 ether);
        IStakePool(pool).withdraw(5 ether);
    }

    function test_RevertWhen_withdraw_locked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 lockedUntil = IStakePool(pool).getLockedUntil();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LockupNotExpired.selector, lockedUntil, INITIAL_TIMESTAMP));
        IStakePool(pool).withdraw(MIN_STAKE);
    }

    function test_RevertWhen_withdraw_zeroAmount() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        IStakePool(pool).withdraw(0);
    }

    function test_RevertWhen_withdraw_insufficientStake() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientStake.selector, 100 ether, MIN_STAKE));
        IStakePool(pool).withdraw(100 ether);
    }

    function test_RevertWhen_withdraw_notOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOwner.selector, bob, alice));
        IStakePool(pool).withdraw(MIN_STAKE);
    }

    // ========================================================================
    // STAKE POOL TESTS - Lockup Management
    // ========================================================================

    function test_increaseLockup_extendsLockup() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 oldLockedUntil = IStakePool(pool).getLockedUntil();
        uint64 extension = LOCKUP_DURATION; // Extend by another full lockup duration

        vm.prank(alice);
        IStakePool(pool).increaseLockup(extension);

        uint64 newLockedUntil = IStakePool(pool).getLockedUntil();
        assertEq(newLockedUntil, oldLockedUntil + extension);
    }

    function test_increaseLockup_emitsLockupIncreasedEvent() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 oldLockedUntil = IStakePool(pool).getLockedUntil();
        uint64 extension = LOCKUP_DURATION;

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.LockupIncreased(pool, oldLockedUntil, oldLockedUntil + extension);
        IStakePool(pool).increaseLockup(extension);
    }

    function test_increaseLockup_restoresVotingPower() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        // Advance time past lockup
        _advanceTime(LOCKUP_DURATION + 1);
        assertEq(IStakePool(pool).getVotingPower(), 0, "Voting power should be 0 when unlocked");

        // Extend lockup
        vm.prank(alice);
        IStakePool(pool).increaseLockup(LOCKUP_DURATION);

        assertEq(IStakePool(pool).getVotingPower(), MIN_STAKE, "Voting power should be restored");
    }

    function test_RevertWhen_increaseLockup_durationTooShort() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 shortDuration = LOCKUP_DURATION / 2; // Less than minimum

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LockupDurationTooShort.selector, shortDuration, LOCKUP_DURATION));
        IStakePool(pool).increaseLockup(shortDuration);
    }

    function test_RevertWhen_increaseLockup_overflow() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        // Try to overflow by adding max uint64
        vm.prank(alice);
        vm.expectRevert(); // Will revert due to overflow
        IStakePool(pool).increaseLockup(type(uint64).max);
    }

    function test_RevertWhen_increaseLockup_notOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOwner.selector, bob, alice));
        IStakePool(pool).increaseLockup(LOCKUP_DURATION);
    }

    // ========================================================================
    // STAKE POOL TESTS - Role Separation
    // ========================================================================

    function test_defaultRoles_setToOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        assertEq(IStakePool(pool).getOwner(), alice);
        assertEq(IStakePool(pool).getOperator(), alice);
        assertEq(IStakePool(pool).getVoter(), alice);
    }

    function test_setOperator_changesOperator() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(alice);
        IStakePool(pool).setOperator(bob);

        assertEq(IStakePool(pool).getOperator(), bob);
    }

    function test_setOperator_emitsOperatorChangedEvent() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.OperatorChanged(pool, alice, bob);
        IStakePool(pool).setOperator(bob);
    }

    function test_RevertWhen_setOperator_notOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOwner.selector, bob, alice));
        IStakePool(pool).setOperator(charlie);
    }

    function test_setVoter_changesVoter() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(alice);
        IStakePool(pool).setVoter(bob);

        assertEq(IStakePool(pool).getVoter(), bob);
    }

    function test_setVoter_emitsVoterChangedEvent() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.VoterChanged(pool, alice, bob);
        IStakePool(pool).setVoter(bob);
    }

    function test_RevertWhen_setVoter_notOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOwner.selector, bob, alice));
        IStakePool(pool).setVoter(charlie);
    }

    // ========================================================================
    // STAKE POOL TESTS - Hook Integration
    // ========================================================================

    function test_setHook_setsHook() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        MockStakingHook mockHook = new MockStakingHook();

        vm.prank(alice);
        IStakePool(pool).setHook(address(mockHook));

        assertEq(IStakePool(pool).getHook(), address(mockHook));
    }

    function test_setHook_emitsHookChangedEvent() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        MockStakingHook mockHook = new MockStakingHook();

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IStakePool.HookChanged(pool, address(0), address(mockHook));
        IStakePool(pool).setHook(address(mockHook));
    }

    function test_hook_calledOnAddStake() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        MockStakingHook mockHook = new MockStakingHook();
        vm.prank(alice);
        IStakePool(pool).setHook(address(mockHook));

        vm.prank(alice);
        IStakePool(pool).addStake{value: 5 ether}();

        assertEq(mockHook.lastAddedAmount(), 5 ether);
        assertEq(mockHook.addedCount(), 1);
    }

    function test_hook_calledOnWithdraw() public {
        vm.prank(alice);
        address pool = staking.createPool{value: 10 ether}(alice);

        MockStakingHook mockHook = new MockStakingHook();
        vm.prank(alice);
        IStakePool(pool).setHook(address(mockHook));

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(alice);
        IStakePool(pool).withdraw(5 ether);

        assertEq(mockHook.lastWithdrawnAmount(), 5 ether);
        assertEq(mockHook.withdrawnCount(), 1);
    }

    function test_hook_calledOnIncreaseLockup() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        MockStakingHook mockHook = new MockStakingHook();
        vm.prank(alice);
        IStakePool(pool).setHook(address(mockHook));

        vm.prank(alice);
        IStakePool(pool).increaseLockup(LOCKUP_DURATION);

        uint64 expectedLockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION + LOCKUP_DURATION;
        assertEq(mockHook.lastLockedUntil(), expectedLockedUntil);
        assertEq(mockHook.lockupCount(), 1);
    }

    function test_RevertWhen_setHook_notOwner() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        MockStakingHook mockHook = new MockStakingHook();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOwner.selector, bob, alice));
        IStakePool(pool).setHook(address(mockHook));
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_createPool_variousAmounts(uint96 amount) public {
        amount = uint96(bound(amount, MIN_STAKE, 1000 ether));

        vm.prank(alice);
        address pool = staking.createPool{value: amount}(alice);

        assertEq(IStakePool(pool).getStake(), amount);
        assertEq(IStakePool(pool).getVotingPower(), amount);
    }

    function testFuzz_addStake_variousAmounts(uint96 initialStake, uint96 additionalStake) public {
        initialStake = uint96(bound(initialStake, MIN_STAKE, 500 ether));
        additionalStake = uint96(bound(additionalStake, 1, 500 ether));

        vm.prank(alice);
        address pool = staking.createPool{value: initialStake}(alice);

        vm.prank(alice);
        IStakePool(pool).addStake{value: additionalStake}();

        assertEq(IStakePool(pool).getStake(), uint256(initialStake) + uint256(additionalStake));
    }

    function testFuzz_withdraw_afterLockup(uint96 stakeAmount, uint96 withdrawAmount) public {
        stakeAmount = uint96(bound(stakeAmount, MIN_STAKE, 1000 ether));
        withdrawAmount = uint96(bound(withdrawAmount, 1, stakeAmount));

        vm.prank(alice);
        address pool = staking.createPool{value: stakeAmount}(alice);

        _advanceTime(LOCKUP_DURATION + 1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool).withdraw(withdrawAmount);

        assertEq(IStakePool(pool).getStake(), stakeAmount - withdrawAmount);
        assertEq(alice.balance, balanceBefore + withdrawAmount);
    }

    function testFuzz_multiplePools_concurrentOperations(uint8 numPools) public {
        numPools = uint8(bound(numPools, 1, 10));

        address[] memory pools = new address[](numPools);

        // Create pools
        for (uint256 i = 0; i < numPools; i++) {
            vm.prank(alice);
            pools[i] = staking.createPool{value: MIN_STAKE}(alice);
        }

        assertEq(staking.getPoolCount(), numPools);

        // Each pool should have correct state
        for (uint256 i = 0; i < numPools; i++) {
            assertEq(IStakePool(pools[i]).getStake(), MIN_STAKE);
            assertEq(IStakePool(pools[i]).getOwner(), alice);
        }
    }

    // ========================================================================
    // INVARIANT TESTS
    // ========================================================================

    function test_invariant_votingPowerMatchesLockedStake() public {
        vm.prank(alice);
        address pool = staking.createPool{value: 10 ether}(alice);

        // When locked: votingPower == stake
        assertTrue(IStakePool(pool).isLocked());
        assertEq(IStakePool(pool).getVotingPower(), IStakePool(pool).getStake());

        // When unlocked: votingPower == 0
        _advanceTime(LOCKUP_DURATION + 1);
        assertFalse(IStakePool(pool).isLocked());
        assertEq(IStakePool(pool).getVotingPower(), 0);
    }

    function test_invariant_lockupNeverDecreases() public {
        vm.prank(alice);
        address pool = staking.createPool{value: MIN_STAKE}(alice);

        uint64 lockedUntil1 = IStakePool(pool).getLockedUntil();

        // addStake should only increase or maintain lockup
        _advanceTime(LOCKUP_DURATION / 4);
        vm.prank(alice);
        IStakePool(pool).addStake{value: 1 ether}();
        uint64 lockedUntil2 = IStakePool(pool).getLockedUntil();
        assertGe(lockedUntil2, lockedUntil1, "Lockup should not decrease");

        // increaseLockup should always increase
        vm.prank(alice);
        IStakePool(pool).increaseLockup(LOCKUP_DURATION);
        uint64 lockedUntil3 = IStakePool(pool).getLockedUntil();
        assertGt(lockedUntil3, lockedUntil2, "Lockup should increase");
    }

    function test_invariant_withdrawOnlyWhenUnlocked() public {
        vm.prank(alice);
        address pool = staking.createPool{value: 10 ether}(alice);

        // Should fail while locked
        assertTrue(IStakePool(pool).isLocked());
        vm.prank(alice);
        vm.expectRevert();
        IStakePool(pool).withdraw(1 ether);

        // Should succeed when unlocked
        _advanceTime(LOCKUP_DURATION + 1);
        assertFalse(IStakePool(pool).isLocked());
        vm.prank(alice);
        IStakePool(pool).withdraw(1 ether); // Should not revert
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _advanceTime(uint64 duration) internal {
        uint64 currentTime = timestamp.microseconds();
        uint64 newTime = currentTime + duration;
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, newTime);
    }
}

