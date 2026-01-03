// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Reconfiguration } from "../../../src/blocker/Reconfiguration.sol";
import { IReconfiguration } from "../../../src/blocker/IReconfiguration.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { DKG } from "../../../src/runtime/DKG.sol";
import { RandomnessConfig } from "../../../src/runtime/RandomnessConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorConsensusInfo } from "../../../src/foundation/Types.sol";
import { NotAllowed, NotAllowedAny } from "../../../src/foundation/SystemAccessControl.sol";

/// @notice Mock ValidatorManagement for testing
contract MockValidatorManagement {
    uint64 public lastEpochReceived;
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

    function onNewEpoch(
        uint64 newEpoch
    ) external {
        lastEpochReceived = newEpoch;
    }
}

/// @title ReconfigurationTest
/// @notice Unit tests for Reconfiguration contract
contract ReconfigurationTest is Test {
    Reconfiguration public reconfig;
    Timestamp public timestamp;
    DKG public dkg;
    RandomnessConfig public randomnessConfig;
    MockValidatorManagement public validatorManagement;

    // Common test values
    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant ONE_HOUR = 3_600_000_000;
    uint64 constant TWO_HOURS = 7_200_000_000;
    bytes constant SAMPLE_TRANSCRIPT = hex"deadbeef1234567890abcdef";

    // Events to test
    event EpochTransitionStarted(uint64 indexed epoch);
    event EpochTransitioned(uint64 indexed newEpoch, uint64 transitionTime);
    event EpochDurationUpdated(uint64 oldDuration, uint64 newDuration);

    function setUp() public {
        // Deploy contracts
        reconfig = new Reconfiguration();
        timestamp = new Timestamp();
        dkg = new DKG();
        randomnessConfig = new RandomnessConfig();
        validatorManagement = new MockValidatorManagement();

        // Deploy at system addresses
        vm.etch(SystemAddresses.EPOCH_MANAGER, address(reconfig).code);
        vm.etch(SystemAddresses.TIMESTAMP, address(timestamp).code);
        vm.etch(SystemAddresses.DKG, address(dkg).code);
        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(randomnessConfig).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(validatorManagement).code);

        // Initialize Timestamp
        vm.prank(SystemAddresses.BLOCK);
        Timestamp(SystemAddresses.TIMESTAMP).updateGlobalTime(address(0x1234), INITIAL_TIME);

        // Initialize DKG
        vm.prank(SystemAddresses.GENESIS);
        DKG(SystemAddresses.DKG).initialize();

        // Initialize RandomnessConfig
        vm.prank(SystemAddresses.GENESIS);
        RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).initialize(_createV2Config());

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
                votingPower: 100 * (i + 1)
            });
        }
        return validators;
    }

    function _initializeReconfiguration() internal {
        vm.prank(SystemAddresses.GENESIS);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).initialize();
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
        return Reconfiguration(SystemAddresses.EPOCH_MANAGER).checkAndStartTransition();
    }

    function _finishTransition(
        bytes memory dkgResult
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).finishTransition(dkgResult);
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_initialize_success() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(true, false, false, true);
        emit EpochTransitioned(0, INITIAL_TIME);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).initialize();

        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isInitialized());
        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 0);
        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).epochIntervalMicros(), TWO_HOURS);
        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).lastReconfigurationTime(), INITIAL_TIME);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.EPOCH_MANAGER).getTransitionState()),
            uint8(IReconfiguration.TransitionState.Idle)
        );
    }

    function test_RevertWhen_initialize_notGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).initialize();
    }

    function test_RevertWhen_initialize_alreadyInitialized() public {
        _initializeReconfiguration();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).initialize();
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
            uint8(Reconfiguration(SystemAddresses.EPOCH_MANAGER).getTransitionState()),
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
        bool started = Reconfiguration(SystemAddresses.EPOCH_MANAGER).checkAndStartTransition();

        assertTrue(started);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.EPOCH_MANAGER).getTransitionState()),
            uint8(IReconfiguration.TransitionState.DkgInProgress)
        );
        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());
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
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).checkAndStartTransition();
    }

    function test_RevertWhen_checkAndStartTransition_notInitialized() public {
        vm.prank(SystemAddresses.BLOCK);
        vm.expectRevert(Errors.ReconfigurationNotInitialized.selector);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).checkAndStartTransition();
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
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).finishTransition(SAMPLE_TRANSCRIPT);

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 1);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.EPOCH_MANAGER).getTransitionState()),
            uint8(IReconfiguration.TransitionState.Idle)
        );
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        // Check ValidatorManagement was notified with correct epoch
        assertEq(MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).lastEpochReceived(), 1);
    }

    function test_finishTransition_success_emptyDkgResult() public {
        _initializeReconfiguration();

        // Start transition
        _advanceTime(TWO_HOURS + 1);
        _startTransition();

        // Finish with empty DKG result (force-end)
        _finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 1);
        assertEq(
            uint8(Reconfiguration(SystemAddresses.EPOCH_MANAGER).getTransitionState()),
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
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 1);
    }

    function test_RevertWhen_finishTransition_notInProgress() public {
        _initializeReconfiguration();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(Errors.ReconfigurationNotInProgress.selector);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).finishTransition(SAMPLE_TRANSCRIPT);
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
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).finishTransition(SAMPLE_TRANSCRIPT);
    }

    function test_RevertWhen_finishTransition_notInitialized() public {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(Errors.ReconfigurationNotInitialized.selector);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).finishTransition(SAMPLE_TRANSCRIPT);
    }

    // ========================================================================
    // GOVERNANCE TESTS
    // ========================================================================

    function test_setEpochIntervalMicros_success() public {
        _initializeReconfiguration();

        uint64 newInterval = ONE_HOUR;

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit EpochDurationUpdated(TWO_HOURS, newInterval);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).setEpochIntervalMicros(newInterval);

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).epochIntervalMicros(), newInterval);
    }

    function test_RevertWhen_setEpochIntervalMicros_notGovernance() public {
        _initializeReconfiguration();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).setEpochIntervalMicros(ONE_HOUR);
    }

    function test_RevertWhen_setEpochIntervalMicros_zeroInterval() public {
        _initializeReconfiguration();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidEpochInterval.selector);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).setEpochIntervalMicros(0);
    }

    function test_RevertWhen_setEpochIntervalMicros_notInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.ReconfigurationNotInitialized.selector);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).setEpochIntervalMicros(ONE_HOUR);
    }

    // ========================================================================
    // VIEW FUNCTIONS TESTS
    // ========================================================================

    function test_canTriggerEpochTransition_returnsFalse_whenNotInitialized() public view {
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).canTriggerEpochTransition());
    }

    function test_canTriggerEpochTransition_returnsFalse_beforeInterval() public {
        _initializeReconfiguration();

        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).canTriggerEpochTransition());
    }

    function test_canTriggerEpochTransition_returnsTrue_afterInterval() public {
        _initializeReconfiguration();

        _advanceTime(TWO_HOURS + 1);

        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).canTriggerEpochTransition());
    }

    function test_getRemainingTimeSeconds() public {
        _initializeReconfiguration();

        // Initially should be 2 hours (7200 seconds)
        uint64 remaining = Reconfiguration(SystemAddresses.EPOCH_MANAGER).getRemainingTimeSeconds();
        assertEq(remaining, 7200);

        // After 1 hour, should be 1 hour remaining
        _advanceTime(ONE_HOUR);
        remaining = Reconfiguration(SystemAddresses.EPOCH_MANAGER).getRemainingTimeSeconds();
        assertEq(remaining, 3600);

        // After 2 hours total, should be 0
        _advanceTime(ONE_HOUR + 1);
        remaining = Reconfiguration(SystemAddresses.EPOCH_MANAGER).getRemainingTimeSeconds();
        assertEq(remaining, 0);
    }

    function test_getRemainingTimeSeconds_returnsZero_whenNotInitialized() public view {
        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).getRemainingTimeSeconds(), 0);
    }

    function test_isTransitionInProgress() public {
        _initializeReconfiguration();

        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        _advanceTime(TWO_HOURS + 1);
        _startTransition();

        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        _finishTransition("");

        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());
    }

    // ========================================================================
    // FULL EPOCH LIFECYCLE TESTS
    // ========================================================================

    function test_fullEpochLifecycle() public {
        _initializeReconfiguration();

        // Epoch 0
        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 0);
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        // Wait for epoch interval to pass
        _advanceTime(TWO_HOURS + 1);

        // Start transition
        bool started = _startTransition();
        assertTrue(started);
        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        // Still epoch 0 during transition
        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 0);

        // Finish transition
        _finishTransition(SAMPLE_TRANSCRIPT);

        // Now epoch 1
        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 1);
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        // ValidatorManagement received the new epoch
        assertEq(MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).lastEpochReceived(), 1);
    }

    function test_multipleEpochTransitions() public {
        _initializeReconfiguration();

        for (uint64 i = 0; i < 5; i++) {
            assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), i);

            _advanceTime(TWO_HOURS + 1);
            _startTransition();
            _finishTransition("");

            assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), i + 1);
            assertEq(MockValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).lastEpochReceived(), i + 1);
        }
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_setEpochIntervalMicros(
        uint64 newInterval
    ) public {
        vm.assume(newInterval > 0);
        _initializeReconfiguration();

        vm.prank(SystemAddresses.GOVERNANCE);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).setEpochIntervalMicros(newInterval);

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).epochIntervalMicros(), newInterval);
    }

    function testFuzz_epochTransitionWithVariableInterval(
        uint64 interval
    ) public {
        // Use reasonable bounds for epoch interval (1 second to 1 week in microseconds)
        interval = uint64(bound(interval, 1_000_000, 604_800_000_000));

        _initializeReconfiguration();

        // Update interval
        vm.prank(SystemAddresses.GOVERNANCE);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).setEpochIntervalMicros(interval);

        // Should not be ready to transition yet
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).canTriggerEpochTransition());

        // Advance time past interval
        _advanceTime(interval + 1);

        // Now should be ready
        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).canTriggerEpochTransition());

        // Complete transition
        _startTransition();
        _finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 1);
    }
}

