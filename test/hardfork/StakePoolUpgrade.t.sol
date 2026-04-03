// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { GammaHardforkBase } from "./GammaHardforkBase.t.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title StakePoolUpgradeTest
/// @notice Tests for StakePool after Gamma hardfork bytecode replacement.
///         Key concerns:
///         - withdrawRewards() works on upgraded pools
///         - receive() is removed (sending ETH reverts)
///         - ReentrancyGuard is functional (slot initialized)
///         - setOperator/setVoter/setStaker zero address validation
///         - renewLockUntil MAX_LOCKUP_DURATION validation
///         - _addPending MAX_PENDING_BUCKETS limit
contract StakePoolUpgradeTest is GammaHardforkBase {
    address public pool1;
    address public pool2;

    function setUp() public override {
        super.setUp();
        // Create pools BEFORE hardfork
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 2, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Apply Gamma hardfork (replaces StakePool bytecodes)
        _applyGammaHardfork();
    }

    // ========================================================================
    // REENTRANCY GUARD
    // ========================================================================

    /// @notice Verify ReentrancyGuard slot is initialized after hardfork
    function test_reentrancyGuard_slotInitialized() public view {
        bytes32 slot = vm.load(pool1, HardforkRegistry.REENTRANCY_GUARD_SLOT);
        assertEq(uint256(slot), 1, "ReentrancyGuard should be NOT_ENTERED (1)");
    }

    // ========================================================================
    // WITHDRAW REWARDS
    // ========================================================================

    /// @notice Test withdrawRewards() on upgraded pool
    function test_withdrawRewards_basic() public {
        // Simulate rewards by sending ETH directly to pool via vm.deal
        // Pool balance = activeStake + rewards
        uint256 activeStake = IStakePool(pool1).getActiveStake();
        uint256 rewardAmount = 5 ether;
        vm.deal(pool1, activeStake + rewardAmount);

        // Get reward balance
        uint256 rewardBalance = IStakePool(pool1).getRewardBalance();
        assertEq(rewardBalance, rewardAmount, "reward balance should equal extra ETH");

        // Withdraw rewards (only owner can call)
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool1).withdrawRewards(alice);

        assertEq(alice.balance, aliceBalBefore + rewardAmount, "alice should receive rewards");
        assertEq(IStakePool(pool1).getRewardBalance(), 0, "reward balance should be 0");
    }

    /// @notice Test withdrawRewards with zero rewards
    function test_withdrawRewards_zeroRewards() public {
        uint256 rewardBalance = IStakePool(pool1).getRewardBalance();
        assertEq(rewardBalance, 0, "should have no rewards initially");

        // Should not revert, just no-op
        vm.prank(alice);
        IStakePool(pool1).withdrawRewards(alice);
    }

    // ========================================================================
    // RECEIVE() REMOVAL
    // ========================================================================

    /// @notice Test that sending plain ETH to pool reverts (receive() removed)
    function test_receiveRemoved_plainEthReverts() public {
        vm.deal(charlie, 10 ether);
        vm.prank(charlie);
        (bool success,) = pool1.call{ value: 1 ether }("");
        assertFalse(success, "Plain ETH transfer should fail (no receive())");
    }

    // ========================================================================
    // ZERO ADDRESS VALIDATION
    // ========================================================================

    /// @notice Test setOperator with zero address reverts
    function test_setOperator_zeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        IStakePool(pool1).setOperator(address(0));
    }

    /// @notice Test setVoter with zero address reverts
    function test_setVoter_zeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        IStakePool(pool1).setVoter(address(0));
    }

    /// @notice Test setStaker with zero address reverts
    function test_setStaker_zeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        IStakePool(pool1).setStaker(address(0));
    }

    /// @notice Test setOperator no-op when setting to same value
    function test_setOperator_noopSameValue() public {
        address currentOperator = IStakePool(pool1).getOperator();
        // Should not revert, just no-op
        vm.prank(alice);
        IStakePool(pool1).setOperator(currentOperator);
        assertEq(IStakePool(pool1).getOperator(), currentOperator, "operator unchanged");
    }

    // ========================================================================
    // BASIC OPERATIONS STILL WORK
    // ========================================================================

    /// @notice Test addStake still works after hardfork
    function test_addStake_worksAfterHardfork() public {
        uint256 stakeBefore = IStakePool(pool1).getActiveStake();
        vm.prank(alice);
        IStakePool(pool1).addStake{ value: 1 ether }();
        assertEq(IStakePool(pool1).getActiveStake(), stakeBefore + 1 ether, "stake should increase");
    }

    /// @notice Test unstake still works after hardfork
    function test_unstake_worksAfterHardfork() public {
        // Alice leaves validator set first (need to leave before unstaking below minimum)
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        // Complete epoch to finalize leave
        _completeEpochTransition();

        // Now unstake
        uint256 stakeBefore = IStakePool(pool1).getActiveStake();
        vm.prank(alice);
        IStakePool(pool1).unstake(1 ether);
        assertEq(IStakePool(pool1).getActiveStake(), stakeBefore - 1 ether, "stake should decrease");
    }
}
