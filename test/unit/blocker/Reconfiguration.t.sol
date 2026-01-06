// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Reconfiguration } from "../../../src/blocker/Reconfiguration.sol";
import { IReconfiguration } from "../../../src/blocker/IReconfiguration.sol";
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
import { NotAllowed, NotAllowedAny } from "../../../src/foundation/SystemAccessControl.sol";

/// @notice Mock ValidatorManagement for testing
contract MockValidatorManagement {
    uint64 public currentEpoch;
    ValidatorConsensusInfo[] private _validators;
    ValidatorConsensusInfo[] private _curValidators; // dealers: current validators for DKG
    ValidatorConsensusInfo[] private _nextValidators; // targets: projected next epoch validators

    function setValidators(
        ValidatorConsensusInfo[] memory validators
    ) external {
        delete _validators;
        delete _curValidators;
        delete _nextValidators;
        for (uint256 i = 0; i < validators.length; i++) {
            _validators.push(validators[i]);
            _curValidators.push(validators[i]);
            _nextValidators.push(validators[i]);
        }
    }

    /// @notice Set dealers (current validators) and targets (next validators) separately for DKG tests
    function setDkgValidatorSets(
        ValidatorConsensusInfo[] memory dealers,
        ValidatorConsensusInfo[] memory targets
    ) external {
        delete _curValidators;
        delete _nextValidators;
        delete _validators;
        for (uint256 i = 0; i < dealers.length; i++) {
            _curValidators.push(dealers[i]);
        }
        for (uint256 i = 0; i < targets.length; i++) {
            _nextValidators.push(targets[i]);
            _validators.push(targets[i]); // Active validators = targets after transition
        }
    }

    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        return _validators;
    }

    /// @notice Get current validators for DKG dealers (active + pending_inactive)
    function getCurValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory) {
        return _curValidators;
    }

    /// @notice Get projected next epoch validators for DKG targets
    function getNextValidatorConsensusInfos() external view returns (ValidatorConsensusInfo[] memory) {
        return _nextValidators;
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
}

