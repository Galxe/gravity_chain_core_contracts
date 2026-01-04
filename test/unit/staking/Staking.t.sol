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

/// @title StakingTest
/// @notice Unit tests for Staking factory and StakePool contracts with two-role separation
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
        address pool = staking.createPool{ value: MIN_STAKE }(
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

    function test_createPool_setsInitialStake() public {
        uint256 initialStake = 10 ether;
        vm.prank(alice);
        address pool = _createPool(alice, initialStake);

        assertEq(IStakePool(pool).getStake(), initialStake, "Stake should match initial value");
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

        assertEq(staking.getPoolVotingPower(pool), stakeAmount, "Should return voting power via factory");
    }

    function test_getPoolVotingPower_returnsZeroWhenUnlocked() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);

        assertEq(staking.getPoolVotingPower(pool), 0, "Should return 0 when unlocked");
    }

    function test_RevertWhen_getPoolVotingPower_invalidPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, alice));
        staking.getPoolVotingPower(alice);
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

    // ========================================================================
    // STAKE POOL TESTS - Staker Role (addStake)
    // ========================================================================

    function test_addStake_increasesStake() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint256 additionalStake = 5 ether;
        vm.prank(alice);
        IStakePool(pool).addStake{ value: additionalStake }();

        assertEq(IStakePool(pool).getStake(), MIN_STAKE + additionalStake);
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

        assertEq(IStakePool(pool).getStake(), MIN_STAKE + 1 ether);
    }

    // ========================================================================
    // STAKE POOL TESTS - Voting Power
    // ========================================================================

    function test_getVotingPower_returnsStakeWhenLocked() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        address pool = _createPool(alice, stakeAmount);

        assertEq(IStakePool(pool).getVotingPower(), stakeAmount);
    }

    function test_getVotingPower_returnsZeroWhenUnlocked() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);

        assertEq(IStakePool(pool).getVotingPower(), 0, "Voting power should be 0 when unlocked");
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
    // STAKE POOL TESTS - Withdraw (Staker Only)
    // ========================================================================

    function test_withdraw_withdrawsStake() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        _advanceTime(LOCKUP_DURATION + 1);

        uint256 balanceBefore = bob.balance;
        vm.prank(alice);
        IStakePool(pool).withdraw(5 ether, bob); // Withdraw to bob

        assertEq(IStakePool(pool).getStake(), 5 ether);
        assertEq(bob.balance, balanceBefore + 5 ether);
    }

    function test_withdraw_emitsStakeWithdrawnEvent() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IStakePool.StakeWithdrawn(pool, 5 ether, bob);
        IStakePool(pool).withdraw(5 ether, bob);
    }

    function test_RevertWhen_withdraw_locked() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        uint64 lockedUntil = IStakePool(pool).getLockedUntil();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LockupNotExpired.selector, lockedUntil, INITIAL_TIMESTAMP));
        IStakePool(pool).withdraw(MIN_STAKE, alice);
    }

    function test_RevertWhen_withdraw_zeroAmount() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        IStakePool(pool).withdraw(0, alice);
    }

    function test_RevertWhen_withdraw_notStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, charlie, bob));
        IStakePool(pool).withdraw(MIN_STAKE, charlie);
    }

    function test_withdraw_worksWithDifferentStaker() public {
        vm.prank(alice);
        address pool = _createPoolWithStaker(alice, bob, 10 ether);

        _advanceTime(LOCKUP_DURATION + 1);

        uint256 balanceBefore = charlie.balance;
        vm.prank(bob); // Bob is the staker
        IStakePool(pool).withdraw(5 ether, charlie); // Withdraw to charlie

        assertEq(IStakePool(pool).getStake(), 5 ether);
        assertEq(charlie.balance, balanceBefore + 5 ether);
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

    function test_renewLockUntil_restoresVotingPower() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        _advanceTime(LOCKUP_DURATION + 1);
        assertEq(IStakePool(pool).getVotingPower(), 0, "Voting power should be 0 when unlocked");

        vm.prank(alice);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION * 2); // Need enough to be >= now + minLockup

        assertEq(IStakePool(pool).getVotingPower(), MIN_STAKE, "Voting power should be restored");
    }

    function test_renewLockUntil_allowsSmallExtensionWhenFarInFuture() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        // Initial lockup is at INITIAL_TIMESTAMP + LOCKUP_DURATION
        // Now is INITIAL_TIMESTAMP, so result after adding 1 day is still >= now + minLockup
        uint64 smallExtension = 1 days * 1_000_000; // Small extension

        vm.prank(alice);
        IStakePool(pool).renewLockUntil(smallExtension);

        // Should succeed because result is still >= now + minLockup
        uint64 newLockedUntil = IStakePool(pool).getLockedUntil();
        assertEq(newLockedUntil, INITIAL_TIMESTAMP + LOCKUP_DURATION + smallExtension);
    }

    function test_RevertWhen_renewLockUntil_resultTooShort() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        // Advance time so current lockup is almost expired
        _advanceTime(LOCKUP_DURATION - 1 days * 1_000_000);

        // Try to extend by a tiny amount that would result in lockup < now + minLockup
        uint64 tinyExtension = 1; // 1 microsecond

        vm.prank(alice);
        // Result would be approx INITIAL_TIMESTAMP + LOCKUP_DURATION + 1, but now is much later
        // so result < now + minLockup
        vm.expectRevert(); // Will revert with LockupDurationTooShort
        IStakePool(pool).renewLockUntil(tinyExtension);
    }

    function test_RevertWhen_renewLockUntil_overflow() public {
        vm.prank(alice);
        address pool = _createPool(alice, MIN_STAKE);

        vm.prank(alice);
        vm.expectRevert(); // Will revert due to overflow
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
        assertEq(Ownable(pool).owner(), alice); // Still alice until accepted
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

        assertEq(IStakePool(pool).getStake(), amount);
        assertEq(IStakePool(pool).getVotingPower(), amount);
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

        assertEq(IStakePool(pool).getStake(), uint256(initialStake) + uint256(additionalStake));
    }

    function testFuzz_withdraw_afterLockup(
        uint96 stakeAmount,
        uint96 withdrawAmount
    ) public {
        stakeAmount = uint96(bound(stakeAmount, MIN_STAKE, 1000 ether));
        withdrawAmount = uint96(bound(withdrawAmount, 1, stakeAmount));

        vm.prank(alice);
        address pool = _createPool(alice, stakeAmount);

        _advanceTime(LOCKUP_DURATION + 1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool).withdraw(withdrawAmount, alice);

        assertEq(IStakePool(pool).getStake(), stakeAmount - withdrawAmount);
        assertEq(alice.balance, balanceBefore + withdrawAmount);
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
            assertEq(IStakePool(pools[i]).getStake(), MIN_STAKE);
            assertEq(Ownable(pools[i]).owner(), alice);
        }
    }

    // ========================================================================
    // INVARIANT TESTS
    // ========================================================================

    function test_invariant_votingPowerMatchesLockedStake() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

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

    function test_invariant_withdrawOnlyWhenUnlocked() public {
        vm.prank(alice);
        address pool = _createPool(alice, 10 ether);

        // Should fail while locked
        assertTrue(IStakePool(pool).isLocked());
        vm.prank(alice);
        vm.expectRevert();
        IStakePool(pool).withdraw(1 ether, alice);

        // Should succeed when unlocked
        _advanceTime(LOCKUP_DURATION + 1);
        assertFalse(IStakePool(pool).isLocked());
        vm.prank(alice);
        IStakePool(pool).withdraw(1 ether, alice); // Should not revert
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
