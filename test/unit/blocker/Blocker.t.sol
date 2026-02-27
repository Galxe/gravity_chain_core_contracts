// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Blocker } from "../../../src/blocker/Blocker.sol";
import { Reconfiguration } from "../../../src/blocker/Reconfiguration.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { DKG } from "../../../src/runtime/DKG.sol";
import { RandomnessConfig } from "../../../src/runtime/RandomnessConfig.sol";
import { EpochConfig } from "../../../src/runtime/EpochConfig.sol";
import { ConsensusConfig } from "../../../src/runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "../../../src/runtime/ExecutionConfig.sol";
import { ValidatorConfig } from "../../../src/runtime/ValidatorConfig.sol";
import { VersionConfig } from "../../../src/runtime/VersionConfig.sol";
import { GovernanceConfig } from "../../../src/runtime/GovernanceConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorConsensusInfo } from "../../../src/foundation/Types.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";
import { ValidatorPerformanceTracker } from "../../../src/blocker/ValidatorPerformanceTracker.sol";

/// @notice Mock ValidatorManagement for testing
contract MockValidatorManagementBlocker {
    uint64 public currentEpoch;
    ValidatorConsensusInfo[] private _validators;

    function setValidators(
        ValidatorConsensusInfo[] memory validators
    ) external {
        delete _validators;
        for (uint256 i = 0; i < validators.length; i++) {
            _validators.push(validators[i]);
        }
    }

    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        return _validators;
    }

    /// @notice Get current validators for DKG dealers
    function getCurValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory) {
        return _validators;
    }

    /// @notice Get projected next epoch validators for DKG targets
    function getNextValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory) {
        return _validators;
    }

    function getActiveValidatorByIndex(
        uint64 index
    ) external view returns (ValidatorConsensusInfo memory) {
        require(index < _validators.length, "Index out of bounds");
        return _validators[index];
    }

    /// @notice Get total voting power of active validators
    function getTotalVotingPower() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < _validators.length; i++) {
            total += _validators[i].votingPower;
        }
        return total;
    }

    function onNewEpoch() external {
        currentEpoch++;
    }

    function getCurrentEpoch() external view returns (uint64) {
        return currentEpoch;
    }

    function getActiveValidatorCount() external view returns (uint256) {
        return _validators.length;
    }

    function evictUnderperformingValidators() external {
        // no-op for testing
    }
}

