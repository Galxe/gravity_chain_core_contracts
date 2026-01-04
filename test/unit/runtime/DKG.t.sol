// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DKG } from "../../../src/runtime/DKG.sol";
import { RandomnessConfig } from "../../../src/runtime/RandomnessConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorConsensusInfo } from "../../../src/foundation/Types.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";

/// @title DKGTest
/// @notice Unit tests for DKG contract
contract DKGTest is Test {
    DKG public dkg;
    Timestamp public timestamp;

    // Common test values
    uint64 constant EPOCH_1 = 1;
    uint64 constant EPOCH_2 = 2;
    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant ONE_HOUR = 3_600_000_000;
    bytes constant SAMPLE_TRANSCRIPT = hex"deadbeef1234567890abcdef";

    function setUp() public {
        dkg = new DKG();
        timestamp = new Timestamp();

        // Deploy timestamp at the expected address for DKG to use
        vm.etch(SystemAddresses.TIMESTAMP, address(timestamp).code);

        // Initialize timestamp with initial time
        vm.prank(SystemAddresses.BLOCK);
        Timestamp(SystemAddresses.TIMESTAMP).updateGlobalTime(address(0x1234), INITIAL_TIME);
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _createOffConfig() internal pure returns (RandomnessConfig.RandomnessConfigData memory) {
        return RandomnessConfig.RandomnessConfigData({
            variant: RandomnessConfig.ConfigVariant.Off, configV2: RandomnessConfig.ConfigV2Data(0, 0, 0)
        });
    }

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

    function _startSession() internal {
        _startSession(EPOCH_1);
    }

    function _startSession(
        uint64 epoch
    ) internal {
        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.start(epoch, _createV2Config(), _createValidators(3), _createValidators(4));
    }

    // ========================================================================
    // START SESSION TESTS
    // ========================================================================

    function test_Start() public {
        ValidatorConsensusInfo[] memory dealers = _createValidators(3);
        ValidatorConsensusInfo[] memory targets = _createValidators(4);
        RandomnessConfig.RandomnessConfigData memory config = _createV2Config();

        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.start(EPOCH_1, config, dealers, targets);

        assertTrue(dkg.hasInProgress());
        assertTrue(dkg.isInProgress());

        (bool hasSession, DKG.DKGSessionInfo memory info) = dkg.getIncompleteSession();
        assertTrue(hasSession);
        assertEq(info.dealerEpoch, EPOCH_1);
        assertEq(uint8(info.configVariant), uint8(RandomnessConfig.ConfigVariant.V2));
        assertEq(info.dealerCount, 3);
        assertEq(info.targetCount, 4);
        assertEq(info.startTimeUs, INITIAL_TIME);
    }

    function test_RevertWhen_Start_AlreadyInProgress() public {
        _startSession();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(Errors.DKGInProgress.selector);
        dkg.start(EPOCH_2, _createV2Config(), _createValidators(3), _createValidators(4));
    }

    function test_RevertWhen_Start_NotReconfiguration() public {
        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        dkg.start(EPOCH_1, _createV2Config(), _createValidators(3), _createValidators(4));
    }

    // ========================================================================
    // FINISH SESSION TESTS
    // ========================================================================

    function test_Finish() public {
        _startSession();

        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.finish(SAMPLE_TRANSCRIPT);

        assertFalse(dkg.hasInProgress());
        assertFalse(dkg.isInProgress());
        assertTrue(dkg.hasLastCompleted());

        (bool hasCompleted, DKG.DKGSessionInfo memory info) = dkg.getLastCompletedSession();
        assertTrue(hasCompleted);
        assertEq(info.dealerEpoch, EPOCH_1);
        assertEq(info.startTimeUs, INITIAL_TIME);
        assertEq(info.transcript, SAMPLE_TRANSCRIPT);
    }

    function test_RevertWhen_Finish_NotInProgress() public {
        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(Errors.DKGNotInProgress.selector);
        dkg.finish(SAMPLE_TRANSCRIPT);
    }

    function test_RevertWhen_Finish_NotReconfiguration() public {
        _startSession();

        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        dkg.finish(SAMPLE_TRANSCRIPT);
    }

    // ========================================================================
    // TRY CLEAR INCOMPLETE SESSION TESTS
    // ========================================================================

    function test_TryClearIncompleteSession() public {
        _startSession();
        assertTrue(dkg.hasInProgress());

        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.tryClearIncompleteSession();

        assertFalse(dkg.hasInProgress());
        assertFalse(dkg.isInProgress());
    }

    function test_TryClearIncompleteSession_NoSession() public {
        assertFalse(dkg.hasInProgress());

        // Should be no-op
        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.tryClearIncompleteSession();

        assertFalse(dkg.hasInProgress());
    }

    function test_RevertWhen_TryClearIncompleteSession_NotReconfiguration() public {
        _startSession();

        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        dkg.tryClearIncompleteSession();
    }

    // ========================================================================
    // VIEW FUNCTION TESTS
    // ========================================================================

    function test_GetIncompleteSession_NoSession() public view {
        (bool hasSession, DKG.DKGSessionInfo memory info) = dkg.getIncompleteSession();
        assertFalse(hasSession);
        assertEq(info.dealerEpoch, 0);
        assertEq(info.startTimeUs, 0);
    }

    function test_GetLastCompletedSession_NoSession() public view {
        (bool hasSession, DKG.DKGSessionInfo memory info) = dkg.getLastCompletedSession();
        assertFalse(hasSession);
        assertEq(info.dealerEpoch, 0);
        assertEq(info.startTimeUs, 0);
        assertEq(info.transcript, "");
    }

    function test_SessionDealerEpoch() public view {
        DKG.DKGSessionInfo memory info;
        info.dealerEpoch = 42;
        assertEq(dkg.sessionDealerEpoch(info), 42);
    }

    // ========================================================================
    // MULTI-SESSION LIFECYCLE TESTS
    // ========================================================================

    function test_MultipleSessionLifecycle() public {
        // Session 1
        _startSession(EPOCH_1);
        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.finish(hex"0001");

        // Verify session 1 completed
        (bool hasCompleted1, DKG.DKGSessionInfo memory info1) = dkg.getLastCompletedSession();
        assertTrue(hasCompleted1);
        assertEq(info1.startTimeUs, INITIAL_TIME);

        // Advance time
        vm.prank(SystemAddresses.BLOCK);
        Timestamp(SystemAddresses.TIMESTAMP).updateGlobalTime(address(0x1234), INITIAL_TIME + ONE_HOUR);

        // Session 2
        _startSession(EPOCH_2);
        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.finish(hex"0002");

        // Verify session 2 is now last completed
        (bool hasCompleted2, DKG.DKGSessionInfo memory info2) = dkg.getLastCompletedSession();
        assertTrue(hasCompleted2);
        assertEq(info2.dealerEpoch, EPOCH_2);
        assertEq(info2.startTimeUs, INITIAL_TIME + ONE_HOUR);
        assertEq(info2.transcript, hex"0002");
    }

    function test_SessionClearAndRestart() public {
        // Start session
        _startSession(EPOCH_1);
        assertTrue(dkg.hasInProgress());

        // Clear it
        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.tryClearIncompleteSession();
        assertFalse(dkg.hasInProgress());

        // Start new session should work
        _startSession(EPOCH_2);
        assertTrue(dkg.hasInProgress());

        (bool hasSession, DKG.DKGSessionInfo memory info) = dkg.getIncompleteSession();
        assertTrue(hasSession);
        assertEq(info.dealerEpoch, EPOCH_2);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Event_DKGStartEvent() public {
        // Note: We can't easily test the full event struct with expectEmit
        // due to the nested struct, but we verify indexed parameters
        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(true, false, false, false);
        emit DKG.DKGStartEvent(EPOCH_1, INITIAL_TIME, _createDKGSessionMetadata());
        dkg.start(EPOCH_1, _createV2Config(), _createValidators(3), _createValidators(4));
    }

    function test_Event_DKGCompleted() public {
        _startSession();

        bytes32 expectedHash = keccak256(SAMPLE_TRANSCRIPT);

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(true, false, false, true);
        emit DKG.DKGCompleted(EPOCH_1, expectedHash);
        dkg.finish(SAMPLE_TRANSCRIPT);
    }

    function test_Event_DKGSessionCleared() public {
        _startSession();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(true, false, false, false);
        emit DKG.DKGSessionCleared(EPOCH_1);
        dkg.tryClearIncompleteSession();
    }

    // Helper to create expected metadata for event testing
    function _createDKGSessionMetadata() internal pure returns (DKG.DKGSessionMetadata memory) {
        return DKG.DKGSessionMetadata({
            dealerEpoch: EPOCH_1,
            randomnessConfig: _createV2Config(),
            dealerValidatorSet: _createValidators(3),
            targetValidatorSet: _createValidators(4)
        });
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_StartFinish(
        uint64 epoch,
        bytes calldata transcript
    ) public {
        vm.assume(transcript.length > 0);

        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.start(epoch, _createV2Config(), _createValidators(3), _createValidators(4));

        assertTrue(dkg.hasInProgress());
        (bool hasSession, DKG.DKGSessionInfo memory info) = dkg.getIncompleteSession();
        assertTrue(hasSession);
        assertEq(info.dealerEpoch, epoch);

        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.finish(transcript);

        assertFalse(dkg.hasInProgress());
        assertTrue(dkg.hasLastCompleted());

        (bool hasCompleted, DKG.DKGSessionInfo memory completedInfo) = dkg.getLastCompletedSession();
        assertTrue(hasCompleted);
        assertEq(completedInfo.transcript, transcript);
    }

    function testFuzz_ValidatorCounts(
        uint8 dealerCount,
        uint8 targetCount
    ) public {
        vm.assume(dealerCount > 0 && dealerCount <= 10);
        vm.assume(targetCount > 0 && targetCount <= 10);

        vm.prank(SystemAddresses.RECONFIGURATION);
        dkg.start(EPOCH_1, _createV2Config(), _createValidators(dealerCount), _createValidators(targetCount));

        (bool hasSession, DKG.DKGSessionInfo memory info) = dkg.getIncompleteSession();
        assertTrue(hasSession);
        assertEq(info.dealerCount, dealerCount);
        assertEq(info.targetCount, targetCount);
    }
}
