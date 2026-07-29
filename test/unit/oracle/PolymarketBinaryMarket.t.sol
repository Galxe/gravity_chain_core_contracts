// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { IPolymarketSettlementResolver } from "../../../src/oracle/resolver/IPolymarketSettlementResolver.sol";
import { PolymarketSettlementResolver } from "../../../src/oracle/resolver/PolymarketSettlementResolver.sol";
import { PolymarketBinaryMarket } from "../../../src/oracle/market/PolymarketBinaryMarket.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { MockGToken } from "../../utils/MockGToken.sol";
import { FeeOnTransferToken } from "../../utils/FeeOnTransferToken.sol";

contract ReentrantCollateral is MockGToken {
    enum Attack {
        None,
        PlaceBet,
        Claim,
        Refund
    }

    PolymarketBinaryMarket private _market;
    uint256 private _marketId;
    Attack private _attack;
    bool private _insideHook;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes4 public reentryRevertSelector;

    function configureAttack(
        PolymarketBinaryMarket market,
        uint256 marketId,
        Attack attack
    ) external {
        _market = market;
        _marketId = marketId;
        _attack = attack;
        reentryAttempted = false;
        reentrySucceeded = false;
        reentryRevertSelector = bytes4(0);
        _approve(address(this), address(market), type(uint256).max);
    }

    function placeBet(
        uint8 outcome,
        uint256 amount
    ) external {
        _market.placeBet(_marketId, outcome, amount);
    }

    function claim() external returns (uint256 amount) {
        return _market.claim(_marketId);
    }

    function refund() external returns (uint256 amount) {
        return _market.refund(_marketId);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);
        if (_attack == Attack.None || _insideHook || (from != address(this) && to != address(this))) return;

        _insideHook = true;
        reentryAttempted = true;

        bytes memory callData;
        if (_attack == Attack.PlaceBet) {
            callData = abi.encodeCall(
                PolymarketBinaryMarket.placeBet,
                (_marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), uint256(1))
            );
        } else if (_attack == Attack.Claim) {
            callData = abi.encodeCall(PolymarketBinaryMarket.claim, (_marketId));
        } else {
            callData = abi.encodeCall(PolymarketBinaryMarket.refund, (_marketId));
        }

        bytes memory returnData;
        (reentrySucceeded, returnData) = address(_market).call(callData);
        if (returnData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(returnData, 0x20))
            }
            reentryRevertSelector = selector;
        }
        _insideHook = false;
    }
}

