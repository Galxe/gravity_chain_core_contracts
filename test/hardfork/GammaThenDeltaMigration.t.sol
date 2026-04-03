// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { HardforkTestBase } from "./HardforkTestBase.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";
import { ConsensusConfig } from "../../src/runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "../../src/runtime/ExecutionConfig.sol";
import { VersionConfig } from "../../src/runtime/VersionConfig.sol";
import { RandomnessConfig } from "../../src/runtime/RandomnessConfig.sol";
import { Governance } from "../../src/governance/Governance.sol";
import { ReentrancyAttacker } from "./helpers/ReentrancyAttacker.sol";

/// @title GammaThenDeltaMigrationTest
/// @notice Sequential hardfork migration test: v1.0.0 → Gamma → Delta.
///         Verifies:
///         1. ReentrancyGuard initialized by Gamma persists through Delta
///         2. ReentrancyGuard actually blocks reentrancy attacks after both hardforks
///         3. Delta-specific features work correctly after the sequential upgrade
///         4. Full epoch lifecycle works after the sequential upgrade path
contract GammaThenDeltaMigrationTest is HardforkTestBase {
    address public pool1;
    address public pool2;

    /// @notice ReentrancyGuard ERC-7201 namespaced storage slot (from HardforkRegistry)
    bytes32 constant REENTRANCY_GUARD_SLOT = HardforkRegistry.REENTRANCY_GUARD_SLOT;

    function setUp() public {
        _fundTestAccounts();

        // Step 1: Deploy v1.0.0 bytecodes from fixtures
        _deployFromFixtures("gravity-testnet-v1.0.0");

        // Step 2: Initialize using v1.0.0 contracts (4-arg StakingConfig.initialize)
        _initializeAllConfigsV100();
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();

        // Step 3: Create validators and stake pools on v1.0.0
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 3, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND * 3, "bob");

        // Step 4: Process epoch to activate validators
        _processEpoch();

        // Step 5: Run one epoch on v1.0.0 code to prove chain is live
        _completeEpochTransition();
    }

    /// @notice Initialize configs using v1.0.0 ABI (StakingConfig has 4-arg initialize)
    function _initializeAllConfigsV100() internal {
        vm.startPrank(SystemAddresses.GENESIS);

        // v1.0.0 StakingConfig.initialize(uint256,uint64,uint64,uint256)
        (bool ok,) = SystemAddresses.STAKE_CONFIG
            .call(
                abi.encodeWithSignature(
                    "initialize(uint256,uint64,uint64,uint256)",
                    MIN_STAKE,
                    LOCKUP_DURATION,
                    UNBONDING_DELAY,
                    MIN_PROPOSAL_STAKE
                )
            );
        require(ok, "v1.0.0 StakingConfig.initialize failed");

        validatorConfig.initialize(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
        );
        epochConfig.initialize(TWO_HOURS);
        ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG).initialize(hex"00");
        ExecutionConfig(SystemAddresses.EXECUTION_CONFIG).initialize(hex"00");
        VersionConfig(SystemAddresses.VERSION_CONFIG).initialize(1);
        governanceConfig.initialize(50, MIN_PROPOSAL_STAKE, 7 days * 1_000_000);
        RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).initialize(_createV2Config());

        uint32[] memory sourceTypes = new uint32[](1);
        sourceTypes[0] = 1;
        address[] memory callbacks = new address[](1);
        callbacks[0] = SystemAddresses.JWK_MANAGER;
        nativeOracle.initialize(sourceTypes, callbacks);
        vm.stopPrank();
    }

    /// @notice Apply Gamma hardfork (bytecode replacement + ReentrancyGuard init)
    function _applyGamma() internal {
        _applyHardfork(HardforkRegistry.gamma());
    }

    /// @notice Apply Delta hardfork (bytecode replacement only, no post-actions)
    function _applyDelta() internal {
        _applyHardfork(HardforkRegistry.delta());
    }

    /// @notice Apply both hardforks sequentially: Gamma then Delta
    function _applyGammaThenDelta() internal {
        _applyGamma();
        _completeEpochTransition(); // Run an epoch between hardforks
        _applyDelta();
    }

    /// @notice Helper to verify ReentrancyGuard slot value for all tracked pools
    function _assertReentrancyGuardInitialized(
        string memory context
    ) internal view {
        for (uint256 i = 0; i < stakePoolAddresses.length; i++) {
            bytes32 val = vm.load(stakePoolAddresses[i], REENTRANCY_GUARD_SLOT);
            assertEq(
                val,
                bytes32(uint256(1)),
                string.concat(
                    context, ": ReentrancyGuard not NOT_ENTERED for pool ", vm.toString(stakePoolAddresses[i])
                )
            );
        }
    }

    // ========================================================================
    // PRE-HARDFORK VERIFICATION
    // ========================================================================

    function test_preHardfork_chainIsRunning() public view {
        assertEq(validatorManager.getActiveValidatorCount(), 2, "should have 2 active validators");
        assertEq(reconfig.currentEpoch(), 2, "should be epoch 2 after one transition");
    }

    function test_preHardfork_reentrancyGuardNotSet() public view {
        // Before Gamma, ReentrancyGuard slot should be 0 (uninitialized)
        for (uint256 i = 0; i < stakePoolAddresses.length; i++) {
            bytes32 val = vm.load(stakePoolAddresses[i], REENTRANCY_GUARD_SLOT);
            assertEq(val, bytes32(uint256(0)), "ReentrancyGuard should be 0 before Gamma");
        }
    }

    // ========================================================================
    // GAMMA → DELTA SEQUENTIAL: ReentrancyGuard PERSISTENCE
    // ========================================================================

    function test_gammaThenDelta_reentrancyGuardSetAfterGamma() public {
        _applyGamma();
        _assertReentrancyGuardInitialized("after Gamma");
    }

    function test_gammaThenDelta_reentrancyGuardPreservedAfterDelta() public {
        _applyGammaThenDelta();
        _assertReentrancyGuardInitialized("after Gamma+Delta");
    }

    function test_gammaThenDelta_reentrancyGuardPreservedWithNewPool() public {
        _applyGamma();

        // Create a new pool after Gamma (its ReentrancyGuard is initialized by constructor)
        address pool3 = _createStakePool(charlie, MIN_STAKE);

        _completeEpochTransition();
        _applyDelta();

        // Verify all pools including the one created between hardforks
        _assertReentrancyGuardInitialized("after Gamma+Delta with new pool");

        // Also verify the new pool specifically
        bytes32 val = vm.load(pool3, REENTRANCY_GUARD_SLOT);
        assertEq(val, bytes32(uint256(1)), "new pool ReentrancyGuard should be NOT_ENTERED");
    }

    // ========================================================================
    // GAMMA → DELTA SEQUENTIAL: ReentrancyGuard EFFECTIVENESS
    // ========================================================================

    function test_gammaThenDelta_nonReentrantFunctionsWork() public {
        _applyGammaThenDelta();

        // withdrawRewards should work normally (no reentrancy)
        uint256 activeStake = IStakePool(pool1).getActiveStake();
        uint256 rewardAmount = 3 ether;
        vm.deal(pool1, activeStake + rewardAmount);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool1).withdrawRewards(alice);
        assertEq(alice.balance, aliceBefore + rewardAmount, "rewards withdrawn normally");
    }

    function test_gammaThenDelta_reentrancyBlockedOnWithdrawRewards() public {
        _applyGammaThenDelta();

        // Set up the attacker as the staker of pool1
        ReentrancyAttacker attacker = new ReentrancyAttacker();
        vm.prank(alice);
        IStakePool(pool1).setStaker(address(attacker));

        // Fund pool with rewards
        uint256 activeStake = IStakePool(pool1).getActiveStake();
        vm.deal(pool1, activeStake + 10 ether);

        // Configure attacker to re-enter withdrawRewards
        attacker.setAttack(pool1, ReentrancyAttacker.AttackTarget.WITHDRAW_REWARDS);

        // Call withdrawRewards with attacker as recipient — the receive() will try to re-enter
        vm.prank(address(attacker));
        IStakePool(pool1).withdrawRewards(address(attacker));

        // The attack was triggered but reentrancy should have been blocked
        assertTrue(attacker.attackTriggered(), "attack receive() was triggered");
        assertFalse(attacker.reentrancySucceeded(), "reentrancy should be blocked by ReentrancyGuard");
    }

    function test_gammaThenDelta_reentrancyBlockedOnWithdrawAvailable() public {
        _applyGammaThenDelta();

        ReentrancyAttacker attacker = new ReentrancyAttacker();
        vm.prank(alice);
        IStakePool(pool1).setStaker(address(attacker));

        // Unstake some amount to create pending buckets
        vm.prank(address(attacker));
        IStakePool(pool1).unstake(1 ether);

        // Advance time past lockup + unbonding to make it withdrawable
        _advanceTime(LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Configure attacker to re-enter withdrawAvailable
        attacker.setAttack(pool1, ReentrancyAttacker.AttackTarget.WITHDRAW_AVAILABLE);

        // Call withdrawAvailable — receive() will try to re-enter
        vm.prank(address(attacker));
        IStakePool(pool1).withdrawAvailable(address(attacker));

        assertTrue(attacker.attackTriggered(), "attack receive() was triggered");
        assertFalse(attacker.reentrancySucceeded(), "reentrancy should be blocked by ReentrancyGuard");
    }

    // ========================================================================
    // GAMMA → DELTA SEQUENTIAL: DELTA FEATURES
    // ========================================================================

    function test_gammaThenDelta_stakingConfigNewSignature() public {
        _applyGammaThenDelta();

        // Delta's 3-arg setForNextEpoch should work (minimumProposalStake removed)
        uint256 newMinStake = 5 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(newMinStake, LOCKUP_DURATION, UNBONDING_DELAY);
        assertTrue(stakingConfig.hasPendingConfig(), "pending config set");

        _completeEpochTransition();
        assertEq(stakingConfig.minimumStake(), newMinStake, "new config applied");
        assertFalse(stakingConfig.hasPendingConfig(), "pending cleared");
    }

    function test_gammaThenDelta_governanceMaxProposalTargets() public {
        _applyGammaThenDelta();

        assertEq(
            Governance(SystemAddresses.GOVERNANCE).MAX_PROPOSAL_TARGETS(), 100, "MAX_PROPOSAL_TARGETS should be 100"
        );
    }

    function test_gammaThenDelta_governanceRenounceOwnershipBlocked() public {
        _applyGammaThenDelta();

        vm.expectRevert();
        Governance(SystemAddresses.GOVERNANCE).renounceOwnership();
    }

    function test_gammaThenDelta_nativeOracleSequentialNonce() public {
        _applyGammaThenDelta();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.record(1, 100, 1, block.number, hex"aabb", 0);

        // Gap should fail
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSelector(Errors.NonceNotSequential.selector, 1, 100, 2, 3));
        nativeOracle.record(1, 100, 3, block.number, hex"ccdd", 0);

        // Sequential should succeed
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.record(1, 100, 2, block.number, hex"ccdd", 0);
        assertEq(nativeOracle.getLatestNonce(1, 100), 2, "nonce should be 2");
    }

    // ========================================================================
    // GAMMA → DELTA SEQUENTIAL: FULL LIFECYCLE
    // ========================================================================

    function test_gammaThenDelta_fullEpochLifecycle() public {
        _applyGammaThenDelta();

        // Add stake
        vm.prank(alice);
        IStakePool(pool1).addStake{ value: 5 ether }();

        // Update config
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(2 ether, LOCKUP_DURATION, UNBONDING_DELAY);

        // Join new validator
        _createRegisterAndJoin(charlie, MIN_BOND, "charlie");

        // Complete epoch
        _completeEpochTransition();

        assertEq(stakingConfig.minimumStake(), 2 ether, "config applied");
        assertEq(validatorManager.getActiveValidatorCount(), 3, "3 validators");
        assertEq(IStakePool(pool1).getActiveStake(), MIN_BOND * 3 + 5 ether, "stake increased");

        // ReentrancyGuard still intact
        _assertReentrancyGuardInitialized("after full lifecycle");
    }

    function test_gammaThenDelta_multipleEpochsAfterBothHardforks() public {
        _applyGammaThenDelta();

        uint64 epochBefore = reconfig.currentEpoch();
        for (uint256 i = 0; i < 5; i++) {
            _completeEpochTransition();
        }
        assertEq(reconfig.currentEpoch(), epochBefore + 5, "5 epochs completed");
        assertEq(validatorManager.getActiveValidatorCount(), 2, "validators preserved");
        _assertReentrancyGuardInitialized("after 5 epochs post-both-hardforks");
    }

    function test_gammaThenDelta_storagePreservedAcrossBothHardforks() public {
        // Snapshot critical StakingConfig storage before any hardfork
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = bytes32(uint256(0)); // minimumStake
        slots[1] = bytes32(uint256(1)); // lockup|unbonding (packed)
        _snapshotStorage(SystemAddresses.STAKE_CONFIG, slots);

        _applyGammaThenDelta();

        _verifyStoragePreserved();
        assertTrue(stakingConfig.isInitialized(), "still initialized");
        assertEq(stakingConfig.lockupDurationMicros(), LOCKUP_DURATION, "lockup preserved");
        assertEq(stakingConfig.unbondingDelayMicros(), UNBONDING_DELAY, "unbonding preserved");
    }
}
