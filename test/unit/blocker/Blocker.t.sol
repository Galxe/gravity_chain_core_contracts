// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Blocker } from "../../../src/blocker/Blocker.sol";
import { Reconfiguration } from "../../../src/blocker/Reconfiguration.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { DKG } from "../../../src/runtime/DKG.sol";
import { RandomnessConfig } from "../../../src/runtime/RandomnessConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorConsensusInfo } from "../../../src/foundation/Types.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @notice Mock ValidatorManagement for testing
contract MockValidatorManagementBlocker {
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

/// @title BlockerTest
/// @notice Unit tests for Blocker contract
contract BlockerTest is Test {
    Blocker public blocker;
    Reconfiguration public reconfig;
    Timestamp public timestamp;
    DKG public dkg;
    RandomnessConfig public randomnessConfig;
    MockValidatorManagementBlocker public validatorManagement;

    // Common test values
    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant ONE_HOUR = 3_600_000_000;
    uint64 constant TWO_HOURS = 7_200_000_000;
    bytes32 constant PROPOSER_KEY = bytes32(uint256(0x1234567890abcdef));
    bytes32 constant NIL_PROPOSER = bytes32(0);

    // Events to test
    event BlockStarted(uint256 indexed blockHeight, uint64 indexed epoch, address proposer, uint64 timestampMicros);

    function setUp() public {
        // Deploy contracts
        blocker = new Blocker();
        reconfig = new Reconfiguration();
        timestamp = new Timestamp();
        dkg = new DKG();
        randomnessConfig = new RandomnessConfig();
        validatorManagement = new MockValidatorManagementBlocker();

        // Deploy at system addresses
        vm.etch(SystemAddresses.BLOCK, address(blocker).code);
        vm.etch(SystemAddresses.EPOCH_MANAGER, address(reconfig).code);
        vm.etch(SystemAddresses.TIMESTAMP, address(timestamp).code);
        vm.etch(SystemAddresses.DKG, address(dkg).code);
        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(randomnessConfig).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(validatorManagement).code);

        // Initialize RandomnessConfig
        vm.prank(SystemAddresses.GENESIS);
        RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).initialize(_createV2Config());

        // Setup mock validators
        MockValidatorManagementBlocker(SystemAddresses.VALIDATOR_MANAGER).setValidators(_createValidators(3));
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

    function _initializeBlocker() internal {
        vm.prank(SystemAddresses.GENESIS);
        Blocker(SystemAddresses.BLOCK).initialize();
    }

    function _initializeReconfiguration() internal {
        vm.prank(SystemAddresses.GENESIS);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).initialize();
    }

    function _initializeAll() internal {
        _initializeBlocker();
        _initializeReconfiguration();
    }

    function _callOnBlockStart(
        bytes32 proposer,
        uint64 timestampMicros
    ) internal {
        bytes32[] memory failedProposers = new bytes32[](0);
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Blocker(SystemAddresses.BLOCK).onBlockStart(proposer, failedProposers, timestampMicros);
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_initialize_success() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(true, true, false, true);
        emit BlockStarted(0, 0, SystemAddresses.SYSTEM_CALLER, 0);
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
        vm.expectRevert(Blocker.AlreadyInitialized.selector);
        Blocker(SystemAddresses.BLOCK).initialize();
    }

    // ========================================================================
    // ON BLOCK START TESTS
    // ========================================================================

    function test_onBlockStart_normalBlock() public {
        _initializeAll();

        uint64 newTimestamp = INITIAL_TIME + 1_000_000; // 1 second later

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, true, false, true);
        // proposer address will be uint160(uint256(PROPOSER_KEY))
        emit BlockStarted(block.number, 0, address(uint160(uint256(PROPOSER_KEY))), newTimestamp);

        bytes32[] memory failedProposers = new bytes32[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_KEY, failedProposers, newTimestamp);

        // Check timestamp was updated
        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), newTimestamp);
    }

    function test_onBlockStart_nilBlock() public {
        _initializeAll();

        // For NIL blocks, timestamp must stay the same
        uint64 currentTime = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, true, false, true);
        emit BlockStarted(block.number, 0, SystemAddresses.SYSTEM_CALLER, currentTime);

        bytes32[] memory failedProposers = new bytes32[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(NIL_PROPOSER, failedProposers, currentTime);

        // Timestamp should stay the same for NIL block
        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), currentTime);
    }

    function test_onBlockStart_triggersEpochTransition_whenTimeElapsed() public {
        _initializeAll();

        // Advance time past epoch interval (2 hours)
        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + TWO_HOURS + 1;

        // Call onBlockStart which should trigger epoch transition
        _callOnBlockStart(PROPOSER_KEY, newTimestamp);

        // Check that epoch transition started
        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());
    }

    function test_onBlockStart_noTransition_whenTimeNotElapsed() public {
        _initializeAll();

        // Advance time but not past epoch interval
        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + ONE_HOUR;

        _callOnBlockStart(PROPOSER_KEY, newTimestamp);

        // Transition should not have started
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());
    }

    function test_RevertWhen_onBlockStart_notSystemCaller() public {
        _initializeAll();

        address notSystemCaller = address(0x1234);
        bytes32[] memory failedProposers = new bytes32[](0);

        vm.prank(notSystemCaller);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notSystemCaller, SystemAddresses.SYSTEM_CALLER));
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_KEY, failedProposers, INITIAL_TIME + 1);
    }

    function test_onBlockStart_withFailedProposers() public {
        _initializeAll();

        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;

        bytes32[] memory failedProposers = new bytes32[](2);
        failedProposers[0] = bytes32(uint256(0xaaaa));
        failedProposers[1] = bytes32(uint256(0xbbbb));

        // Should succeed even with failed proposers (they're currently unused)
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_KEY, failedProposers, newTimestamp);

        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), newTimestamp);
    }

    // ========================================================================
    // PROPOSER RESOLUTION TESTS
    // ========================================================================

    function test_proposerResolution_nilBlock() public {
        _initializeAll();

        uint64 currentTime = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // NIL block (bytes32(0)) should resolve to SYSTEM_CALLER
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, false, false, true);
        emit BlockStarted(block.number, 0, SystemAddresses.SYSTEM_CALLER, currentTime);

        bytes32[] memory failedProposers = new bytes32[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(NIL_PROPOSER, failedProposers, currentTime);
    }

    function test_proposerResolution_normalBlock() public {
        _initializeAll();

        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;

        // Non-NIL block should convert proposer key to address
        address expectedProposer = address(uint160(uint256(PROPOSER_KEY)));

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, false, false, true);
        emit BlockStarted(block.number, 0, expectedProposer, newTimestamp);

        bytes32[] memory failedProposers = new bytes32[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(PROPOSER_KEY, failedProposers, newTimestamp);
    }

    // ========================================================================
    // INTEGRATION WITH RECONFIGURATION TESTS
    // ========================================================================

    function test_fullBlockFlow_withEpochTransition() public {
        _initializeAll();

        // Block 1: Normal block, no transition
        uint64 timestamp1 = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;
        _callOnBlockStart(PROPOSER_KEY, timestamp1);

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 0);
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        // Block 2: After epoch interval, transition starts
        uint64 timestamp2 = timestamp1 + TWO_HOURS;
        _callOnBlockStart(PROPOSER_KEY, timestamp2);

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 0);
        assertTrue(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());

        // Finish transition manually (normally consensus engine does this)
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        Reconfiguration(SystemAddresses.EPOCH_MANAGER).finishTransition("");

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 1);

        // Block 3: After transition, new epoch
        uint64 timestamp3 = timestamp2 + 1_000_000;
        _callOnBlockStart(PROPOSER_KEY, timestamp3);

        assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 1);
        assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());
    }

    function test_multipleBlocksWithoutTransition() public {
        _initializeAll();

        uint64 currentTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // Process multiple blocks without triggering transition
        for (uint256 i = 0; i < 10; i++) {
            currentTimestamp += 1_000_000; // 1 second each
            _callOnBlockStart(PROPOSER_KEY, currentTimestamp);

            assertEq(Reconfiguration(SystemAddresses.EPOCH_MANAGER).currentEpoch(), 0);
            assertFalse(Reconfiguration(SystemAddresses.EPOCH_MANAGER).isTransitionInProgress());
        }
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_onBlockStart_proposerConversion(
        bytes32 proposer
    ) public {
        vm.assume(proposer != bytes32(0)); // Non-NIL block
        _initializeAll();

        uint64 newTimestamp = Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() + 1_000_000;
        address expectedProposer = address(uint160(uint256(proposer)));

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectEmit(false, false, false, true);
        emit BlockStarted(block.number, 0, expectedProposer, newTimestamp);

        bytes32[] memory failedProposers = new bytes32[](0);
        Blocker(SystemAddresses.BLOCK).onBlockStart(proposer, failedProposers, newTimestamp);

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

        _callOnBlockStart(PROPOSER_KEY, newTimestamp);

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
            _callOnBlockStart(PROPOSER_KEY, currentTimestamp);
        }

        assertEq(Timestamp(SystemAddresses.TIMESTAMP).nowMicroseconds(), currentTimestamp);
    }
}