contract MockBinaryPolymarketResolver is IPolymarketSettlementResolver {
    address public constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;

    bytes32 public constant QUESTION_ID = 0x49a5e94a4b5a400dcd720ca1875fcd49ba55c303e43bf091bc175df72f74f501;
    bytes32 public constant SETTLEMENT_TX_HASH = 0x97828bf9110f78c07f1ad5cff5415875b67b3fe032e19ee6aa2317355861aab2;

    uint256 public constant SETTLEMENT_LOG_INDEX = 2_077;

    struct MockSettlement {
        bool exists;
        ObservationStatus status;
        uint8 winningSlot;
        uint64 recordedAt;
        uint256 polygonChainId;
        address ctf;
        uint256 outcomeSlotCount;
        uint8 settlementKind;
        uint256[] payoutNumerators;
    }

    struct MockMirrorConfig {
        bool exists;
        uint256 polygonChainId;
        address ctf;
        bytes32 conditionId;
        uint256 outcomeSlotCount;
    }

    mapping(uint256 mirrorId => MockMirrorConfig config) private _mirrorConfigs;
    mapping(uint256 mirrorId => mapping(bytes32 conditionId => MockSettlement settlement)) private _settlements;

    function setMirrorConfig(
        uint256 mirrorId,
        uint256 polygonChainId,
        address ctf,
        bytes32 conditionId,
        uint256 outcomeSlotCount
    ) external {
        _mirrorConfigs[mirrorId] = MockMirrorConfig(true, polygonChainId, ctf, conditionId, outcomeSlotCount);
    }

    function getMirrorConfig(
        uint256 mirrorId
    ) external view returns (bool, uint256, address, bytes32, uint256) {
        MockMirrorConfig storage config = _mirrorConfigs[mirrorId];
        return (config.exists, config.polygonChainId, config.ctf, config.conditionId, config.outcomeSlotCount);
    }

    function setSettlement(
        uint256 mirrorId,
        bytes32 conditionId,
        uint256 polygonChainId,
        address ctf,
        uint256 outcomeSlotCount,
        uint8 settlementKind,
        uint256[] memory payoutNumerators
    ) external {
        MockSettlement storage settlement = _settlements[mirrorId][conditionId];
        settlement.exists = true;
        settlement.recordedAt = uint64(block.timestamp);
        settlement.polygonChainId = polygonChainId;
        settlement.ctf = ctf;
        settlement.outcomeSlotCount = outcomeSlotCount;
        settlement.settlementKind = settlementKind;
        settlement.status = ObservationStatus.Invalid;
        settlement.winningSlot = type(uint8).max;

        delete settlement.payoutNumerators;
        uint256 positivePayoutCount;
        for (uint256 i; i < payoutNumerators.length;) {
            settlement.payoutNumerators.push(payoutNumerators[i]);
            if (payoutNumerators[i] > 0) {
                ++positivePayoutCount;
                if (positivePayoutCount == 1) settlement.winningSlot = uint8(i);
            }
            unchecked {
                ++i;
            }
        }

        MockMirrorConfig storage config = _mirrorConfigs[mirrorId];
        if (
            config.exists && polygonChainId == config.polygonChainId && ctf == config.ctf
                && conditionId == config.conditionId && outcomeSlotCount == config.outcomeSlotCount
                && payoutNumerators.length == outcomeSlotCount && settlementKind == 1 && positivePayoutCount > 0
        ) {
            settlement.status =
                positivePayoutCount == 1 ? ObservationStatus.ResolvedWinner : ObservationStatus.ResolvedVoidable;
            if (positivePayoutCount > 1) settlement.winningSlot = type(uint8).max;
        }
    }

    function setRecordedAt(
        uint256 mirrorId,
        bytes32 conditionId,
        uint64 recordedAt
    ) external {
        _settlements[mirrorId][conditionId].recordedAt = recordedAt;
    }

    function getSettlement(
        uint256 mirrorId,
        bytes32 conditionId
    )
        external
        view
        returns (
            bool exists,
            uint128 nonce,
            uint256 polygonChainId,
            address ctf,
            address oracle,
            bytes32 questionId,
            uint256 outcomeSlotCount,
            bytes32 txHash,
            uint256 logIndex,
            uint8 settlementKind
        )
    {
        MockSettlement storage settlement = _settlements[mirrorId][conditionId];
        return (
            settlement.exists,
            1,
            settlement.polygonChainId,
            settlement.ctf,
            UMA_ORACLE,
            QUESTION_ID,
            settlement.outcomeSlotCount,
            SETTLEMENT_TX_HASH,
            SETTLEMENT_LOG_INDEX,
            settlement.settlementKind
        );
    }

    function isSettlementObserved(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (bool observed) {
        return _settlements[mirrorId][conditionId].exists;
    }

    function getSettlementObservation(
        uint256 mirrorId,
        bytes32 conditionId
    )
        external
        view
        returns (
            IPolymarketSettlementResolver.ObservationStatus status,
            uint8 winningSlot,
            uint128 nonce,
            uint64 recordedAt,
            bytes32 txHash,
            uint256 logIndex
        )
    {
        MockSettlement storage settlement = _settlements[mirrorId][conditionId];
        if (!settlement.exists) {
            return (IPolymarketSettlementResolver.ObservationStatus.None, type(uint8).max, 0, 0, bytes32(0), 0);
        }
        return (
            settlement.status,
            settlement.winningSlot,
            1,
            settlement.recordedAt,
            SETTLEMENT_TX_HASH,
            SETTLEMENT_LOG_INDEX
        );
    }

    function getPayoutNumerators(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (uint256[] memory) {
        return _settlements[mirrorId][conditionId].payoutNumerators;
    }
}

contract PolymarketBinaryMarketTest is Test {
    bytes4 internal constant REENTRANCY_ERROR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    PolymarketBinaryMarket public market;
    MockBinaryPolymarketResolver public mockResolver;
    MockGToken public collateral;

    address public governance = SystemAddresses.GOVERNANCE;
    address public systemCaller = SystemAddresses.SYSTEM_CALLER;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant MIRROR_ID = 7_202_626;
    uint256 public constant POLYGON_CHAIN_ID = 137;
    uint256 public constant CALLBACK_GAS_LIMIT = 2_000_000;
    uint256 public constant SOURCE_BLOCK = 89_222_209;
    uint256 public constant SETTLEMENT_LOG_INDEX = 2_077;
    uint256 public constant STARTING_BALANCE = 1_000 ether;

    address public constant CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address public constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;

    bytes32 public constant SPEC_HASH = keccak256("Fed July rate-cut binary mirror spec");
    bytes32 public constant CONDITION_ID = 0x2afe86f96be81a0d89ed776bedbd52d1c75bc47b49e6f0f791ddd009f52faf23;
    bytes32 public constant QUESTION_ID = 0x49a5e94a4b5a400dcd720ca1875fcd49ba55c303e43bf091bc175df72f74f501;
    bytes32 public constant SETTLEMENT_TX_HASH = 0x97828bf9110f78c07f1ad5cff5415875b67b3fe032e19ee6aa2317355861aab2;

    function setUp() public {
        vm.warp(1_700_000_000);

        market = new PolymarketBinaryMarket();
        mockResolver = new MockBinaryPolymarketResolver();
        collateral = new MockGToken();
        mockResolver.setMirrorConfig(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(carol);
    }

    function test_CreateMarketStoresBinarySettlementRef() public {
        uint256 marketId = _createMarket(address(mockResolver), _yesNoSlotMap());

        PolymarketBinaryMarket.Market memory stored = market.getMarket(marketId);
        assertEq(stored.specHash, SPEC_HASH);
        assertEq(stored.collateral, address(collateral));
        assertEq(uint8(stored.status), uint8(PolymarketBinaryMarket.MarketStatus.Open));
        assertEq(stored.winningOutcome, type(uint8).max);

        PolymarketBinaryMarket.SettlementRef memory ref = market.getSettlementRef(marketId);
        assertEq(ref.sourceType, market.SOURCE_TYPE_POLYMARKET_SETTLEMENT());
        assertEq(ref.mirrorId, MIRROR_ID);
        assertEq(ref.conditionId, CONDITION_ID);
        assertEq(ref.resolver, address(mockResolver));
        assertEq(ref.ctf, CTF);
        assertEq(ref.polygonChainId, POLYGON_CHAIN_ID);
        assertEq(ref.outcomeSlotCount, 2);
        assertEq(ref.slotToOutcome.length, 2);
        assertEq(ref.slotToOutcome[0], uint8(PolymarketBinaryMarket.BinaryOutcome.Yes));
        assertEq(ref.slotToOutcome[1], uint8(PolymarketBinaryMarket.BinaryOutcome.No));
    }

    function test_RevertForUnknownMarketId() public {
        vm.expectRevert(abi.encodeWithSelector(PolymarketBinaryMarket.MarketNotFound.selector, 999));
        market.getMarket(999);

        vm.expectRevert(abi.encodeWithSelector(PolymarketBinaryMarket.MarketNotFound.selector, 999));
        market.lockMarket(999);
    }

    function test_RevertWhenCreateMarketRefInvalid() public {
        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(mockResolver), _yesNoSlotMap());
        params.settlementRef.sourceType = 7;

        vm.expectRevert(PolymarketBinaryMarket.InvalidSettlementRef.selector);
        vm.prank(governance);
        market.createMarket(params);

        params = _createParams(address(mockResolver), _yesNoSlotMap());
        params.settlementRef.slotToOutcome[1] = params.settlementRef.slotToOutcome[0];

        vm.expectRevert(PolymarketBinaryMarket.InvalidSettlementRef.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenCreateMarketTimeInvalid() public {
        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(mockResolver), _yesNoSlotMap());
        params.closesAt = params.opensAt;

        vm.expectRevert(PolymarketBinaryMarket.InvalidMarketTime.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenSettlementRefDoesNotMatchRegisteredMirror() public {
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();
        vm.prank(governance);
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);

        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(resolver), _yesNoSlotMap());
        params.settlementRef.ctf = address(0xBEEF);

        vm.expectRevert(PolymarketBinaryMarket.InvalidSettlementRef.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenResolverMirrorIsNotRegistered() public {
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();
        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(resolver), _yesNoSlotMap());

        vm.expectRevert(PolymarketBinaryMarket.InvalidSettlementRef.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenCreatingMarketForResolvedCondition() public {
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);
        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(mockResolver), _yesNoSlotMap());

        vm.expectRevert(PolymarketBinaryMarket.SettlementAlreadyAvailable.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenBettingAfterSettlementBecomesAvailable() public {
        uint256 marketId = _createMarket(address(mockResolver), _yesNoSlotMap());
        _placeBet(alice, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 100 ether);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);

        vm.expectRevert(PolymarketBinaryMarket.SettlementAlreadyAvailable.selector);
        vm.prank(bob);
        market.placeBet(marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 1 ether);

        PolymarketBinaryMarket.Market memory stored = market.getMarket(marketId);
        assertEq(stored.totalPool, 100 ether);
        assertEq(collateral.balanceOf(bob), STARTING_BALANCE);
    }

    function test_RevertWhenCreatingMarketAfterSettlementPayloadIsStored() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.prank(governance);
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);

        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, _resolverPayload(_singleWinningPayout(0)), 0);

        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(resolver), _yesNoSlotMap());
        vm.expectRevert(PolymarketBinaryMarket.SettlementAlreadyAvailable.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenBettingAfterSettlementPayloadIsStored() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.prank(governance);
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);

        uint256 marketId = _createMarket(address(resolver), _yesNoSlotMap());
        _placeBet(alice, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 100 ether);

        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, _resolverPayload(_singleWinningPayout(0)), 0);

        assertTrue(resolver.isSettlementObserved(MIRROR_ID, CONDITION_ID));
        vm.expectRevert(PolymarketBinaryMarket.SettlementAlreadyAvailable.selector);
        vm.prank(bob);
        market.placeBet(marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 1 ether);

        assertEq(market.getMarket(marketId).totalPool, 100 ether);
        assertEq(collateral.balanceOf(bob), STARTING_BALANCE);
    }

    function test_FinalizeMarketMapsReviewedSlotToYesNoOutcome() public {
        uint8[] memory slotMap = _noYesSlotMap();
        uint256 marketId = _createFundedLockedMarket(address(mockResolver), slotMap);
        _mockSettlement(_singleWinningPayout(1), POLYGON_CHAIN_ID, CTF, 2, 1);

        market.finalizeMarket(marketId);

        PolymarketBinaryMarket.Market memory stored = market.getMarket(marketId);
        assertEq(uint8(stored.status), uint8(PolymarketBinaryMarket.MarketStatus.Settled));
        assertEq(stored.winningOutcome, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes));
        assertEq(market.claimable(marketId, alice), 0);
        assertEq(market.claimable(marketId, bob), 240 ether);
        assertEq(market.claimable(marketId, carol), 360 ether);
    }

    function test_ClaimSplitsPoolProRataAndRejectsDuplicateOrLoser() public {
        uint256 marketId = _createMarket(address(mockResolver), _yesNoSlotMap());
        _placeBet(alice, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 100 ether);
        _placeBet(bob, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 300 ether);
        _placeBet(carol, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 600 ether);
        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);
        market.finalizeMarket(marketId);

        assertEq(market.claimable(marketId, alice), 250 ether);
        assertEq(market.claimable(marketId, bob), 750 ether);
        assertEq(market.claimable(marketId, carol), 0);

        vm.prank(alice);
        assertEq(market.claim(marketId), 250 ether);
        assertEq(collateral.balanceOf(alice), STARTING_BALANCE - 100 ether + 250 ether);

        vm.expectRevert(PolymarketBinaryMarket.NothingToClaim.selector);
        vm.prank(alice);
        market.claim(marketId);

        vm.expectRevert(PolymarketBinaryMarket.NothingToClaim.selector);
        vm.prank(carol);
        market.claim(marketId);

        vm.prank(bob);
        assertEq(market.claim(marketId), 750 ether);
        assertEq(collateral.balanceOf(address(market)), 0);
    }

    function test_RejectsFeeOnTransferCollateralWithoutChangingAccounting() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(alice, 100 ether);
        vm.prank(alice);
        feeToken.approve(address(market), 100 ether);

        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(mockResolver), _yesNoSlotMap());
        params.collateral = address(feeToken);
        vm.prank(governance);
        uint256 marketId = market.createMarket(params);

        vm.expectRevert(
            abi.encodeWithSelector(PolymarketBinaryMarket.InvalidCollateralTransfer.selector, 100 ether, 99 ether)
        );
        vm.prank(alice);
        market.placeBet(marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 100 ether);

        assertEq(market.getMarket(marketId).totalPool, 0);
        assertEq(feeToken.balanceOf(alice), 100 ether);
        assertEq(feeToken.balanceOf(address(market)), 0);
    }

    function test_RejectsFeeOnTransferPayoutWithoutMarkingClaimed() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.setFeeEnabled(false);
        feeToken.mint(alice, 100 ether);
        vm.prank(alice);
        feeToken.approve(address(market), 100 ether);

        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(mockResolver), _yesNoSlotMap());
        params.collateral = address(feeToken);
        vm.prank(governance);
        uint256 marketId = market.createMarket(params);

        vm.prank(alice);
        market.placeBet(marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 100 ether);
        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);
        market.finalizeMarket(marketId);

        feeToken.setFeeEnabled(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolymarketBinaryMarket.InvalidCollateralPayout.selector, 100 ether, 99 ether, 100 ether
            )
        );
        vm.prank(alice);
        market.claim(marketId);

        assertFalse(market.claimed(marketId, alice));
        assertEq(feeToken.balanceOf(alice), 0);
        assertEq(feeToken.balanceOf(address(market)), 100 ether);
    }

    function test_ReentrantCollateralCannotReenterPlaceBet() public {
        ReentrantCollateral token = new ReentrantCollateral();
        uint256 marketId = _createMarketWithCollateral(address(token));
        token.mint(address(token), 100 ether);
        token.configureAttack(market, marketId, ReentrantCollateral.Attack.PlaceBet);

        token.placeBet(uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 100 ether);

        _assertReentryBlocked(token);
        assertEq(market.userStake(marketId, address(token), uint8(PolymarketBinaryMarket.BinaryOutcome.Yes)), 100 ether);
        assertEq(market.getMarket(marketId).totalPool, 100 ether);
        assertEq(token.balanceOf(address(market)), 100 ether);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_ReentrantCollateralCannotClaimTwice() public {
        ReentrantCollateral token = new ReentrantCollateral();
        uint256 marketId = _createMarketWithCollateral(address(token));
        token.mint(address(token), 100 ether);
        token.configureAttack(market, marketId, ReentrantCollateral.Attack.PlaceBet);
        token.placeBet(uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 100 ether);

        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        market.placeBet(marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 100 ether);

        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);
        market.finalizeMarket(marketId);

        token.configureAttack(market, marketId, ReentrantCollateral.Attack.Claim);
        assertEq(token.claim(), 200 ether);

        _assertReentryBlocked(token);
        assertTrue(market.claimed(marketId, address(token)));
        assertEq(token.balanceOf(address(token)), 200 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_ReentrantCollateralCannotRefundTwice() public {
        ReentrantCollateral token = new ReentrantCollateral();
        uint256 marketId = _createMarketWithCollateral(address(token));
        token.mint(address(token), 100 ether);
        token.configureAttack(market, marketId, ReentrantCollateral.Attack.PlaceBet);
        token.placeBet(uint8(PolymarketBinaryMarket.BinaryOutcome.No), 100 ether);

        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);
        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Voided));

        token.configureAttack(market, marketId, ReentrantCollateral.Attack.Refund);
        assertEq(token.refund(), 100 ether);

        _assertReentryBlocked(token);
        assertTrue(market.claimed(marketId, address(token)));
        assertEq(token.balanceOf(address(token)), 100 ether);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_FinalizeRequiresCanonicalTerminalObservation() public {
        uint256 missingMarketId = _createFundedLockedMarket(address(mockResolver), _yesNoSlotMap());
        vm.expectRevert(PolymarketBinaryMarket.SettlementUnavailable.selector);
        market.finalizeMarket(missingMarketId);

        uint256 ambiguousMarketId = _createFundedLockedMarket(address(mockResolver), _yesNoSlotMap());
        uint256[] memory ambiguous = new uint256[](2);
        ambiguous[0] = 1;
        ambiguous[1] = 1;
        _mockSettlement(ambiguous, POLYGON_CHAIN_ID, CTF, 2, 1);

        market.finalizeMarket(ambiguousMarketId);
        assertEq(uint8(market.getMarket(ambiguousMarketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Voided));

        MockBinaryPolymarketResolver mismatchResolver = new MockBinaryPolymarketResolver();
        mismatchResolver.setMirrorConfig(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);
        uint256 mismatchMarketId = _createFundedLockedMarket(address(mismatchResolver), _yesNoSlotMap());
        mismatchResolver.setSettlement(MIRROR_ID, CONDITION_ID, 1, CTF, 2, 1, _singleWinningPayout(0));

        vm.expectRevert(PolymarketBinaryMarket.SettlementUnavailable.selector);
        market.finalizeMarket(mismatchMarketId);
    }

    function test_NoWinningStakeVoidsAndRefunds() public {
        uint256 marketId = _createMarket(address(mockResolver), _yesNoSlotMap());
        _placeBet(alice, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 100 ether);
        _placeBet(carol, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 200 ether);
        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);

        market.finalizeMarket(marketId);

        PolymarketBinaryMarket.Market memory stored = market.getMarket(marketId);
        assertEq(uint8(stored.status), uint8(PolymarketBinaryMarket.MarketStatus.Voided));

        vm.prank(alice);
        assertEq(market.refund(marketId), 100 ether);
        assertEq(collateral.balanceOf(alice), STARTING_BALANCE);

        vm.prank(carol);
        assertEq(market.refund(marketId), 200 ether);
        assertEq(collateral.balanceOf(carol), STARTING_BALANCE);
    }

    function test_UnresolvedMarketRemainsLockedIndefinitely() public {
        uint256 marketId = _createFundedLockedMarket(address(mockResolver), _yesNoSlotMap());
        vm.warp(block.timestamp + 10 * 365 days);

        vm.expectRevert(PolymarketBinaryMarket.SettlementUnavailable.selector);
        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Locked));

        vm.prank(governance);
        (bool success,) = address(market).call(abi.encodeWithSignature("voidMarket(uint256)", marketId));
        assertFalse(success);
    }

    function test_CanonicalSettlementCanFinalizeYearsAfterMarketCloses() public {
        uint256 marketId = _createFundedLockedMarket(address(mockResolver), _yesNoSlotMap());
        vm.warp(block.timestamp + 10 * 365 days);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);

        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Settled));
    }

    function test_RecordedAtIsAuditMetadataOnly() public {
        uint256 marketId = _createFundedLockedMarket(address(mockResolver), _yesNoSlotMap());
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 2, 1);
        mockResolver.setRecordedAt(MIRROR_ID, CONDITION_ID, type(uint64).max);

        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Settled));
    }

    function test_PolymarketNonUniquePayoutVoidsAndRefunds() public {
        uint256 marketId = _createFundedLockedMarket(address(mockResolver), _yesNoSlotMap());
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 1;
        _mockSettlement(payouts, POLYGON_CHAIN_ID, CTF, 2, 1);

        vm.prank(alice);
        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Voided));

        vm.prank(alice);
        assertEq(market.refund(marketId), 100 ether);
        vm.prank(bob);
        assertEq(market.refund(marketId), 200 ether);
        vm.prank(carol);
        assertEq(market.refund(marketId), 300 ether);
        assertEq(collateral.balanceOf(address(market)), 0);
    }

    function test_PendingPayloadRemainsLockedUntilReplay() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.startPrank(governance);
        oracle.setDefaultCallback(market.SOURCE_TYPE_POLYMARKET_SETTLEMENT(), address(resolver));
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);
        vm.stopPrank();

        uint256 marketId = _createFundedLockedMarket(address(resolver), _yesNoSlotMap());
        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, _resolverPayload(_singleWinningPayout(0)), 1);

        (IPolymarketSettlementResolver.ObservationStatus status,,,,,) =
            resolver.getSettlementObservation(MIRROR_ID, CONDITION_ID);
        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.PendingValid));

        vm.warp(block.timestamp + 10 * 365 days);
        vm.expectRevert(PolymarketBinaryMarket.SettlementUnavailable.selector);
        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Locked));

        resolver.replaySettlement(MIRROR_ID, 1);
        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Settled));
    }

    function test_InvalidStoredPayloadRemainsLockedIndefinitely() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.startPrank(governance);
        oracle.setDefaultCallback(market.SOURCE_TYPE_POLYMARKET_SETTLEMENT(), address(resolver));
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);
        vm.stopPrank();

        uint256 marketId = _createFundedLockedMarket(address(resolver), _yesNoSlotMap());
        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, hex"deadbeef", CALLBACK_GAS_LIMIT);

        (IPolymarketSettlementResolver.ObservationStatus status,,,,,) =
            resolver.getSettlementObservation(MIRROR_ID, CONDITION_ID);
        assertEq(uint8(status), uint8(IPolymarketSettlementResolver.ObservationStatus.Invalid));

        vm.warp(block.timestamp + 10 * 365 days);
        vm.expectRevert(PolymarketBinaryMarket.SettlementUnavailable.selector);
        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Locked));
    }

    function test_IntegrationSettlesFromNativeOracleAndRealResolver() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.startPrank(governance);
        oracle.setDefaultCallback(market.SOURCE_TYPE_POLYMARKET_SETTLEMENT(), address(resolver));
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);
        vm.stopPrank();

        uint256 marketId = _createMarket(address(resolver), _yesNoSlotMap());
        _placeBet(alice, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 100 ether);
        _placeBet(bob, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 200 ether);
        _lockMarket(marketId);

        bytes memory payload = _resolverPayload(_singleWinningPayout(0));

        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, payload, CALLBACK_GAS_LIMIT);

        market.finalizeMarket(marketId);

        PolymarketBinaryMarket.Market memory stored = market.getMarket(marketId);
        assertEq(uint8(stored.status), uint8(PolymarketBinaryMarket.MarketStatus.Settled));
        assertEq(stored.winningOutcome, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes));
        assertEq(market.claimable(marketId, alice), 300 ether);
    }

    function test_IntegrationVoidsFromCanonicalNonUniquePolymarketPayout() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.startPrank(governance);
        oracle.setDefaultCallback(market.SOURCE_TYPE_POLYMARKET_SETTLEMENT(), address(resolver));
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 2);
        vm.stopPrank();

        uint256 marketId = _createFundedLockedMarket(address(resolver), _yesNoSlotMap());
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 1;

        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, _resolverPayload(payouts), CALLBACK_GAS_LIMIT);

        market.finalizeMarket(marketId);
        assertEq(uint8(market.getMarket(marketId).status), uint8(PolymarketBinaryMarket.MarketStatus.Voided));
    }

    function _createMarket(
        address resolver,
        uint8[] memory slotToOutcome
    ) internal returns (uint256 marketId) {
        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(resolver, slotToOutcome);
        vm.prank(governance);
        marketId = market.createMarket(params);
    }

    function _createParams(
        address resolver,
        uint8[] memory slotToOutcome
    ) internal view returns (PolymarketBinaryMarket.CreateMarketParams memory params) {
        params.specHash = SPEC_HASH;
        params.opensAt = _opensAt();
        params.closesAt = _closesAt();
        params.collateral = address(collateral);
        params.settlementRef = PolymarketBinaryMarket.SettlementRef({
            sourceType: 6,
            mirrorId: MIRROR_ID,
            conditionId: CONDITION_ID,
            resolver: resolver,
            ctf: CTF,
            polygonChainId: POLYGON_CHAIN_ID,
            outcomeSlotCount: 2,
            slotToOutcome: slotToOutcome,
            mode: PolymarketBinaryMarket.SettlementMode.SingleConditionBinary
        });
    }

    function _createFundedLockedMarket(
        address resolver,
        uint8[] memory slotToOutcome
    ) internal returns (uint256 marketId) {
        marketId = _createMarket(resolver, slotToOutcome);
        _placeBet(alice, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.No), 100 ether);
        _placeBet(bob, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 200 ether);
        _placeBet(carol, marketId, uint8(PolymarketBinaryMarket.BinaryOutcome.Yes), 300 ether);
        _lockMarket(marketId);
    }

    function _createMarketWithCollateral(
        address collateralAddress
    ) internal returns (uint256 marketId) {
        PolymarketBinaryMarket.CreateMarketParams memory params = _createParams(address(mockResolver), _yesNoSlotMap());
        params.collateral = collateralAddress;
        vm.prank(governance);
        return market.createMarket(params);
    }

    function _assertReentryBlocked(
        ReentrantCollateral token
    ) internal view {
        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryRevertSelector(), REENTRANCY_ERROR);
    }

    function _placeBet(
        address user,
        uint256 marketId,
        uint8 outcome,
        uint256 amount
    ) internal {
        vm.prank(user);
        market.placeBet(marketId, outcome, amount);
    }

    function _lockMarket(
        uint256 marketId
    ) internal {
        vm.warp(_closesAt());
        market.lockMarket(marketId);
    }

    function _mockSettlement(
        uint256[] memory payouts,
        uint256 polygonChainId,
        address ctf,
        uint256 outcomeSlotCount,
        uint8 settlementKind
    ) internal {
        mockResolver.setSettlement(
            MIRROR_ID, CONDITION_ID, polygonChainId, ctf, outcomeSlotCount, settlementKind, payouts
        );
    }

    function _resolverPayload(
        uint256[] memory payouts
    ) internal pure returns (bytes memory) {
        return abi.encode(
            PolymarketSettlementResolver.PolymarketSettlementPayload({
                mirrorId: MIRROR_ID,
                polygonChainId: POLYGON_CHAIN_ID,
                ctf: CTF,
                oracle: UMA_ORACLE,
                conditionId: CONDITION_ID,
                questionId: QUESTION_ID,
                outcomeSlotCount: 2,
                payoutNumerators: payouts,
                txHash: SETTLEMENT_TX_HASH,
                logIndex: SETTLEMENT_LOG_INDEX,
                settlementKind: 1
            })
        );
    }

    function _installNativeOracle() internal returns (NativeOracle oracle) {
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
    }

    function _singleWinningPayout(
        uint8 winningSlot
    ) internal pure returns (uint256[] memory payouts) {
        payouts = new uint256[](2);
        payouts[winningSlot] = 1;
    }

    function _yesNoSlotMap() internal pure returns (uint8[] memory slotToOutcome) {
        slotToOutcome = new uint8[](2);
        slotToOutcome[0] = uint8(PolymarketBinaryMarket.BinaryOutcome.Yes);
        slotToOutcome[1] = uint8(PolymarketBinaryMarket.BinaryOutcome.No);
    }

    function _noYesSlotMap() internal pure returns (uint8[] memory slotToOutcome) {
        slotToOutcome = new uint8[](2);
        slotToOutcome[0] = uint8(PolymarketBinaryMarket.BinaryOutcome.No);
        slotToOutcome[1] = uint8(PolymarketBinaryMarket.BinaryOutcome.Yes);
    }

    function _fundAndApprove(
        address user
    ) internal {
        collateral.mint(user, STARTING_BALANCE);
        vm.prank(user);
        collateral.approve(address(market), type(uint256).max);
    }

    function _opensAt() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _closesAt() internal view returns (uint64) {
        return uint64(block.timestamp + 1 hours);
    }
}
