// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Staking} from "../../../src/staking/Staking.sol";
import {IStaking} from "../../../src/staking/IStaking.sol";
import {StakePosition} from "../../../src/foundation/Types.sol";
import {SystemAddresses} from "../../../src/foundation/SystemAddresses.sol";
import {Errors} from "../../../src/foundation/Errors.sol";

/// @title StakingTest
/// @notice Unit tests for the Staking contract
contract StakingTest is Test {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    uint64 constant LOCKUP_DURATION_MICROS = 7 days * 1_000_000; // 7 days in microseconds
    uint256 constant MINIMUM_STAKE = 1 ether;
    uint256 constant MINIMUM_PROPOSAL_STAKE = 10 ether;

    // ========================================================================
    // STATE
    // ========================================================================

    Staking public staking;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // ========================================================================
    // SETUP
    // ========================================================================

    function setUp() public {
        // Deploy Staking contract at the system address
        staking = new Staking();
        vm.etch(SystemAddresses.STAKING, address(staking).code);
        staking = Staking(SystemAddresses.STAKING);

        // Deploy mock Timestamp contract
        _deployMockTimestamp(1_000_000_000_000); // Start at 1M seconds in microseconds

        // Deploy mock StakingConfig contract
        _deployMockStakingConfig();

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    // ========================================================================
    // MOCK DEPLOYMENTS
    // ========================================================================

    function _deployMockTimestamp(uint64 initialTime) internal {
        MockTimestamp mockTimestamp = new MockTimestamp(initialTime);
        vm.etch(SystemAddresses.TIMESTAMP, address(mockTimestamp).code);
        // Store the initial timestamp in slot 0
        vm.store(SystemAddresses.TIMESTAMP, bytes32(0), bytes32(uint256(initialTime)));
    }

    function _deployMockStakingConfig() internal {
        MockStakingConfig mockConfig = new MockStakingConfig();
        vm.etch(SystemAddresses.STAKE_CONFIG, address(mockConfig).code);
        // Store values in appropriate slots
        // Slot 0: minimumStake, Slot 1: lockupDurationMicros, Slot 2: minimumProposalStake, Slot 3: _initialized
        vm.store(SystemAddresses.STAKE_CONFIG, bytes32(uint256(0)), bytes32(MINIMUM_STAKE));
        vm.store(SystemAddresses.STAKE_CONFIG, bytes32(uint256(1)), bytes32(uint256(LOCKUP_DURATION_MICROS)));
        vm.store(SystemAddresses.STAKE_CONFIG, bytes32(uint256(2)), bytes32(MINIMUM_PROPOSAL_STAKE));
        vm.store(SystemAddresses.STAKE_CONFIG, bytes32(uint256(3)), bytes32(uint256(1))); // initialized = true
    }

    function _advanceTime(uint64 deltaMicros) internal {
        uint64 current = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        vm.store(SystemAddresses.TIMESTAMP, bytes32(0), bytes32(uint256(current + deltaMicros)));
    }

    function _setTime(uint64 timeMicros) internal {
        vm.store(SystemAddresses.TIMESTAMP, bytes32(0), bytes32(uint256(timeMicros)));
    }

    // ========================================================================
    // STAKE TESTS
    // ========================================================================

    function test_stake_createsNewPosition() public {
        uint256 amount = 10 ether;
        uint64 now_ = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 expectedLockup = now_ + LOCKUP_DURATION_MICROS;

        vm.prank(alice);
        staking.stake{value: amount}();

        StakePosition memory pos = staking.getStake(alice);
        assertEq(pos.amount, amount, "Stake amount mismatch");
        assertEq(pos.lockedUntil, expectedLockup, "Lockup time mismatch");
        assertEq(pos.stakedAt, now_, "StakedAt mismatch");
        assertEq(staking.getTotalStaked(), amount, "Total staked mismatch");
    }

    function test_stake_addsToExistingPosition() public {
        uint256 amount1 = 10 ether;
        uint256 amount2 = 5 ether;
        uint64 now_ = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        vm.startPrank(alice);
        staking.stake{value: amount1}();

        // Advance time by 1 day
        _advanceTime(1 days * 1_000_000);

        staking.stake{value: amount2}();
        vm.stopPrank();

        StakePosition memory pos = staking.getStake(alice);
        assertEq(pos.amount, amount1 + amount2, "Stake amount mismatch");
        assertEq(pos.stakedAt, now_, "StakedAt should not change"); // Original stake time preserved
        assertEq(staking.getTotalStaked(), amount1 + amount2, "Total staked mismatch");
    }

    function test_stake_extendsLockup() public {
        uint256 amount = 10 ether;
        uint64 initialTime = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        vm.prank(alice);
        staking.stake{value: amount}();

        StakePosition memory pos1 = staking.getStake(alice);
        uint64 originalLockup = pos1.lockedUntil;

        // Advance time by 1 day
        _advanceTime(1 days * 1_000_000);
        uint64 newTime = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 expectedNewLockup = newTime + LOCKUP_DURATION_MICROS;

        vm.prank(alice);
        staking.stake{value: 1 ether}();

        StakePosition memory pos2 = staking.getStake(alice);
        assertEq(pos2.lockedUntil, expectedNewLockup, "Lockup should be extended");
        assertGt(pos2.lockedUntil, originalLockup, "New lockup should be greater than original");
    }

    function test_stake_emitsStakedEvent() public {
        uint256 amount = 10 ether;
        uint64 now_ = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 expectedLockup = now_ + LOCKUP_DURATION_MICROS;

        vm.expectEmit(true, false, false, true);
        emit IStaking.Staked(alice, amount, expectedLockup);

        vm.prank(alice);
        staking.stake{value: amount}();
    }

    function test_stake_revertsOnZeroAmount() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(alice);
        staking.stake{value: 0}();
    }

    // ========================================================================
    // VOTING POWER TESTS
    // ========================================================================

    function test_getVotingPower_returnsStakeWhenLocked() public {
        uint256 amount = 10 ether;

        vm.prank(alice);
        staking.stake{value: amount}();

        uint256 votingPower = staking.getVotingPower(alice);
        assertEq(votingPower, amount, "Voting power should equal stake amount");
    }

    function test_getVotingPower_returnsZeroWhenLockupExpired() public {
        uint256 amount = 10 ether;

        vm.prank(alice);
        staking.stake{value: amount}();

        // Advance past lockup
        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        uint256 votingPower = staking.getVotingPower(alice);
        assertEq(votingPower, 0, "Voting power should be zero after lockup expires");
    }

    function test_getVotingPower_returnsZeroForNonStaker() public {
        uint256 votingPower = staking.getVotingPower(alice);
        assertEq(votingPower, 0, "Voting power should be zero for non-staker");
    }

    function test_isLocked_returnsTrueWhenLocked() public {
        vm.prank(alice);
        staking.stake{value: 10 ether}();

        assertTrue(staking.isLocked(alice), "Should be locked");
    }

    function test_isLocked_returnsFalseWhenExpired() public {
        vm.prank(alice);
        staking.stake{value: 10 ether}();

        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        assertFalse(staking.isLocked(alice), "Should not be locked after expiry");
    }

    // ========================================================================
    // UNSTAKE TESTS
    // ========================================================================

    function test_unstake_withdrawsPartialAmount() public {
        uint256 stakeAmount = 10 ether;
        uint256 unstakeAmount = 4 ether;

        vm.prank(alice);
        staking.stake{value: stakeAmount}();

        // Advance past lockup
        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        staking.unstake(unstakeAmount);

        uint256 balanceAfter = alice.balance;
        StakePosition memory pos = staking.getStake(alice);

        assertEq(balanceAfter - balanceBefore, unstakeAmount, "Should receive unstaked amount");
        assertEq(pos.amount, stakeAmount - unstakeAmount, "Remaining stake mismatch");
        assertEq(staking.getTotalStaked(), stakeAmount - unstakeAmount, "Total staked mismatch");
    }

    function test_unstake_emitsUnstakedEvent() public {
        uint256 stakeAmount = 10 ether;
        uint256 unstakeAmount = 4 ether;

        vm.prank(alice);
        staking.stake{value: stakeAmount}();

        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        vm.expectEmit(true, false, false, true);
        emit IStaking.Unstaked(alice, unstakeAmount);

        vm.prank(alice);
        staking.unstake(unstakeAmount);
    }

    function test_unstake_revertsWhenLocked() public {
        uint256 stakeAmount = 10 ether;

        vm.prank(alice);
        staking.stake{value: stakeAmount}();

        StakePosition memory pos = staking.getStake(alice);
        uint64 now_ = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        vm.expectRevert(abi.encodeWithSelector(Errors.LockupNotExpired.selector, pos.lockedUntil, now_));
        vm.prank(alice);
        staking.unstake(1 ether);
    }

    function test_unstake_revertsOnZeroAmount() public {
        vm.prank(alice);
        staking.stake{value: 10 ether}();

        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(alice);
        staking.unstake(0);
    }

    function test_unstake_revertsOnInsufficientStake() public {
        uint256 stakeAmount = 10 ether;

        vm.prank(alice);
        staking.stake{value: stakeAmount}();

        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientStake.selector, stakeAmount + 1, stakeAmount));
        vm.prank(alice);
        staking.unstake(stakeAmount + 1);
    }

    function test_unstake_revertsOnNoStakePosition() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.NoStakePosition.selector, alice));
        vm.prank(alice);
        staking.unstake(1 ether);
    }

    // ========================================================================
    // WITHDRAW TESTS
    // ========================================================================

    function test_withdraw_withdrawsFullAmount() public {
        uint256 stakeAmount = 10 ether;

        vm.prank(alice);
        staking.stake{value: stakeAmount}();

        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        staking.withdraw();

        uint256 balanceAfter = alice.balance;
        StakePosition memory pos = staking.getStake(alice);

        assertEq(balanceAfter - balanceBefore, stakeAmount, "Should receive full amount");
        assertEq(pos.amount, 0, "Stake should be zero");
        assertEq(staking.getTotalStaked(), 0, "Total staked should be zero");
    }

    function test_withdraw_revertsWhenLocked() public {
        vm.prank(alice);
        staking.stake{value: 10 ether}();

        StakePosition memory pos = staking.getStake(alice);
        uint64 now_ = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        vm.expectRevert(abi.encodeWithSelector(Errors.LockupNotExpired.selector, pos.lockedUntil, now_));
        vm.prank(alice);
        staking.withdraw();
    }

    function test_withdraw_revertsOnNoStakePosition() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.NoStakePosition.selector, alice));
        vm.prank(alice);
        staking.withdraw();
    }

    // ========================================================================
    // EXTEND LOCKUP TESTS
    // ========================================================================

    function test_extendLockup_extendsLockup() public {
        vm.prank(alice);
        staking.stake{value: 10 ether}();

        // Advance time but stay within lockup
        _advanceTime(1 days * 1_000_000);
        uint64 newTime = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 expectedNewLockup = newTime + LOCKUP_DURATION_MICROS;

        vm.prank(alice);
        staking.extendLockup();

        StakePosition memory pos = staking.getStake(alice);
        assertEq(pos.lockedUntil, expectedNewLockup, "Lockup should be extended");
    }

    function test_extendLockup_emitsLockupExtendedEvent() public {
        vm.prank(alice);
        staking.stake{value: 10 ether}();

        _advanceTime(1 days * 1_000_000);
        uint64 newTime = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 expectedNewLockup = newTime + LOCKUP_DURATION_MICROS;

        vm.expectEmit(true, false, false, true);
        emit IStaking.LockupExtended(alice, expectedNewLockup);

        vm.prank(alice);
        staking.extendLockup();
    }

    function test_extendLockup_revertsOnNoStakePosition() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.NoStakePosition.selector, alice));
        vm.prank(alice);
        staking.extendLockup();
    }

    function test_extendLockup_revertsIfNotExtending() public {
        vm.prank(alice);
        staking.stake{value: 10 ether}();

        StakePosition memory pos = staking.getStake(alice);
        uint64 now_ = MockTimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // Try to extend immediately (no time passed) - should fail
        vm.expectRevert(abi.encodeWithSelector(Errors.LockupNotExpired.selector, pos.lockedUntil, now_));
        vm.prank(alice);
        staking.extendLockup();
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_stake_variousAmounts(uint96 amount) public {
        vm.assume(amount > 0);

        vm.deal(alice, uint256(amount));

        vm.prank(alice);
        staking.stake{value: amount}();

        assertEq(staking.getStake(alice).amount, amount);
        assertEq(staking.getTotalStaked(), amount);
        assertEq(staking.getVotingPower(alice), amount);
    }

    function testFuzz_unstake_afterLockup(uint96 stakeAmount, uint96 unstakeAmount) public {
        vm.assume(stakeAmount > 0);
        vm.assume(unstakeAmount > 0);
        vm.assume(unstakeAmount <= stakeAmount);

        vm.deal(alice, stakeAmount);

        vm.prank(alice);
        staking.stake{value: stakeAmount}();

        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        vm.prank(alice);
        staking.unstake(unstakeAmount);

        assertEq(staking.getStake(alice).amount, stakeAmount - unstakeAmount);
    }

    function testFuzz_multipleStakers(uint96 aliceAmount, uint96 bobAmount) public {
        vm.assume(aliceAmount > 0);
        vm.assume(bobAmount > 0);

        vm.deal(alice, aliceAmount);
        vm.deal(bob, bobAmount);

        vm.prank(alice);
        staking.stake{value: aliceAmount}();

        vm.prank(bob);
        staking.stake{value: bobAmount}();

        assertEq(staking.getTotalStaked(), uint256(aliceAmount) + uint256(bobAmount));
        assertEq(staking.getVotingPower(alice), aliceAmount);
        assertEq(staking.getVotingPower(bob), bobAmount);
    }
}

// ============================================================================
// MOCK CONTRACTS
// ============================================================================

contract MockTimestamp {
    uint64 public microseconds;

    constructor(uint64 initialTime) {
        microseconds = initialTime;
    }

    function nowMicroseconds() external view returns (uint64) {
        return microseconds;
    }

    function nowSeconds() external view returns (uint64) {
        return microseconds / 1_000_000;
    }
}

contract MockStakingConfig {
    uint256 public minimumStake;
    uint64 public lockupDurationMicros;
    uint256 public minimumProposalStake;
    bool private _initialized;

    function initialize(uint256 _minimumStake, uint64 _lockupDurationMicros, uint256 _minimumProposalStake) external {
        minimumStake = _minimumStake;
        lockupDurationMicros = _lockupDurationMicros;
        minimumProposalStake = _minimumProposalStake;
        _initialized = true;
    }
}