/// @title ReconfigurationTest
/// @notice Unit tests for Reconfiguration contract
contract ReconfigurationTest is Test {
    Reconfiguration public reconfig;
    Timestamp public timestamp;
    DKG public dkg;
    RandomnessConfig public randomnessConfig;
    EpochConfig public epochConfig;
    MockValidatorManagement public validatorManagement;

    // Common test values
    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant ONE_HOUR = 3_600_000_000;
    uint64 constant TWO_HOURS = 7_200_000_000;
    bytes constant SAMPLE_TRANSCRIPT = hex"deadbeef1234567890abcdef";

    // Events to test
    event EpochTransitionStarted(uint64 indexed epoch);
    event EpochTransitioned(uint64 indexed newEpoch, uint64 transitionTime);

    function setUp() public {
        // Deploy contracts
        reconfig = new Reconfiguration();
        timestamp = new Timestamp();
        dkg = new DKG();
        randomnessConfig = new RandomnessConfig();
        epochConfig = new EpochConfig();
        validatorManagement = new MockValidatorManagement();

        // Deploy at system addresses
        vm.etch(SystemAddresses.RECONFIGURATION, address(reconfig).code);
        vm.etch(SystemAddresses.TIMESTAMP, address(timestamp).code);
        vm.etch(SystemAddresses.DKG, address(dkg).code);
        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(randomnessConfig).code);
        vm.etch(SystemAddresses.EPOCH_CONFIG, address(epochConfig).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(validatorManagement).code);

        // Initialize Timestamp
        vm.prank(SystemAddresses.BLOCK);
        Timestamp(SystemAddresses.TIMESTAMP).updateGlobalTime(address(0x1234), INITIAL_TIME);

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
                100 // maxValidatorSetSize
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
        MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).setValidators(_createValidators(3));
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
                validatorIndex: uint64(i)
            });
        }
        return validators;
    }

    function _initializeReconfiguration() internal {
        vm.prank(SystemAddresses.GENESIS);
        Reconfiguration(SystemAddresses.RECONFIGURATION).initialize();
    }

    function _advanceTime(
        uint64 micros
    ) internal {
        uint64 currentTime = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        vm.prank(SystemAddresses.BLOCK);
        Timestamp(SystemAddresses.TIMESTAMP).updateGlobalTime(address(0x1234), currentTime + micros);
    }

    function _startTransition() internal returns (bool) {
        vm.prank(SystemAddresses.BLOCK);
        return Reconfiguration(SystemAddresses.RECONFIGURATION).checkAndStartTransition();
    }

    function _finishTransition(
        bytes memory dkgResult
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Reconfiguration(SystemAddresses.RECONFIGURATION).finishTransition(dkgResult);
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_initialize_success() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(true, false, false, true);
        emit EpochTransitioned(0, INITIAL_TIME);
        Reconfiguration(SystemAddresses.RECONFIGURATION).initialize();

        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).isInitialized());
        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 0);
        // Epoch interval is now in EpochConfig, not Reconfiguration
        assertEq(EpochConfig(SystemAddresses.EPOCH_CONFIG).epochIntervalMicros(), TWO_HOURS);
        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).lastReconfigurationTime(), INITIAL_TIME);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.RECONFIGURATION).getTransitionState()),
            uint8(IReconfiguration.TransitionState.Idle)
        );
    }

    function test_RevertWhen_initialize_notGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        Reconfiguration(SystemAddresses.RECONFIGURATION).initialize();
    }

    function test_RevertWhen_initialize_alreadyInitialized() public {
        _initializeReconfiguration();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        Reconfiguration(SystemAddresses.RECONFIGURATION).initialize();
    }

    // ========================================================================
    // CHECK AND START TRANSITION TESTS
    // ========================================================================

    function test_checkAndStartTransition_returnsfalse_whenNotReady() public {
        _initializeReconfiguration();

        // Time hasn't elapsed yet
        bool started = _startTransition();
        assertFalse(started);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.RECONFIGURATION).getTransitionState()),
            uint8(IReconfiguration.TransitionState.Idle)
        );
    }

    function test_checkAndStartTransition_startsTransition_whenTimeElapsed() public {
        _initializeReconfiguration();

        // Advance time past epoch interval
        _advanceTime(TWO_HOURS + 1);

        vm.prank(SystemAddresses.BLOCK);
        vm.expectEmit(true, false, false, false);
        emit EpochTransitionStarted(0);
        bool started = Reconfiguration(SystemAddresses.RECONFIGURATION).checkAndStartTransition();

        assertTrue(started);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.RECONFIGURATION).getTransitionState()),
            uint8(IReconfiguration.TransitionState.DkgInProgress)
        );
        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());
    }

    function test_checkAndStartTransition_returnsFalse_whenAlreadyInProgress() public {
        _initializeReconfiguration();

        // Start transition
        _advanceTime(TWO_HOURS + 1);
        bool started1 = _startTransition();
        assertTrue(started1);

        // Try to start again
        bool started2 = _startTransition();
        assertFalse(started2);
    }

    function test_RevertWhen_checkAndStartTransition_notBlock() public {
        _initializeReconfiguration();

        address notBlock = address(0x1234);
        vm.prank(notBlock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notBlock, SystemAddresses.BLOCK));
        Reconfiguration(SystemAddresses.RECONFIGURATION).checkAndStartTransition();
    }

    function test_RevertWhen_checkAndStartTransition_notInitialized() public {
        vm.prank(SystemAddresses.BLOCK);
        vm.expectRevert(Errors.ReconfigurationNotInitialized.selector);
        Reconfiguration(SystemAddresses.RECONFIGURATION).checkAndStartTransition();
    }

    // ========================================================================
    // FINISH TRANSITION TESTS
    // ========================================================================

    function test_finishTransition_success_withDkgResult() public {
        _initializeReconfiguration();

        // Start transition
        _advanceTime(TWO_HOURS + 1);
        _startTransition();

        // Advance time a bit more
        _advanceTime(ONE_HOUR);
        uint64 expectedTransitionTime = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(true, false, false, true);
        emit EpochTransitioned(1, expectedTransitionTime);
        Reconfiguration(SystemAddresses.RECONFIGURATION).finishTransition(SAMPLE_TRANSCRIPT);

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.RECONFIGURATION).getTransitionState()),
            uint8(IReconfiguration.TransitionState.Idle)
        );
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        // Check ValidatorManagement was notified and incremented its epoch
        // Note: ValidatorManagement now increments its own epoch internally
        assertEq(MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getCurrentEpoch(), 1);
    }

    function test_finishTransition_success_emptyDkgResult() public {
        _initializeReconfiguration();

        // Start transition
        _advanceTime(TWO_HOURS + 1);
        _startTransition();

        // Finish with empty DKG result (force-end)
        _finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.RECONFIGURATION).getTransitionState()),
            uint8(IReconfiguration.TransitionState.Idle)
        );
    }

    function test_finishTransition_allowedByTimelock() public {
        _initializeReconfiguration();

        // Start transition
        _advanceTime(TWO_HOURS + 1);
        _startTransition();

        // Finish via GOVERNANCE (governance force-end)
        vm.prank(SystemAddresses.GOVERNANCE);
        Reconfiguration(SystemAddresses.RECONFIGURATION).finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
    }

    function test_RevertWhen_finishTransition_notInProgress() public {
        _initializeReconfiguration();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(Errors.ReconfigurationNotInProgress.selector);
        Reconfiguration(SystemAddresses.RECONFIGURATION).finishTransition(SAMPLE_TRANSCRIPT);
    }

    function test_RevertWhen_finishTransition_notAuthorized() public {
        _initializeReconfiguration();

        // Start transition
        _advanceTime(TWO_HOURS + 1);
        _startTransition();

        address notAuthorized = address(0x1234);
        address[] memory allowed = new address[](2);
        allowed[0] = SystemAddresses.SYSTEM_CALLER;
        allowed[1] = SystemAddresses.GOVERNANCE;

        vm.prank(notAuthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, notAuthorized, allowed));
        Reconfiguration(SystemAddresses.RECONFIGURATION).finishTransition(SAMPLE_TRANSCRIPT);
    }

    function test_RevertWhen_finishTransition_notInitialized() public {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(Errors.ReconfigurationNotInitialized.selector);
        Reconfiguration(SystemAddresses.RECONFIGURATION).finishTransition(SAMPLE_TRANSCRIPT);
    }

    // ========================================================================
    // VIEW FUNCTIONS TESTS
    // ========================================================================

    function test_canTriggerEpochTransition_returnsFalse_whenNotInitialized() public view {
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).canTriggerEpochTransition());
    }

    function test_canTriggerEpochTransition_returnsFalse_beforeInterval() public {
        _initializeReconfiguration();

        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).canTriggerEpochTransition());
    }

    function test_canTriggerEpochTransition_returnsTrue_afterInterval() public {
        _initializeReconfiguration();

        _advanceTime(TWO_HOURS + 1);

        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).canTriggerEpochTransition());
    }

    function test_getRemainingTimeSeconds() public {
        _initializeReconfiguration();

        // Initially should be 2 hours (7200 seconds)
        uint64 remaining = Reconfiguration(SystemAddresses.RECONFIGURATION).getRemainingTimeSeconds();
        assertEq(remaining, 7200);

        // After 1 hour, should be 1 hour remaining
        _advanceTime(ONE_HOUR);
        remaining = Reconfiguration(SystemAddresses.RECONFIGURATION).getRemainingTimeSeconds();
        assertEq(remaining, 3600);

        // After 2 hours total, should be 0
        _advanceTime(ONE_HOUR + 1);
        remaining = Reconfiguration(SystemAddresses.RECONFIGURATION).getRemainingTimeSeconds();
        assertEq(remaining, 0);
    }

    function test_getRemainingTimeSeconds_returnsZero_whenNotInitialized() public view {
        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).getRemainingTimeSeconds(), 0);
    }

    function test_isTransitionInProgress() public {
        _initializeReconfiguration();

        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        _advanceTime(TWO_HOURS + 1);
        _startTransition();

        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        _finishTransition("");

        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());
    }

    // ========================================================================
    // FULL EPOCH LIFECYCLE TESTS
    // ========================================================================

    function test_fullEpochLifecycle() public {
        _initializeReconfiguration();

        // Epoch 0
        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 0);
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        // Wait for epoch interval to pass
        _advanceTime(TWO_HOURS + 1);

        // Start transition
        bool started = _startTransition();
        assertTrue(started);
        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        // Still epoch 0 during transition
        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 0);

        // Finish transition
        _finishTransition(SAMPLE_TRANSCRIPT);

        // Now epoch 1
        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());

        // ValidatorManagement epoch incremented
        assertEq(MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getCurrentEpoch(), 1);
    }

    function test_multipleEpochTransitions() public {
        _initializeReconfiguration();

        for (uint64 i = 0; i < 5; i++) {
            assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), i);

            _advanceTime(TWO_HOURS + 1);
            _startTransition();
            _finishTransition("");

            assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), i + 1);
            assertEq(MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getCurrentEpoch(), i + 1);
        }
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_epochTransitionWithVariableInterval(
        uint64 interval
    ) public {
        // Use reasonable bounds for epoch interval (1 second to 1 week in microseconds)
        interval = uint64(bound(interval, 1_000_000, 604_800_000_000));

        // Update interval in EpochConfig using pending pattern before initializing Reconfiguration
        vm.prank(SystemAddresses.GOVERNANCE);
        EpochConfig(SystemAddresses.EPOCH_CONFIG).setForNextEpoch(interval);

        // Apply the pending config via reconfiguration
        vm.prank(SystemAddresses.RECONFIGURATION);
        EpochConfig(SystemAddresses.EPOCH_CONFIG).applyPendingConfig();

        _initializeReconfiguration();

        // Should not be ready to transition yet
        assertFalse(Reconfiguration(SystemAddresses.RECONFIGURATION).canTriggerEpochTransition());

        // Advance time past interval
        _advanceTime(interval + 1);

        // Now should be ready
        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).canTriggerEpochTransition());

        // Complete transition
        _startTransition();
        _finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch(), 1);
    }

    // ========================================================================
    // DKG DEALER/TARGET VALIDATOR SET TESTS
    // ========================================================================

    function test_checkAndStartTransition_usesDifferentDealersAndTargets() public {
        _initializeReconfiguration();

        // Setup: Current validators (dealers) include pending_inactive
        ValidatorConsensusInfo[] memory dealers = new ValidatorConsensusInfo[](3);
        dealers[0] = ValidatorConsensusInfo({
            validator: address(uint160(1)),
            consensusPubkey: abi.encodePacked("pubkey0"),
            consensusPop: abi.encodePacked("pop0"),
            votingPower: 100,
            validatorIndex: 0
        });
        dealers[1] = ValidatorConsensusInfo({
            validator: address(uint160(2)),
            consensusPubkey: abi.encodePacked("pubkey1"),
            consensusPop: abi.encodePacked("pop1"),
            votingPower: 200,
            validatorIndex: 1
        });
        dealers[2] = ValidatorConsensusInfo({
            validator: address(uint160(3)), // pending_inactive
            consensusPubkey: abi.encodePacked("pubkey2"),
            consensusPop: abi.encodePacked("pop2"),
            votingPower: 150,
            validatorIndex: 2
        });

        // Targets: exclude pending_inactive validator (3), include new pending_active (4)
        ValidatorConsensusInfo[] memory targets = new ValidatorConsensusInfo[](3);
        targets[0] = ValidatorConsensusInfo({
            validator: address(uint160(1)),
            consensusPubkey: abi.encodePacked("pubkey0"),
            consensusPop: abi.encodePacked("pop0"),
            votingPower: 100,
            validatorIndex: 0
        });
        targets[1] = ValidatorConsensusInfo({
            validator: address(uint160(2)),
            consensusPubkey: abi.encodePacked("pubkey1"),
            consensusPop: abi.encodePacked("pop1"),
            votingPower: 200,
            validatorIndex: 1
        });
        targets[2] = ValidatorConsensusInfo({
            validator: address(uint160(4)), // new pending_active
            consensusPubkey: abi.encodePacked("pubkey3"),
            consensusPop: abi.encodePacked("pop3"),
            votingPower: 120,
            validatorIndex: 2
        });

        // Set up mock with different dealers and targets
        MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).setDkgValidatorSets(dealers, targets);

        // Advance time and start transition
        _advanceTime(TWO_HOURS + 1);
        bool started = _startTransition();
        assertTrue(started);

        // Verify transition started (DKG.start was called)
        assertTrue(Reconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress());
    }

    function test_checkAndStartTransition_handlesPendingInactiveInDealers() public {
        _initializeReconfiguration();

        // Dealers include validator that is pending_inactive
        // They can still participate in current epoch's DKG
        ValidatorConsensusInfo[] memory dealers = new ValidatorConsensusInfo[](2);
        dealers[0] = ValidatorConsensusInfo({
            validator: address(uint160(1)),
            consensusPubkey: abi.encodePacked("pubkey0"),
            consensusPop: abi.encodePacked("pop0"),
            votingPower: 100,
            validatorIndex: 0
        });
        dealers[1] = ValidatorConsensusInfo({
            validator: address(uint160(2)), // pending_inactive, still in dealers
            consensusPubkey: abi.encodePacked("pubkey1"),
            consensusPop: abi.encodePacked("pop1"),
            votingPower: 200,
            validatorIndex: 1
        });

        // Targets exclude the pending_inactive validator
        ValidatorConsensusInfo[] memory targets = new ValidatorConsensusInfo[](1);
        targets[0] = ValidatorConsensusInfo({
            validator: address(uint160(1)), // index 0 in next epoch
            consensusPubkey: abi.encodePacked("pubkey0"),
            consensusPop: abi.encodePacked("pop0"),
            votingPower: 100,
            validatorIndex: 0
        });

        MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).setDkgValidatorSets(dealers, targets);

        _advanceTime(TWO_HOURS + 1);
        bool started = _startTransition();
        assertTrue(started);
    }

    function test_checkAndStartTransition_targetIndicesAreFreshlyAssigned() public {
        _initializeReconfiguration();

        // Simulate a scenario where target validators get fresh indices (0, 1, 2, ...)
        // This is important: targets should NOT reuse their current epoch indices
        ValidatorConsensusInfo[] memory dealers = new ValidatorConsensusInfo[](3);
        for (uint256 i = 0; i < 3; i++) {
            dealers[i] = ValidatorConsensusInfo({
                validator: address(uint160(i + 1)),
                consensusPubkey: abi.encodePacked("pubkey", i),
                consensusPop: abi.encodePacked("pop", i),
                votingPower: 100 * (i + 1),
                validatorIndex: uint64(i)
            });
        }

        // Targets with fresh indices (position in array = index)
        // Note: In actual implementation, ValidatorManagement assigns indices as 0, 1, 2...
        ValidatorConsensusInfo[] memory targets = new ValidatorConsensusInfo[](2);
        // Only validators 1 and 3 remain (validator 2 is leaving)
        // Their indices are freshly assigned: validator1 -> index 0, validator3 -> index 1
        targets[0] = ValidatorConsensusInfo({
            validator: address(uint160(1)),
            consensusPubkey: abi.encodePacked("pubkey", uint256(0)),
            consensusPop: abi.encodePacked("pop", uint256(0)),
            votingPower: 100,
            validatorIndex: 0
        });
        targets[1] = ValidatorConsensusInfo({
            validator: address(uint160(3)),
            consensusPubkey: abi.encodePacked("pubkey", uint256(2)),
            consensusPop: abi.encodePacked("pop", uint256(2)),
            votingPower: 300,
            validatorIndex: 1
        });

        MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).setDkgValidatorSets(dealers, targets);

        _advanceTime(TWO_HOURS + 1);
        bool started = _startTransition();
        assertTrue(started);

        // Verify: targets array has 2 elements (indices 0 and 1 implicitly)
        // The DKG module will use these for the next epoch's key distribution
    }
}