/// @title BlockerTest
/// @notice Unit tests for Blocker contract
contract BlockerTest is Test {
    Blocker public blocker;
    Reconfiguration public reconfig;
    Timestamp public timestamp;
    DKG public dkg;
    RandomnessConfig public randomnessConfig;
    EpochConfig public epochConfig;
    MockValidatorManagementBlocker public validatorManagement;

    // Common test values
    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant ONE_HOUR = 3_600_000_000;
    uint64 constant TWO_HOURS = 7_200_000_000;
    uint64 constant PROPOSER_INDEX = 0; // Index into validator set
    uint64 constant NIL_PROPOSER_INDEX = type(uint64).max; // NIL block indicator

    // Events to test
    event BlockStarted(uint256 indexed blockHeight, uint64 indexed epoch, address proposer, uint64 timestampMicros);

    function setUp() public {
        // Deploy contracts
        blocker = new Blocker();
        reconfig = new Reconfiguration();
        timestamp = new Timestamp();
        dkg = new DKG();
        randomnessConfig = new RandomnessConfig();
        epochConfig = new EpochConfig();
        validatorManagement = new MockValidatorManagementBlocker();

        // Deploy at system addresses
        vm.etch(SystemAddresses.BLOCK, address(blocker).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(reconfig).code);
        vm.etch(SystemAddresses.TIMESTAMP, address(timestamp).code);
        vm.etch(SystemAddresses.DKG, address(dkg).code);
        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(randomnessConfig).code);
        vm.etch(SystemAddresses.EPOCH_CONFIG, address(epochConfig).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(validatorManagement).code);

        // Deploy ValidatorPerformanceTracker
        vm.etch(SystemAddresses.PERFORMANCE_TRACKER, address(new ValidatorPerformanceTracker()).code);

        // Initialize EpochConfig
        vm.prank(SystemAddresses.GENESIS);
        EpochConfig(SystemAddresses.EPOCH_CONFIG).initialize(TWO_HOURS);

        // Initialize RandomnessConfig
        vm.prank(SystemAddresses.GENESIS);
        RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).initialize(_createV2Config());

        // Deploy and initialize additional config contracts
        vm.etch(SystemAddresses.CONSENSUS_CONFIG, address(new ConsensusConfig()).code);
        vm.etch(SystemAddresses.EXECUTION_CONFIG, address(new ExecutionConfig()).code);
        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        vm.etch(SystemAddresses.VERSION_CONFIG, address(new VersionConfig()).code);
        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);

        // Initialize ConsensusConfig
        vm.prank(SystemAddresses.GENESIS);
        ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG).initialize(hex"deadbeef");

        // Initialize ExecutionConfig
        vm.prank(SystemAddresses.GENESIS);
        ExecutionConfig(SystemAddresses.EXECUTION_CONFIG).initialize(hex"cafebabe");

        // Initialize ValidatorConfig
        vm.prank(SystemAddresses.GENESIS);
        ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG)
            .initialize(
                10 ether, // minimumBond
                1000 ether, // maximumBond
                7 days * 1_000_000, // unbondingDelayMicros
                true, // allowValidatorSetChange
                20, // votingPowerIncreaseLimitPct
                100, // maxValidatorSetSize
                false, // autoEvictEnabled
                0 // autoEvictThreshold
            );

        // Initialize VersionConfig
        vm.prank(SystemAddresses.GENESIS);
        VersionConfig(SystemAddresses.VERSION_CONFIG).initialize(1);

        // Initialize GovernanceConfig
        vm.prank(SystemAddresses.GENESIS);
        GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG)
            .initialize(
                1000 ether, // minVotingThreshold
                100 ether, // requiredProposerStake
                7 days * 1_000_000 // votingDurationMicros
            );

        // Setup mock validators
        MockValidatorManagementBlocker(SystemAddresses.VALIDATOR_MANAGER).setValidators(_createValidators(3));

        // Initialize ValidatorPerformanceTracker
        vm.prank(SystemAddresses.GENESIS);
        ValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER).initialize(3);
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

    function _createValidators(
        uint256 count
    ) internal pure returns (ValidatorConsensusInfo[] memory) {
        ValidatorConsensusInfo[] memory validators = new ValidatorConsensusInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            validators[i] = ValidatorConsensusInfo({
                validator: address(uint160(i + 1)),
                consensusPubkey: abi.encodePacked("pubkey", i),
                consensusPop: abi.encodePacked("pop", i),
                votingPower: 100 * (i + 1),
                validatorIndex: uint64(i),
                networkAddresses: abi.encodePacked("network", i),
                fullnodeAddresses: abi.encodePacked("fullnode", i)
            });
        }
        return validators;
    }

    function _initializeBlocker() internal {
        vm.prank(SystemAddresses.GENESIS);
        Blocker(SystemAddresses.BLOCK).initialize();
    }

    function _initializeReconfiguration() internal {
        vm.prank(SystemAddresses.GENESIS);
        Reconfiguration(SystemAddresses.RECONFIGURATION).initialize();
    }

    function _initializeAll() internal {
        _initializeBlocker();
        _initializeReconfiguration();
    }

    function _callOnBlockStart(
        uint64 proposerIndex,
        uint64 timestampMicros
    ) internal {
        uint64[] memory failedProposerIndices = new uint64[](0);
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Blocker(SystemAddresses.BLOCK).onBlockStart(proposerIndex, failedProposerIndices, timestampMicros);
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_initialize_success() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(true, true, false, true);
        emit BlockStarted(0, 0, SystemAddresses.SYSTEM_CALLER, 0); // Genesis block emits epoch 0
        Blocker(SystemAddresses.BLOCK).initialize();

        assertTrue(Blocker(SystemAddresses.BLOCK).isInitialized());
        // Check timestamp was initialized to 0
        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), 0);
    }

    function test_RevertWhen_initialize_notGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        Blocker(SystemAddresses.BLOCK).initialize();
    }

    function test_RevertWhen_initialize_alreadyInitialized() public {
        _initializeBlocker();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        Blocker(SystemAddresses.BLOCK).initialize();
    }

    // ========================================================================
    // ON BLOCK START TESTS
    // ========================================================================

    function test_onBlockStart_normalBlock() public {
        _initializeAll();

        uint64 newTimestamp = INITIAL_TIME + 1_000_000; // 1 second later

        // Get expected proposer address from validator at index 0
        ValidatorConsensusInfo memory validator =
            MockValidatorManagementBlocker(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorByIndex(PROPOSER_INDEX);

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, true, false, true);
        emit BlockStarted(block.number, 1, validator.validator, newTimestamp);

        uint64[] memory failedProposerIndices = new uint64[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_INDEX, failedProposerIndices, newTimestamp);

        // Check timestamp was updated
        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), newTimestamp);
    }

    function test_onBlockStart_nilBlock() public {
        _initializeAll();

        // For NIL blocks, timestamp must stay the same
        uint64 currentTime = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, true, false, true);
        emit BlockStarted(block.number, 1, SystemAddresses.SYSTEM_CALLER, currentTime);

        uint64[] memory failedProposerIndices = new uint64[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(NIL_PROPOSER_INDEX, failedProposerIndices, currentTime);

        // Timestamp should stay the same for NIL block
        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), currentTime);
    }

    function test_onBlockStart_triggersEpochTransition_whenTimeElapsed() public {
        _initializeAll();

        // Advance time past epoch interval (2 hours)
        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + TWO_HOURS + 1;

        // Call onBlockStart which should trigger epoch transition
        _callOnBlockStart(PROPOSER_INDEX, newTimestamp);

        // Check that epoch transition started
        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());
    }

    function test_onBlockStart_noTransition_whenTimeNotElapsed() public {
        _initializeAll();

        // Advance time but not past epoch interval
        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + ONE_HOUR;

        _callOnBlockStart(PROPOSER_INDEX, newTimestamp);

        // Transition should not have started
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());
    }

    function test_RevertWhen_onBlockStart_notSystemCaller() public {
        _initializeAll();

        address notSystemCaller = address(0x1234);
        uint64[] memory failedProposerIndices = new uint64[](0);

        vm.prank(notSystemCaller);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notSystemCaller, SystemAddresses.SYSTEM_CALLER));
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_INDEX, failedProposerIndices, INITIAL_TIME + 1);
    }

    function test_onBlockStart_withFailedProposers() public {
        _initializeAll();

        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;

        uint64[] memory failedProposerIndices = new uint64[](2);
        failedProposerIndices[0] = 1;
        failedProposerIndices[1] = 2;

        // Should succeed even with failed proposers (they're currently unused)
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_INDEX, failedProposerIndices, newTimestamp);

        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), newTimestamp);
    }

    // ========================================================================
    // PROPOSER RESOLUTION TESTS
    // ========================================================================

    function test_proposerResolution_nilBlock() public {
        _initializeAll();

        uint64 currentTime = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // NIL block (NIL_PROPOSER_INDEX) should resolve to SYSTEM_CALLER
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, false, false, true);
        emit BlockStarted(block.number, 1, SystemAddresses.SYSTEM_CALLER, currentTime);

        uint64[] memory failedProposerIndices = new uint64[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(NIL_PROPOSER_INDEX, failedProposerIndices, currentTime);
    }

    function test_proposerResolution_normalBlock() public {
        _initializeAll();

        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;

        // Normal block should resolve proposer index to validator address
        ValidatorConsensusInfo memory validator =
            MockValidatorManagementBlocker(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorByIndex(PROPOSER_INDEX);

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, false, false, true);
        emit BlockStarted(block.number, 1, validator.validator, newTimestamp);

        uint64[] memory failedProposerIndices = new uint64[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_INDEX, failedProposerIndices, newTimestamp);
    }

    function test_proposerResolution_differentIndices() public {
        _initializeAll();

        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;

        // Test different validator indices
        for (uint64 i = 0; i < 3; i++) {
            ValidatorConsensusInfo memory validator =
                MockValidatorManagementBlocker(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorByIndex(i);

            vm.prank(SystemAddresses.SYSTEM_CALLER);
            vm.expectEmit(false, false, false, true);
            emit BlockStarted(block.number, 1, validator.validator, newTimestamp);

            uint64[] memory failedProposerIndices = new uint64[](0);
            Blocker(SystemAddresses.BLOCK).onBlockStart(i, failedProposerIndices, newTimestamp);

            newTimestamp += 1_000_000;
        }
    }

    // ========================================================================
    // INTEGRATION WITH RECONFIGURATION TESTS
    // ========================================================================

    function test_fullBlockFlow_withEpochTransition() public {
        _initializeAll();

        // Block 1: Normal block, no transition
        uint64 timestamp1 = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;
        _callOnBlockStart(PROPOSER_INDEX, timestamp1);

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        // Block 2: After epoch interval, transition starts
        uint64 timestamp2 = timestamp1 + TWO_HOURS;
        _callOnBlockStart(PROPOSER_INDEX, timestamp2);

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        // Finish transition manually (normally consensus engine does this)
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Reconfiguration(SystemAddresses.RECONFIGURATION).finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 2);

        // Block 3: After transition, new epoch
        uint64 timestamp3 = timestamp2 + 1_000_000;
        _callOnBlockStart(PROPOSER_INDEX, timestamp3);

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 2);
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());
    }

    function test_multipleBlocksWithoutTransition() public {
        _initializeAll();

        uint64 currentTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // Process multiple blocks without triggering transition
        for (uint256 i = 0; i < 10; i++) {
            currentTimestamp += 1_000_000; // 1 second each
            _callOnBlockStart(PROPOSER_INDEX, currentTimestamp);

            assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
            assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());
        }
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_onBlockStart_validProposerIndex(
        uint64 proposerIndex
    ) public {
        // Bound proposer index to valid range (0-2 for our 3 validators)
        proposerIndex = uint64(bound(proposerIndex, 0, 2));
        _initializeAll();

        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;
        ValidatorConsensusInfo memory validator =
            MockValidatorManagementBlocker(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorByIndex(proposerIndex);

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, false, false, true);
        emit BlockStarted(block.number, 1, validator.validator, newTimestamp);

        uint64[] memory failedProposerIndices = new uint64[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(proposerIndex, failedProposerIndices, newTimestamp);

        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), newTimestamp);
    }

    function testFuzz_onBlockStart_timestampAdvances(
        uint64 timeDelta
    ) public {
        // Use reasonable time delta (1 second to 1 day in microseconds)
        timeDelta = uint64(bound(timeDelta, 1_000_000, 86_400_000_000));
        _initializeAll();

        uint64 currentTime = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 newTimestamp = currentTime + timeDelta;

        _callOnBlockStart(PROPOSER_INDEX, newTimestamp);

        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), newTimestamp);
    }

    function testFuzz_multipleBlocksSequence(
        uint8 blockCount
    ) public {
        blockCount = uint8(bound(blockCount, 1, 50));
        _initializeAll();

        uint64 currentTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        for (uint256 i = 0; i < blockCount; i++) {
            currentTimestamp += 1_000_000; // 1 second each
            _callOnBlockStart(PROPOSER_INDEX, currentTimestamp);
        }

        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), currentTimestamp);
    }
}

