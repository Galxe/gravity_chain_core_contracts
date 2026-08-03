// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";
import { INativeOracle } from "../../../src/oracle/INativeOracle.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { IPolymarketSettlementResolver } from "../../../src/oracle/resolver/IPolymarketSettlementResolver.sol";
import { PolymarketSettlementResolver } from "../../../src/oracle/resolver/PolymarketSettlementResolver.sol";

contract PolymarketSettlementResolverTest is Test {
    NativeOracle public oracle;
    PolymarketSettlementResolver public resolver;

    uint32 public constant SOURCE_TYPE_POLYMARKET_SETTLEMENT = 6;
    uint256 public constant MIRROR_ID = 1_897_398;
    uint256 public constant SECOND_MIRROR_ID = 1_897_399;
    uint256 public constant POLYGON_CHAIN_ID = 137;
    uint256 public constant SOURCE_BLOCK = 89_222_209;
    uint256 public constant LOG_INDEX = 2_077;
    uint256 public constant CALLBACK_GAS_LIMIT = 500_000;
    uint256 public constant MAX_OUTCOME_SLOT_COUNT = 32;
    uint8 public constant SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION = 1;

    address public constant CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address public constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;
    bytes32 public constant QUESTION_ID = 0x49a5e94a4b5a400dcd720ca1875fcd49ba55c303e43bf091bc175df72f74f501;
    bytes32 public constant TX_HASH = 0x97828bf9110f78c07f1ad5cff5415875b67b3fe032e19ee6aa2317355861aab2;

    address public alice = makeAddr("alice");
    bytes32 public conditionId;

    function setUp() public {
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
        resolver = new PolymarketSettlementResolver();
        conditionId = _conditionId(UMA_ORACLE, QUESTION_ID, 2);

        vm.startPrank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(SOURCE_TYPE_POLYMARKET_SETTLEMENT, address(resolver));
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, conditionId, 2);
        vm.stopPrank();
    }

    function test_StoresTerminalWinnerAndSourceProgress() public {
        vm.warp(1_000_000);
        uint256[] memory payouts = _payouts(1, 0);

        _record(MIRROR_ID, 1, SOURCE_BLOCK, _encode(_payload(MIRROR_ID, payouts)), CALLBACK_GAS_LIMIT);

        (
            IPolymarketSettlementResolver.ObservationStatus status,
            uint8 winningSlot,
            uint128 nonce,
            uint64 recordedAt,
            bytes32 txHash,
            uint256 logIndex
        ) = resolver.getSettlementObservation(MIRROR_ID, conditionId);
        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.ResolvedWinner));
        assertEq(winningSlot, 0);
        assertEq(nonce, 1);
        assertEq(recordedAt, 1_000_000);
        assertEq(txHash, TX_HASH);
        assertEq(logIndex, LOG_INDEX);
        assertTrue(resolver.isSettlementObserved(MIRROR_ID, conditionId));

        INativeOracle.SourceProgress memory progress =
            oracle.getSourceProgress(SOURCE_TYPE_POLYMARKET_SETTLEMENT, MIRROR_ID);
        assertEq(progress.latestNonce, 1);
        assertEq(progress.latestPosition, SOURCE_BLOCK);
        assertEq(oracle.getRecord(SOURCE_TYPE_POLYMARKET_SETTLEMENT, MIRROR_ID, 1).recordedAt, 0);
    }

    function test_GetSettlementReturnsCanonicalMetadata() public {
        _record(MIRROR_ID, 1, SOURCE_BLOCK, _encode(_payload(MIRROR_ID, _payouts(0, 1))), CALLBACK_GAS_LIMIT);

        (
            bool exists,
            uint128 nonce,
            uint256 polygonChainId,
            address ctf,
            address oracleAddress,
            bytes32 questionId,
            uint256 outcomeSlotCount,
            bytes32 txHash,
            uint256 logIndex,
            uint8 settlementKind
        ) = resolver.getSettlement(MIRROR_ID, conditionId);
        assertTrue(exists);
        assertEq(nonce, 1);
        assertEq(polygonChainId, POLYGON_CHAIN_ID);
        assertEq(ctf, CTF);
        assertEq(oracleAddress, UMA_ORACLE);
        assertEq(questionId, QUESTION_ID);
        assertEq(outcomeSlotCount, 2);
        assertEq(txHash, TX_HASH);
        assertEq(logIndex, LOG_INDEX);
        assertEq(settlementKind, resolver.SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION());
    }

    function test_MaximumOutcomeCountFitsStandardCallbackGasLimit() public {
        uint256 mirrorId = SECOND_MIRROR_ID;
        bytes32 questionId = keccak256("maximum-outcome-question");
        bytes32 maximumConditionId = _conditionId(UMA_ORACLE, questionId, MAX_OUTCOME_SLOT_COUNT);
        vm.prank(SystemAddresses.GOVERNANCE);
        resolver.registerMirror(mirrorId, POLYGON_CHAIN_ID, CTF, maximumConditionId, MAX_OUTCOME_SLOT_COUNT);

        uint256[] memory payouts = new uint256[](MAX_OUTCOME_SLOT_COUNT);
        payouts[MAX_OUTCOME_SLOT_COUNT - 1] = 1;
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(mirrorId, payouts);
        payload.questionId = questionId;
        payload.conditionId = maximumConditionId;
        payload.outcomeSlotCount = MAX_OUTCOME_SLOT_COUNT;

        _record(mirrorId, 1, SOURCE_BLOCK, _encode(payload), CALLBACK_GAS_LIMIT);

        (IPolymarketSettlementResolver.ObservationStatus status, uint8 winningSlot,,,,) =
            resolver.getSettlementObservation(mirrorId, maximumConditionId);
        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.ResolvedWinner));
        assertEq(winningSlot, MAX_OUTCOME_SLOT_COUNT - 1);
    }

    function test_ClassifiesWinnerAtNonzeroSlot() public view {
        (IPolymarketSettlementResolver.ObservationStatus status, uint8 winningSlot) =
            resolver.classifySettlementPayload(MIRROR_ID, _encode(_payload(MIRROR_ID, _payouts(0, 7))));

        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.ResolvedWinner));
        assertEq(winningSlot, 1);
    }

    function test_MultiplePositivePayoutsAreTerminalAndVoidable() public {
        bytes memory encoded = _encode(_payload(MIRROR_ID, _payouts(1, 1)));
        (IPolymarketSettlementResolver.ObservationStatus classified, uint8 classifiedSlot) =
            resolver.classifySettlementPayload(MIRROR_ID, encoded);
        assertEq(uint8(classified), uint8(IPolymarketSettlementResolver.ObservationStatus.ResolvedVoidable));
        assertEq(classifiedSlot, type(uint8).max);

        _record(MIRROR_ID, 1, SOURCE_BLOCK, encoded, CALLBACK_GAS_LIMIT);
        (IPolymarketSettlementResolver.ObservationStatus stored, uint8 storedSlot,,,,) =
            resolver.getSettlementObservation(MIRROR_ID, conditionId);
        assertEq(uint8(stored), uint8(IPolymarketSettlementResolver.ObservationStatus.ResolvedVoidable));
        assertEq(storedSlot, type(uint8).max);
    }

    function test_ArbitrarilyDelayedCanonicalSettlementRemainsValid() public {
        vm.warp(100 * 365 days);
        _record(MIRROR_ID, 1, SOURCE_BLOCK, _encode(_payload(MIRROR_ID, _payouts(1, 0))), CALLBACK_GAS_LIMIT);

        (IPolymarketSettlementResolver.ObservationStatus status,,, uint64 recordedAt,,) =
            resolver.getSettlementObservation(MIRROR_ID, conditionId);
        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.ResolvedWinner));
        assertEq(recordedAt, block.timestamp);
    }

    function test_IndependentMirrorsDoNotShareSettlementState() public {
        bytes32 secondQuestion = keccak256("second-question");
        bytes32 secondCondition = _conditionId(UMA_ORACLE, secondQuestion, 2);
        vm.prank(SystemAddresses.GOVERNANCE);
        resolver.registerMirror(SECOND_MIRROR_ID, POLYGON_CHAIN_ID, CTF, secondCondition, 2);

        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload =
            _payload(SECOND_MIRROR_ID, _payouts(0, 1));
        payload.questionId = secondQuestion;
        payload.conditionId = secondCondition;
        _record(SECOND_MIRROR_ID, 1, SOURCE_BLOCK, _encode(payload), CALLBACK_GAS_LIMIT);

        assertFalse(resolver.isSettlementObserved(MIRROR_ID, conditionId));
        assertTrue(resolver.isSettlementObserved(SECOND_MIRROR_ID, secondCondition));
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_POLYMARKET_SETTLEMENT, MIRROR_ID), 0);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_POLYMARKET_SETTLEMENT, SECOND_MIRROR_ID), 1);
    }

    function test_GetMirrorConfigReturnsImmutableIdentity() public view {
        (bool exists, uint256 chainId, address ctf, bytes32 registeredCondition, uint256 slots) =
            resolver.getMirrorConfig(MIRROR_ID);
        assertTrue(exists);
        assertEq(chainId, POLYGON_CHAIN_ID);
        assertEq(ctf, CTF);
        assertEq(registeredCondition, conditionId);
        assertEq(slots, 2);
    }

    function test_UnknownOrWrongConditionReadsAsUnobserved() public view {
        bytes32 wrongCondition = keccak256("wrong-condition");
        assertFalse(resolver.isSettlementObserved(MIRROR_ID, wrongCondition));
        assertFalse(resolver.isSettlementObserved(999, conditionId));
        (IPolymarketSettlementResolver.ObservationStatus status, uint8 winningSlot,,,,) =
            resolver.getSettlementObservation(MIRROR_ID, wrongCondition);
        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.None));
        assertEq(winningSlot, type(uint8).max);
    }

    function test_RevertWhenRegisteringMirrorTwice() public {
        vm.expectRevert(
            abi.encodeWithSelector(PolymarketSettlementResolver.MirrorAlreadyRegistered.selector, MIRROR_ID)
        );
        vm.prank(SystemAddresses.GOVERNANCE);
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, conditionId, 2);
    }

    function test_RevertWhenRegisteringMirrorOutsideGovernance() public {
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, alice, SystemAddresses.GOVERNANCE));
        vm.prank(alice);
        resolver.registerMirror(SECOND_MIRROR_ID, POLYGON_CHAIN_ID, CTF, conditionId, 2);
    }

    function test_RevertWhenMirrorIdExceedsRelayerIdentityWidth() public {
        vm.expectRevert(PolymarketSettlementResolver.InvalidMirrorConfig.selector);
        vm.prank(SystemAddresses.GOVERNANCE);
        resolver.registerMirror(uint256(type(uint64).max) + 1, POLYGON_CHAIN_ID, CTF, conditionId, 2);
    }

    function test_RevertWhenMirrorIdentityFieldIsZeroOrForeign() public {
        vm.startPrank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(PolymarketSettlementResolver.InvalidMirrorConfig.selector);
        resolver.registerMirror(0, POLYGON_CHAIN_ID, CTF, conditionId, 2);
        vm.expectRevert(PolymarketSettlementResolver.InvalidMirrorConfig.selector);
        resolver.registerMirror(SECOND_MIRROR_ID, 1, CTF, conditionId, 2);
        vm.expectRevert(PolymarketSettlementResolver.InvalidMirrorConfig.selector);
        resolver.registerMirror(SECOND_MIRROR_ID, POLYGON_CHAIN_ID, address(0), conditionId, 2);
        vm.expectRevert(PolymarketSettlementResolver.InvalidMirrorConfig.selector);
        resolver.registerMirror(SECOND_MIRROR_ID, POLYGON_CHAIN_ID, CTF, bytes32(0), 2);
        vm.stopPrank();
    }

    function test_RevertWhenOutcomeCountIsOutsideBounds() public {
        vm.startPrank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(PolymarketSettlementResolver.InvalidMirrorConfig.selector);
        resolver.registerMirror(SECOND_MIRROR_ID, POLYGON_CHAIN_ID, CTF, conditionId, 1);
        vm.expectRevert(PolymarketSettlementResolver.InvalidMirrorConfig.selector);
        resolver.registerMirror(SECOND_MIRROR_ID, POLYGON_CHAIN_ID, CTF, conditionId, MAX_OUTCOME_SLOT_COUNT + 1);
        vm.stopPrank();
    }

    function test_RevertWhenCallbackCalledOutsideNativeOracle() public {
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, alice, SystemAddresses.NATIVE_ORACLE));
        vm.prank(alice);
        resolver.onOracleEvent(
            SOURCE_TYPE_POLYMARKET_SETTLEMENT, MIRROR_ID, 1, _encode(_payload(MIRROR_ID, _payouts(1, 0)))
        );
    }

    function test_RevertWhenNativeOracleUsesWrongSourceType() public {
        vm.expectRevert(abi.encodeWithSelector(PolymarketSettlementResolver.UnsupportedSourceType.selector, uint32(7)));
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        resolver.onOracleEvent(7, MIRROR_ID, 1, _encode(_payload(MIRROR_ID, _payouts(1, 0))));
    }

    function test_UnregisteredMirrorRevertsAtomically() public {
        uint256 unknownMirror = 999;
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload =
            _payload(unknownMirror, _payouts(1, 0));

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(unknownMirror, 1, SOURCE_BLOCK, _encode(payload), CALLBACK_GAS_LIMIT);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_POLYMARKET_SETTLEMENT, unknownMirror), 0);
    }

    function test_SourceIdMismatchRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload =
            _payload(MIRROR_ID + 1, _payouts(1, 0));

        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_ChainMismatchRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.polygonChainId = 1;
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_CtfMismatchRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.ctf = makeAddr("other-ctf");
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_ConditionMismatchRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.conditionId = keccak256("other-condition");
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_DerivedConditionIdentityMismatchRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.questionId = keccak256("foreign-question");
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_OutcomeCountMismatchRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.outcomeSlotCount = 3;
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_AllZeroPayoutRevertsAtomically() public {
        _expectAtomicFailure(MIRROR_ID, _encode(_payload(MIRROR_ID, _payouts(0, 0))));
    }

    function test_PayoutLengthMismatchRevertsAtomically() public {
        uint256[] memory payouts = new uint256[](3);
        payouts[0] = 1;
        _expectAtomicFailure(MIRROR_ID, _encode(_payload(MIRROR_ID, payouts)));
    }

    function test_InvalidSettlementKindRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.settlementKind = 2;
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_ZeroProvenanceRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.txHash = bytes32(0);
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_ZeroOracleOrQuestionRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.oracle = address(0);
        _expectAtomicFailure(MIRROR_ID, _encode(payload));

        payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.questionId = bytes32(0);
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_LogIndexOverflowRevertsAtomically() public {
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload = _payload(MIRROR_ID, _payouts(1, 0));
        payload.logIndex = uint256(type(uint64).max) + 1;
        _expectAtomicFailure(MIRROR_ID, _encode(payload));
    }

    function test_MalformedPayloadRevertsAtomically() public {
        _expectAtomicFailure(MIRROR_ID, hex"deadbeef");
    }

    function test_NonCanonicalTrailingBytesRevertAtomically() public {
        bytes memory canonical = _encode(_payload(MIRROR_ID, _payouts(1, 0)));
        _expectAtomicFailure(MIRROR_ID, bytes.concat(canonical, bytes32(uint256(1))));
    }

    function test_CallbackGasFailureLeavesNoSettlementOrProgress() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(MIRROR_ID, 1, SOURCE_BLOCK, _encode(_payload(MIRROR_ID, _payouts(1, 0))), 1);
        _assertUndelivered(MIRROR_ID, conditionId);
    }

    function test_SecondSettlementCannotOverwriteTerminalState() public {
        bytes memory first = _encode(_payload(MIRROR_ID, _payouts(1, 0)));
        _record(MIRROR_ID, 1, SOURCE_BLOCK, first, CALLBACK_GAS_LIMIT);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(MIRROR_ID, 2, SOURCE_BLOCK + 1, _encode(_payload(MIRROR_ID, _payouts(0, 1))), CALLBACK_GAS_LIMIT);

        (IPolymarketSettlementResolver.ObservationStatus status, uint8 winningSlot, uint128 nonce,,,) =
            resolver.getSettlementObservation(MIRROR_ID, conditionId);
        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.ResolvedWinner));
        assertEq(winningSlot, 0);
        assertEq(nonce, 1);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_POLYMARKET_SETTLEMENT, MIRROR_ID), 1);
    }

    function _expectAtomicFailure(
        uint256 sourceId,
        bytes memory payload
    ) internal {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(sourceId, 1, SOURCE_BLOCK, payload, CALLBACK_GAS_LIMIT);
        _assertUndelivered(sourceId, conditionId);
    }

    function _assertUndelivered(
        uint256 sourceId,
        bytes32 expectedCondition
    ) internal view {
        assertFalse(resolver.isSettlementObserved(sourceId, expectedCondition));
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_POLYMARKET_SETTLEMENT, sourceId), 0);
        assertEq(oracle.getRecord(SOURCE_TYPE_POLYMARKET_SETTLEMENT, sourceId, 1).recordedAt, 0);
    }

    function _record(
        uint256 sourceId,
        uint128 nonce,
        uint256 sourcePosition,
        bytes memory payload,
        uint256 callbackGasLimit
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.record(SOURCE_TYPE_POLYMARKET_SETTLEMENT, sourceId, nonce, sourcePosition, payload, callbackGasLimit);
    }

    function _payload(
        uint256 mirrorId,
        uint256[] memory payouts
    ) internal view returns (PolymarketSettlementResolver.PolymarketSettlementPayload memory) {
        return PolymarketSettlementResolver.PolymarketSettlementPayload({
            mirrorId: mirrorId,
            polygonChainId: POLYGON_CHAIN_ID,
            ctf: CTF,
            oracle: UMA_ORACLE,
            conditionId: conditionId,
            questionId: QUESTION_ID,
            outcomeSlotCount: 2,
            payoutNumerators: payouts,
            txHash: TX_HASH,
            logIndex: LOG_INDEX,
            settlementKind: SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION
        });
    }

    function _encode(
        PolymarketSettlementResolver.PolymarketSettlementPayload memory payload
    ) internal pure returns (bytes memory) {
        return abi.encode(payload);
    }

    function _conditionId(
        address conditionOracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(conditionOracle, questionId, outcomeSlotCount));
    }

    function _payouts(
        uint256 first,
        uint256 second
    ) internal pure returns (uint256[] memory payouts) {
        payouts = new uint256[](2);
        payouts[0] = first;
        payouts[1] = second;
    }
}
