// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Blocker } from "../../../src/blocker/Blocker.sol";
import { Reconfiguration } from "../../../src/blocker/Reconfiguration.sol";
import { IReconfiguration } from "../../../src/blocker/IReconfiguration.sol";
import { ValidatorManagement } from "../../../src/staking/ValidatorManagement.sol";
import { IValidatorManagement } from "../../../src/staking/IValidatorManagement.sol";
import { Staking } from "../../../src/staking/Staking.sol";
import { IStakePool } from "../../../src/staking/IStakePool.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { DKG } from "../../../src/runtime/DKG.sol";
import { IDKG } from "../../../src/runtime/IDKG.sol";
import { RandomnessConfig } from "../../../src/runtime/RandomnessConfig.sol";
import { EpochConfig } from "../../../src/runtime/EpochConfig.sol";
import { StakingConfig } from "../../../src/runtime/StakingConfig.sol";
import { ValidatorConfig } from "../../../src/runtime/ValidatorConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorConsensusInfo, ValidatorStatus } from "../../../src/foundation/Types.sol";

/// @title ConsensusEngineFlowTest
/// @notice Integration tests simulating consensus engine interaction with reconfiguration
/// @dev Based on Aptos's block.move and reconfiguration_with_dkg.move patterns
///
/// Aptos Invariants Tested (from stake.spec.move):
/// 1. ValidatorNotChangeDuringReconfig: Validator set should not change during reconfiguration
/// 2. StakePoolNotChangeDuringReconfig: Stake pools should not change during reconfiguration
/// 3. on_new_epoch should never abort and always complete successfully
/// 4. Proper handling of pending_active and pending_inactive validators
/// 5. Fresh index assignment for next epoch validators
contract ConsensusEngineFlowTest is Test {
    Blocker public blocker;
    Reconfiguration public reconfig;
    ValidatorManagement public validatorManager;
    Staking public staking;
    Timestamp public timestamp;
    DKG public dkg;
    RandomnessConfig public randomnessConfig;
    EpochConfig public epochConfig;
    StakingConfig public stakingConfig;
    ValidatorConfig public validatorConfig;

    // Test addresses
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");

    // Test constants
    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant TWO_HOURS = 7_200_000_000; // 2 hours in microseconds
    uint64 constant ONE_HOUR = 3_600_000_000;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000;
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000;
    uint256 constant MIN_STAKE = 1 ether;
    uint256 constant MIN_BOND = 10 ether;
    uint256 constant MAX_BOND = 1000 ether;
    uint64 constant VOTING_POWER_INCREASE_LIMIT = 20;
    uint256 constant MAX_VALIDATOR_SET_SIZE = 100;

    // Sample consensus key data
    bytes constant CONSENSUS_PUBKEY = hex"1234567890abcdef";
    bytes constant CONSENSUS_POP = hex"abcdef1234567890";
    bytes constant NETWORK_ADDRESSES = hex"0102030405060708";
    bytes constant FULLNODE_ADDRESSES = hex"0807060504030201";
    bytes constant SAMPLE_DKG_TRANSCRIPT = hex"deadbeef1234567890abcdef";

    // Events
    event EpochTransitionStarted(uint64 indexed epoch);
    event EpochTransitioned(uint64 indexed newEpoch, uint64 transitionTime);
    event DKGStartEvent(
        uint64 indexed sessionEpoch,
        RandomnessConfig.RandomnessConfigData config,
        ValidatorConsensusInfo[] dealerValidatorSet,
        ValidatorConsensusInfo[] targetValidatorSet
    );

    function setUp() public {
        // Deploy and etch all contracts at system addresses
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        validatorConfig = ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);
        validatorManager = ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);

        vm.etch(SystemAddresses.DKG, address(new DKG()).code);
        dkg = DKG(SystemAddresses.DKG);

        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(new RandomnessConfig()).code);
        randomnessConfig = RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG);

        vm.etch(SystemAddresses.EPOCH_CONFIG, address(new EpochConfig()).code);
        epochConfig = EpochConfig(SystemAddresses.EPOCH_CONFIG);

        vm.etch(SystemAddresses.RECONFIGURATION, address(new Reconfiguration()).code);
        reconfig = Reconfiguration(SystemAddresses.RECONFIGURATION);

        vm.etch(SystemAddresses.BLOCK, address(new Blocker()).code);
        blocker = Blocker(SystemAddresses.BLOCK);

        // Initialize configs
        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 10 ether);

        vm.prank(SystemAddresses.GENESIS);
        validatorConfig.initialize(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE
        );

        vm.prank(SystemAddresses.GENESIS);
        epochConfig.initialize(TWO_HOURS);

        vm.prank(SystemAddresses.GENESIS);
        randomnessConfig.initialize(_createV2Config());

        // Set initial timestamp BEFORE reconfig initialization
        // so lastReconfigurationTime is set correctly
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIME);

        vm.prank(SystemAddresses.GENESIS);
        reconfig.initialize();

        // Fund test accounts
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(charlie, 10000 ether);
        vm.deal(david, 10000 ether);
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _createV2Config() internal pure returns (RandomnessConfig.RandomnessConfigData memory) {
        uint64 half = uint64(1) << 63;
        uint64 twoThirds = uint64((uint256(1) << 64) * 2 / 3);
        return RandomnessConfig.RandomnessConfigData({
            variant: RandomnessConfig.ConfigVariant.V2,
            configV2: RandomnessConfig.ConfigV2Data({
                secrecyThreshold: half, reconstructionThreshold: twoThirds, fastPathSecrecyThreshold: twoThirds
            })
        });
    }

    function _createStakePool(
        address owner,
        uint256 stakeAmount
    ) internal returns (address pool) {
        uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION;
        vm.prank(owner);
        pool = staking.createPool{ value: stakeAmount }(owner, owner, owner, owner, lockedUntil);
    }

    function _createAndRegisterValidator(
        address owner,
        uint256 stakeAmount,
        string memory moniker
    ) internal returns (address pool) {
        pool = _createStakePool(owner, stakeAmount);
        vm.prank(owner);
        validatorManager.registerValidator(
            pool, moniker, CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function _createRegisterAndJoin(
        address owner,
        uint256 stakeAmount,
        string memory moniker
    ) internal returns (address pool) {
        pool = _createAndRegisterValidator(owner, stakeAmount, moniker);
        vm.prank(owner);
        validatorManager.joinValidatorSet(pool);
    }

    function _advanceTime(
        uint64 micros
    ) internal {
        uint64 currentTime = timestamp.nowMicroseconds();
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, currentTime + micros);
    }

    /// @notice Simulate a block being processed by the consensus engine
    /// @dev Mirrors Aptos's block_prologue_ext pattern
    function _simulateBlockPrologue() internal returns (bool epochTransitionStarted) {
        vm.prank(SystemAddresses.BLOCK);
        return reconfig.checkAndStartTransition();
    }

    /// @notice Simulate consensus engine completing DKG and finishing reconfiguration
    /// @dev Mirrors Aptos's reconfiguration_with_dkg::finish pattern
    function _simulateFinishReconfiguration(
        bytes memory dkgTranscript
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        reconfig.finishTransition(dkgTranscript);
    }

    function _processEpoch() internal {
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorManager.onNewEpoch();
    }

    // ========================================================================
    // CONSENSUS ENGINE SIMULATION TESTS
    // ========================================================================

    /// @notice Test full epoch lifecycle as seen by consensus engine
    /// @dev Simulates: blocks → epoch timeout → DKG start → DKG complete → new epoch
    function test_consensusEngine_fullEpochLifecycle() public {
        // Setup: Register and activate initial validators
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND * 2, "bob");
        _processEpoch(); // Activate validators

        // Verify initial state (epoch 0 → epoch 1 in validatorManager)
        assertEq(validatorManager.getActiveValidatorCount(), 2, "Should have 2 active validators");
        assertEq(reconfig.currentEpoch(), 0, "Reconfiguration should be at epoch 0");

        // Simulate blocks during epoch (no transition)
        for (uint256 i = 0; i < 5; i++) {
            _advanceTime(ONE_HOUR / 10);
            bool started = _simulateBlockPrologue();
            assertFalse(started, "Should not start transition within epoch");
        }

        // Advance past epoch interval
        _advanceTime(TWO_HOURS);

        // Simulate block that triggers epoch transition
        bool transitionStarted = _simulateBlockPrologue();
        assertTrue(transitionStarted, "Should start transition when epoch timeout");
        assertTrue(reconfig.isTransitionInProgress(), "Transition should be in progress");

        // Verify DKG session was started
        (bool hasSession, IDKG.DKGSessionInfo memory sessionInfo) = dkg.getIncompleteSession();
        assertTrue(hasSession, "Should have in-progress DKG session");
        assertEq(sessionInfo.dealerEpoch, 0, "DKG session epoch should match");
        assertEq(sessionInfo.dealerCount, 2, "Should have 2 dealers");
        assertEq(sessionInfo.targetCount, 2, "Should have 2 targets");

        // Simulate consensus engine completing DKG
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);

        // Verify new epoch
        assertEq(reconfig.currentEpoch(), 1, "Should be at epoch 1");
        assertFalse(reconfig.isTransitionInProgress(), "Transition should be complete");
    }

    /// @notice Test Aptos invariant: ValidatorNotChangeDuringReconfig
    /// @dev Validator set should not change while reconfiguration is in progress
    function test_invariant_validatorSetFrozenDuringReconfig() public {
        // Setup validators
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Start reconfiguration
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        assertTrue(reconfig.isTransitionInProgress(), "Should be in reconfiguration");

        // Capture validator set before
        ValidatorConsensusInfo[] memory validatorsBefore = validatorManager.getActiveValidators();

        // Try to join during reconfiguration - should revert
        address pool3 = _createAndRegisterValidator(charlie, MIN_BOND, "charlie");
        vm.prank(charlie);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        validatorManager.joinValidatorSet(pool3);

        // Try to leave during reconfiguration - should revert
        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        validatorManager.leaveValidatorSet(pool1);

        // Validator set should be unchanged
        ValidatorConsensusInfo[] memory validatorsAfter = validatorManager.getActiveValidators();
        assertEq(validatorsBefore.length, validatorsAfter.length, "Validator set should not change during reconfig");
    }

    /// @notice Test Aptos invariant: StakePoolNotChangeDuringReconfig
    /// @dev Stake pools should not be modified during reconfiguration
    function test_invariant_stakePoolFrozenDuringReconfig() public {
        // Setup validator
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND * 2, "alice");
        _processEpoch();

        // Start reconfiguration
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        assertTrue(reconfig.isTransitionInProgress(), "Should be in reconfiguration");

        // Capture stake before
        uint256 activeStakeBefore = IStakePool(pool1).getActiveStake();

        // Try to add stake during reconfiguration - should revert
        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool1).addStake{ value: 1 ether }();

        // Try to unstake during reconfiguration - should revert
        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool1).unstake(1 ether);

        // Stake should be unchanged
        uint256 activeStakeAfter = IStakePool(pool1).getActiveStake();
        assertEq(activeStakeBefore, activeStakeAfter, "Stake should not change during reconfig");
    }

    /// @notice Test Aptos invariant: on_new_epoch should never abort
    /// @dev Epoch transition must complete successfully even with complex validator changes
    function test_invariant_onNewEpochNeverAborts() public {
        // Setup complex validator state
        // Note: Voting power increase limit is 20%, so after Alice leaves (total becomes 50 ether),
        // David can only join with max 10 ether (20% of 50). We use MIN_BOND (10 ether) for David.
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND * 2, "bob"); // 20 ether
        _createRegisterAndJoin(charlie, MIN_BOND * 3, "charlie"); // 30 ether
        _processEpoch();

        // Alice leaves (pending_inactive)
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        // David joins with MIN_BOND (10 ether) to stay within 20% voting power limit
        // Total after Alice leaves = 50 ether, 20% max increase = 10 ether
        address pool4 = _createAndRegisterValidator(david, MIN_BOND, "david");
        vm.prank(david);
        validatorManager.joinValidatorSet(pool4);

        // Start reconfiguration
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();

        // Complete reconfiguration - should never revert
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);

        // Verify epoch completed
        assertEq(reconfig.currentEpoch(), 1, "Epoch should advance");

        // Verify validator changes applied
        assertEq(
            uint8(validatorManager.getValidatorStatus(pool1)),
            uint8(ValidatorStatus.INACTIVE),
            "Alice should be inactive"
        );
        assertEq(
            uint8(validatorManager.getValidatorStatus(pool4)), uint8(ValidatorStatus.ACTIVE), "David should be active"
        );
    }

    /// @notice Test that DKG dealers and targets differ when validators are joining/leaving
    /// @dev Dealers = current validators (including pending_inactive)
    ///      Targets = next epoch validators (excluding pending_inactive, including pending_active)
    function test_dkgDealersAndTargetsDiffer() public {
        // Setup initial validators
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND * 2, "bob");
        _createRegisterAndJoin(charlie, MIN_BOND * 3, "charlie");
        _processEpoch();

        // Bob leaves (will be in dealers but not targets)
        vm.prank(bob);
        validatorManager.leaveValidatorSet(pool2);

        // David joins (will be in targets but not dealers)
        address pool4 = _createAndRegisterValidator(david, MIN_BOND * 4, "david");
        vm.prank(david);
        validatorManager.joinValidatorSet(pool4);

        // Get cur (dealers) and next (targets) before DKG starts
        ValidatorConsensusInfo[] memory dealers = validatorManager.getCurValidatorConsensusInfos();
        ValidatorConsensusInfo[] memory targets = validatorManager.getNextValidatorConsensusInfos();

        // Dealers should include bob (pending_inactive)
        assertEq(dealers.length, 3, "Dealers should have 3 validators (including pending_inactive)");
        bool bobInDealers = false;
        for (uint256 i = 0; i < dealers.length; i++) {
            if (dealers[i].validator == pool2) bobInDealers = true;
        }
        assertTrue(bobInDealers, "Bob (pending_inactive) should be in dealers");

        // Targets should exclude bob but include david
        assertEq(targets.length, 3, "Targets should have 3 validators (alice, charlie, david)");
        bool bobInTargets = false;
        bool davidInTargets = false;
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].validator == pool2) bobInTargets = true;
            if (targets[i].validator == pool4) davidInTargets = true;
        }
        assertFalse(bobInTargets, "Bob should NOT be in targets (leaving)");
        assertTrue(davidInTargets, "David should be in targets (joining)");

        // Start reconfiguration and verify DKG uses correct sets
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();

        (bool hasSession, IDKG.DKGSessionInfo memory sessionInfo) = dkg.getIncompleteSession();
        assertTrue(hasSession, "Should have in-progress DKG session");
        assertEq(sessionInfo.dealerCount, 3, "DKG dealers should be 3");
        assertEq(sessionInfo.targetCount, 3, "DKG targets should be 3");
    }

    /// @notice Test that target validators get fresh indices (0, 1, 2, ...)
    /// @dev This is critical for DKG - indices must be contiguous from 0
    function test_targetValidatorsGetFreshIndices() public {
        // Setup 4 validators with various indices
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        address pool3 = _createRegisterAndJoin(charlie, MIN_BOND, "charlie");
        address pool4 = _createRegisterAndJoin(david, MIN_BOND, "david");
        _processEpoch();

        // Validators bob and david leave
        vm.prank(bob);
        validatorManager.leaveValidatorSet(pool2);
        vm.prank(david);
        validatorManager.leaveValidatorSet(pool4);

        // Get next validators (targets)
        ValidatorConsensusInfo[] memory targets = validatorManager.getNextValidatorConsensusInfos();

        // Should have 2 validators (alice, charlie)
        assertEq(targets.length, 2, "Should have 2 targets");

        // Indices should be 0 and 1 (implicit in array position)
        // The important thing is that the array is contiguous from index 0
        // Note: pool1=alice, pool3=charlie are the remaining validators
        address alicePool = pool1;
        address charliePool = pool3;
        assertTrue(
            targets[0].validator == alicePool || targets[0].validator == charliePool,
            "Index 0 should be alice or charlie"
        );
        assertTrue(
            targets[1].validator == alicePool || targets[1].validator == charliePool,
            "Index 1 should be alice or charlie"
        );
        assertTrue(targets[0].validator != targets[1].validator, "Should be different validators");
    }

    /// @notice Test multiple epoch transitions maintain consistency
    function test_multipleEpochTransitions() public {
        // Setup initial validators (2 validators with equal stake)
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Run through 5 epochs
        for (uint64 epoch = 0; epoch < 5; epoch++) {
            assertEq(reconfig.currentEpoch(), epoch, "Should be at correct epoch");

            // Advance time and trigger transition
            _advanceTime(TWO_HOURS + 1);
            bool started = _simulateBlockPrologue();
            assertTrue(started, "Should start transition");

            // Complete transition
            _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);

            assertEq(reconfig.currentEpoch(), epoch + 1, "Should advance to next epoch");
        }
    }

    /// @notice Test that operations resume after reconfiguration completes
    function test_operationsResumeAfterReconfiguration() public {
        // Setup validator
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND * 2, "alice");
        _processEpoch();

        // Start and complete reconfiguration
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);

        // Operations should work again
        vm.prank(alice);
        IStakePool(pool1).addStake{ value: 1 ether }();
        assertEq(IStakePool(pool1).getActiveStake(), MIN_BOND * 2 + 1 ether, "Add stake should work");

        // New validator can join
        address pool2 = _createAndRegisterValidator(bob, MIN_BOND, "bob");
        vm.prank(bob);
        validatorManager.joinValidatorSet(pool2);
        assertEq(
            uint8(validatorManager.getValidatorStatus(pool2)), uint8(ValidatorStatus.PENDING_ACTIVE), "Join should work"
        );
    }

    /// @notice Test governance force-end of reconfiguration
    /// @dev GOVERNANCE can call finishTransition to force-end stuck DKG
    function test_governanceCanForceEndReconfiguration() public {
        // Setup and start reconfiguration
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch();

        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        assertTrue(reconfig.isTransitionInProgress(), "Should be in reconfiguration");

        // Governance can force-end without DKG result
        vm.prank(SystemAddresses.GOVERNANCE);
        reconfig.finishTransition(""); // Empty DKG result

        assertFalse(reconfig.isTransitionInProgress(), "Reconfiguration should end");
        assertEq(reconfig.currentEpoch(), 1, "Epoch should advance");
    }

    /// @notice Test consensus engine behavior with NIL blocks (empty blocks)
    /// @dev NIL blocks don't have a proposer but still need to check for epoch transition
    function test_nilBlockStillChecksEpochTransition() public {
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch();

        // Advance past epoch interval
        _advanceTime(TWO_HOURS + 1);

        // Even NIL blocks should trigger epoch check
        // (In production, NIL blocks have proposer = vm_reserved)
        bool started = _simulateBlockPrologue();
        assertTrue(started, "NIL block should still trigger epoch transition");
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    /// @notice Fuzz test: Epoch transitions with varying number of validators
    function testFuzz_epochTransitionWithVaryingValidators(
        uint8 numValidators
    ) public {
        numValidators = uint8(bound(numValidators, 1, 10));

        // Create validators
        address[] memory pools = new address[](numValidators);
        for (uint256 i = 0; i < numValidators; i++) {
            address user = address(uint160(0x1000 + i));
            vm.deal(user, 1000 ether);
            pools[i] = _createRegisterAndJoin(user, MIN_BOND + i * 1 ether, "validator");
        }
        _processEpoch();

        assertEq(validatorManager.getActiveValidatorCount(), numValidators, "All validators should be active");

        // Complete an epoch transition
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);

        assertEq(reconfig.currentEpoch(), 1, "Should complete epoch transition");
        assertEq(validatorManager.getActiveValidatorCount(), numValidators, "Validator count should be preserved");
    }

    /// @notice Fuzz test: Validators joining and leaving across epochs
    function testFuzz_validatorChurnAcrossEpochs(
        uint256 seed
    ) public {
        // Initial setup with 2 validators
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND * 2, "alice");
        _createRegisterAndJoin(bob, MIN_BOND * 2, "bob");
        _processEpoch();

        // Simulate 3 epochs with random churn
        for (uint256 epoch = 0; epoch < 3; epoch++) {
            uint256 activeCount = validatorManager.getActiveValidatorCount();

            // Maybe have someone leave (if more than 1 validator)
            if (activeCount > 1 && (seed >> epoch) & 1 == 1) {
                // Check status first, then prank for the actual call
                if (validatorManager.getValidatorStatus(pool1) == ValidatorStatus.ACTIVE) {
                    vm.prank(alice);
                    validatorManager.leaveValidatorSet(pool1);
                }
            }

            // Complete epoch
            _advanceTime(TWO_HOURS + 1);
            _simulateBlockPrologue();
            _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);
        }

        // Should have completed all epochs without reverting
        assertEq(reconfig.currentEpoch(), 3, "Should complete 3 epochs");
    }
}

