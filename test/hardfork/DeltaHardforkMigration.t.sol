// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { HardforkTestBase } from "./HardforkTestBase.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { ValidatorConsensusInfo, ValidatorStatus } from "../../src/foundation/Types.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";
import { ConsensusConfig } from "../../src/runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "../../src/runtime/ExecutionConfig.sol";
import { VersionConfig } from "../../src/runtime/VersionConfig.sol";
import { RandomnessConfig } from "../../src/runtime/RandomnessConfig.sol";

/// @title DeltaHardforkMigrationTest
/// @notice Phase A1: True pre→post hardfork migration test.
///         Uses HardforkTestBase framework:
///         1. Loads v1.2.0 runtime bytecodes from fixtures via _deployFromFixtures()
///         2. Initializes chain state using v1.2.0 code
///         3. Applies Delta hardfork via _applyDeltaMigration()
///         4. Verifies all post-hardfork functionality works correctly
contract DeltaHardforkMigrationTest is HardforkTestBase {
    address public pool1;
    address public pool2;

    function setUp() public {
        _fundTestAccounts();

        // Deploy v1.2.0 bytecodes from fixtures
        _deployFromFixtures("gravity-testnet-v1.2.0");

        // Initialize using v1.2.0 contracts
        // Note: v1.2.0 StakingConfig.initialize() takes 4 args (includes minimumProposalStake)
        //       We use a raw call to match the old ABI signature
        _initializeAllConfigsV120();
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();

        // Create 2 validators with larger stakes (for VP limit headroom)
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 3, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND * 3, "bob");

        // Process epoch to activate validators
        _processEpoch();

        // Run one epoch on v1.2.0 code to prove chain is live
        _completeEpochTransition();
    }

    /// @notice Initialize configs using v1.2.0 ABI (StakingConfig has 4-arg initialize)
    function _initializeAllConfigsV120() internal {
        vm.startPrank(SystemAddresses.GENESIS);

        // v1.2.0 StakingConfig.initialize(uint256,uint64,uint64,uint256)
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
        require(ok, "v1.2.0 StakingConfig.initialize failed");

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

    /// @notice Apply Delta hardfork (bytecode replacement only)
    /// @dev Storage gap pattern means no storage migration is needed.
    function _applyDeltaMigration() internal {
        _applyHardfork(HardforkRegistry.delta());
    }

    // ========================================================================
    // PRE-HARDFORK VERIFICATION
    // ========================================================================

    function test_preHardfork_chainIsRunning() public view {
        assertEq(validatorManager.getActiveValidatorCount(), 2, "should have 2 active validators");
        assertEq(reconfig.currentEpoch(), 2, "should be epoch 2 after one transition");
    }

    // ========================================================================
    // MIGRATION TESTS
    // ========================================================================

    function test_migration_epochTransitionAfterHardfork() public {
        uint64 epochBefore = reconfig.currentEpoch();
        _applyDeltaMigration();
        _completeEpochTransition();
        assertEq(reconfig.currentEpoch(), epochBefore + 1, "epoch should advance");
        assertEq(validatorManager.getActiveValidatorCount(), 2, "validators preserved");
    }

    function test_migration_stakingConfigStoragePreserved() public {
        // Snapshot slots 0 and 1 — with storage gap, neither changes during hardfork
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = bytes32(uint256(0)); // minimumStake
        slots[1] = bytes32(uint256(1)); // lockup|unbonding (packed)
        _snapshotStorage(SystemAddresses.STAKE_CONFIG, slots);

        _applyDeltaMigration();

        _verifyStoragePreserved();
        assertTrue(stakingConfig.isInitialized(), "still initialized");
        assertFalse(stakingConfig.hasPendingConfig(), "no pending config initially");

        // Verify lockup values are preserved
        assertEq(stakingConfig.lockupDurationMicros(), LOCKUP_DURATION, "lockup preserved");
        assertEq(stakingConfig.unbondingDelayMicros(), UNBONDING_DELAY, "unbonding preserved");
    }

    function test_migration_stakingConfigNewSignature() public {
        _applyDeltaMigration();

        // New 3-arg setForNextEpoch should work
        uint256 newMinStake = 5 ether;
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(newMinStake, LOCKUP_DURATION, UNBONDING_DELAY);
        assertTrue(stakingConfig.hasPendingConfig(), "pending config set");

        _completeEpochTransition();
        assertEq(stakingConfig.minimumStake(), newMinStake, "new config applied");
        assertFalse(stakingConfig.hasPendingConfig(), "pending cleared");
    }

    function test_migration_stakePoolWithdrawRewards() public {
        _applyDeltaMigration();

        uint256 activeStake = IStakePool(pool1).getActiveStake();
        uint256 rewardAmount = 3 ether;
        vm.deal(pool1, activeStake + rewardAmount);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool1).withdrawRewards(alice);
        assertEq(alice.balance, aliceBefore + rewardAmount, "rewards withdrawn");
    }

    function test_migration_nativeOracleSequentialNonce() public {
        _applyDeltaMigration();

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
        _applyDeltaMigration();

        address pool3 = _createRegisterAndJoin(charlie, MIN_BOND, "charlie");
        _completeEpochTransition();
        assertEq(validatorManager.getActiveValidatorCount(), 3, "3 validators after join");
    }

    function test_migration_multipleEpochs() public {
        _applyDeltaMigration();
        for (uint256 i = 0; i < 5; i++) {
            _completeEpochTransition();
        }
        assertEq(reconfig.currentEpoch(), 7, "epoch 7 (2 + 5)");
    }

    function test_migration_fullLifecycleIntegration() public {
        assertEq(reconfig.currentEpoch(), 2, "start at epoch 2");

        _applyDeltaMigration();

        vm.prank(alice);
        IStakePool(pool1).addStake{ value: 5 ether }();

        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(2 ether, LOCKUP_DURATION, UNBONDING_DELAY);

        address pool3 = _createRegisterAndJoin(charlie, MIN_BOND, "charlie");

        _completeEpochTransition();

        assertEq(reconfig.currentEpoch(), 3, "epoch 3");
        assertEq(stakingConfig.minimumStake(), 2 ether, "config applied");
        assertEq(validatorManager.getActiveValidatorCount(), 3, "3 validators");
        assertEq(IStakePool(pool1).getActiveStake(), MIN_BOND * 3 + 5 ether, "stake increased");
    }
}
