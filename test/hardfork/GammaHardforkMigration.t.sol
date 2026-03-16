// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { HardforkTestBase } from "./HardforkTestBase.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { ValidatorConsensusInfo, ValidatorStatus } from "../../src/foundation/Types.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title GammaHardforkMigrationTest
/// @notice Phase A1: True pre→post hardfork migration test.
///         Uses HardforkTestBase framework:
///         1. Loads v1.0.0 runtime bytecodes from fixtures via _deployFromFixtures()
///         2. Initializes chain state using v1.0.0 code
///         3. Applies Gamma hardfork via _applyHardfork(HardforkRegistry.gamma())
///         4. Verifies all post-hardfork functionality works correctly
contract GammaHardforkMigrationTest is HardforkTestBase {
    address public pool1;
    address public pool2;

    function setUp() public {
        _fundTestAccounts();

        // Deploy v1.0.0 bytecodes from fixtures
        _deployFromFixtures("gravity-testnet-v1.0.0");

        // Initialize using v1.0.0 contracts
        _initializeAllConfigs();
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();

        // Create 2 validators with larger stakes (for VP limit headroom)
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 3, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND * 3, "bob");

        // Process epoch to activate validators
        _processEpoch();

        // Run one epoch on v1.0.0 code to prove chain is live
        _completeEpochTransition();
    }

    // ========================================================================
    // PRE-HARDFORK VERIFICATION
    // ========================================================================

    function test_preHardfork_chainIsRunning() public view {
        assertEq(validatorManager.getActiveValidatorCount(), 2, "should have 2 active validators");
        assertEq(reconfig.currentEpoch(), 2, "should be epoch 2 after one transition");
        assertEq(stakingConfig.minimumStake(), MIN_STAKE, "v1.0.0 config values");
    }

    // ========================================================================
    // MIGRATION TESTS
    // ========================================================================

    function test_migration_epochTransitionAfterHardfork() public {
        uint64 epochBefore = reconfig.currentEpoch();
        _applyHardfork(HardforkRegistry.gamma());
        _completeEpochTransition();
        assertEq(reconfig.currentEpoch(), epochBefore + 1, "epoch should advance");
        assertEq(validatorManager.getActiveValidatorCount(), 2, "validators preserved");
    }

    function test_migration_stakingConfigStoragePreserved() public {
        // Snapshot critical slots before hardfork
        bytes32[] memory slots = new bytes32[](4);
        slots[0] = bytes32(uint256(0)); // minimumStake
        slots[1] = bytes32(uint256(1)); // lockupDurationMicros + unbondingDelayMicros
        slots[2] = bytes32(uint256(2)); // minimumProposalStake
        slots[3] = bytes32(uint256(3)); // _initialized
        _snapshotStorage(SystemAddresses.STAKE_CONFIG, slots);

        _applyHardfork(HardforkRegistry.gamma());

        _verifyStoragePreserved();
        assertTrue(stakingConfig.isInitialized(), "still initialized");
        assertFalse(stakingConfig.hasPendingConfig(), "no pending config initially");
    }

    function test_migration_stakingConfigPendingConfigWorks() public {
        _applyHardfork(HardforkRegistry.gamma());

        uint256 newMinStake = 5 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(newMinStake, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
        assertTrue(stakingConfig.hasPendingConfig(), "pending config set");

        _completeEpochTransition();
        assertEq(stakingConfig.minimumStake(), newMinStake, "new config applied");
        assertFalse(stakingConfig.hasPendingConfig(), "pending cleared");
    }

    function test_migration_stakePoolWithdrawRewards() public {
        _applyHardfork(HardforkRegistry.gamma());

        uint256 activeStake = IStakePool(pool1).getActiveStake();
        uint256 rewardAmount = 3 ether;
        vm.deal(pool1, activeStake + rewardAmount);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool1).withdrawRewards(alice);
        assertEq(alice.balance, aliceBefore + rewardAmount, "rewards withdrawn");
    }

    function test_migration_stakePoolReceiveRemoved() public {
        _applyHardfork(HardforkRegistry.gamma());

        vm.prank(charlie);
        (bool success,) = pool1.call{ value: 1 ether }("");
        assertFalse(success, "plain ETH should revert");
    }

    function test_migration_nativeOracleSequentialNonce() public {
        _applyHardfork(HardforkRegistry.gamma());

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.record(1, 100, 1, block.number, hex"aabb", 0);

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSelector(Errors.NonceNotSequential.selector, 1, 100, 2, 3));
        nativeOracle.record(1, 100, 3, block.number, hex"ccdd", 0);

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        nativeOracle.record(1, 100, 2, block.number, hex"ccdd", 0);
        assertEq(nativeOracle.getLatestNonce(1, 100), 2, "nonce should be 2");
    }

    function test_migration_validatorJoinAfterHardfork() public {
        _applyHardfork(HardforkRegistry.gamma());

        address pool3 = _createRegisterAndJoin(charlie, MIN_BOND, "charlie");
        _completeEpochTransition();
        assertEq(validatorManager.getActiveValidatorCount(), 3, "3 validators after join");
    }

    function test_migration_multipleEpochs() public {
        _applyHardfork(HardforkRegistry.gamma());
        for (uint256 i = 0; i < 5; i++) {
            _completeEpochTransition();
        }
        assertEq(reconfig.currentEpoch(), 7, "epoch 7 (2 + 5)");
    }

    function test_migration_fullLifecycleIntegration() public {
        assertEq(reconfig.currentEpoch(), 2, "start at epoch 2");

        _applyHardfork(HardforkRegistry.gamma());

        vm.prank(alice);
        IStakePool(pool1).addStake{ value: 5 ether }();

        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(2 ether, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);

        address pool3 = _createRegisterAndJoin(charlie, MIN_BOND, "charlie");

        _completeEpochTransition();

        assertEq(reconfig.currentEpoch(), 3, "epoch 3");
        assertEq(stakingConfig.minimumStake(), 2 ether, "config applied");
        assertEq(validatorManager.getActiveValidatorCount(), 3, "3 validators");
        assertEq(IStakePool(pool1).getActiveStake(), MIN_BOND * 3 + 5 ether, "stake increased");
    }
}
