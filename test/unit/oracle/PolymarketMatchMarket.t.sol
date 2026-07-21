// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { IPolymarketSettlementResolver } from "../../../src/oracle/resolver/IPolymarketSettlementResolver.sol";
import { PolymarketSettlementResolver } from "../../../src/oracle/resolver/PolymarketSettlementResolver.sol";
import { PolymarketMatchMarket } from "../../../src/oracle/market/PolymarketMatchMarket.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { MockGToken } from "../../utils/MockGToken.sol";
import { FeeOnTransferToken } from "../../utils/FeeOnTransferToken.sol";

contract MockPolymarketSettlementResolver is IPolymarketSettlementResolver {
    address public constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;

    bytes32 public constant QUESTION_ID = 0x49a5e94a4b5a400dcd720ca1875fcd49ba55c303e43bf091bc175df72f74f501;
    bytes32 public constant SETTLEMENT_TX_HASH = 0x97828bf9110f78c07f1ad5cff5415875b67b3fe032e19ee6aa2317355861aab2;

    uint256 public constant SETTLEMENT_LOG_INDEX = 2_077;

    struct MockSettlement {
        bool exists;
        uint256 polygonChainId;
        address ctf;
        uint256 outcomeSlotCount;
        uint8 settlementKind;
        bytes32 txHash;
        uint256 logIndex;
        uint256[] payoutNumerators;
    }

    mapping(uint256 mirrorId => mapping(bytes32 conditionId => MockSettlement settlement)) private _settlements;

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
        settlement.polygonChainId = polygonChainId;
        settlement.ctf = ctf;
        settlement.outcomeSlotCount = outcomeSlotCount;
        settlement.settlementKind = settlementKind;
        settlement.txHash = SETTLEMENT_TX_HASH;
        settlement.logIndex = SETTLEMENT_LOG_INDEX;

        delete settlement.payoutNumerators;
        for (uint256 i; i < payoutNumerators.length;) {
            settlement.payoutNumerators.push(payoutNumerators[i]);
            unchecked {
                ++i;
            }
        }
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
            settlement.txHash,
            settlement.logIndex,
            settlement.settlementKind
        );
    }

    function isSettlementObserved(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (bool observed) {
        return _settlements[mirrorId][conditionId].exists;
    }

    function getPayoutNumerators(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (uint256[] memory) {
        return _settlements[mirrorId][conditionId].payoutNumerators;
    }
}

contract PolymarketMatchMarketTest is Test {
    PolymarketMatchMarket public market;
    MockPolymarketSettlementResolver public mockResolver;
    MockGToken public collateral;

    address public governance = SystemAddresses.GOVERNANCE;
    address public systemCaller = SystemAddresses.SYSTEM_CALLER;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant MIRROR_ID = 1_897_398;
    uint256 public constant POLYGON_CHAIN_ID = 137;
    uint256 public constant CALLBACK_GAS_LIMIT = 2_000_000;
    uint256 public constant SOURCE_BLOCK = 89_222_209;
    uint256 public constant SETTLEMENT_LOG_INDEX = 2_077;
    uint256 public constant STARTING_BALANCE = 1_000 ether;

    address public constant CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address public constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;

    bytes32 public constant SPEC_HASH = keccak256("Portugal vs Colombia three-way match market spec");
    bytes32 public constant CONDITION_ID = 0x2afe86f96be81a0d89ed776bedbd52d1c75bc47b49e6f0f791ddd009f52faf23;
    bytes32 public constant QUESTION_ID = 0x49a5e94a4b5a400dcd720ca1875fcd49ba55c303e43bf091bc175df72f74f501;
    bytes32 public constant SETTLEMENT_TX_HASH = 0x97828bf9110f78c07f1ad5cff5415875b67b3fe032e19ee6aa2317355861aab2;

    function setUp() public {
        vm.warp(1_700_000_000);

        market = new PolymarketMatchMarket();
        mockResolver = new MockPolymarketSettlementResolver();
        collateral = new MockGToken();

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(carol);
    }

    function test_CreateMarketStoresImmutableSettlementRef() public {
        uint256 marketId = _createMarket(address(mockResolver));

        PolymarketMatchMarket.Market memory stored = market.getMarket(marketId);
        assertEq(stored.specHash, SPEC_HASH);
        assertEq(stored.collateral, address(collateral));
        assertEq(uint8(stored.status), uint8(PolymarketMatchMarket.MarketStatus.Open));
        assertEq(stored.outcomeCount, market.MATCH_OUTCOME_COUNT());
        assertEq(stored.winningOutcome, type(uint8).max);

        PolymarketMatchMarket.SettlementRef memory ref = market.getSettlementRef(marketId);
        assertEq(ref.sourceType, market.SOURCE_TYPE_POLYMARKET_SETTLEMENT());
        assertEq(ref.mirrorId, MIRROR_ID);
        assertEq(ref.conditionId, CONDITION_ID);
        assertEq(ref.resolver, address(mockResolver));
        assertEq(ref.ctf, CTF);
        assertEq(ref.polygonChainId, POLYGON_CHAIN_ID);
        assertEq(ref.outcomeSlotCount, 3);
        assertEq(ref.slotToOutcome.length, 3);
        assertEq(ref.slotToOutcome[0], uint8(PolymarketMatchMarket.MatchOutcome.HomeWin));
        assertEq(ref.slotToOutcome[1], uint8(PolymarketMatchMarket.MatchOutcome.Draw));
        assertEq(ref.slotToOutcome[2], uint8(PolymarketMatchMarket.MatchOutcome.AwayWin));
    }

    function test_RevertForUnknownMarketId() public {
        vm.expectRevert(abi.encodeWithSelector(PolymarketMatchMarket.MarketNotFound.selector, 999));
        market.getMarket(999);

        vm.expectRevert(abi.encodeWithSelector(PolymarketMatchMarket.MarketNotFound.selector, 999));
        market.lockMarket(999);
    }

    function test_RevertWhenCreateMarketRefInvalid() public {
        PolymarketMatchMarket.CreateMarketParams memory params = _createParams(address(mockResolver));
        params.settlementRef.sourceType = 7;

        vm.expectRevert(PolymarketMatchMarket.InvalidSettlementRef.selector);
        vm.prank(governance);
        market.createMarket(params);

        params = _createParams(address(mockResolver));
        params.settlementRef.slotToOutcome[2] = params.settlementRef.slotToOutcome[1];

        vm.expectRevert(PolymarketMatchMarket.InvalidSettlementRef.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenCreateMarketTimeInvalid() public {
        PolymarketMatchMarket.CreateMarketParams memory params = _createParams(address(mockResolver));
        params.closesAt = params.opensAt;

        vm.expectRevert(PolymarketMatchMarket.InvalidMarketTime.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenCreatingMarketForResolvedCondition() public {
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 3, 1);
        PolymarketMatchMarket.CreateMarketParams memory params = _createParams(address(mockResolver));

        vm.expectRevert(PolymarketMatchMarket.SettlementAlreadyAvailable.selector);
        vm.prank(governance);
        market.createMarket(params);
    }

    function test_RevertWhenBettingAfterSettlementBecomesAvailable() public {
        uint256 marketId = _createMarket(address(mockResolver));
        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw), 100 ether);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 3, 1);

        vm.expectRevert(PolymarketMatchMarket.SettlementAlreadyAvailable.selector);
        vm.prank(bob);
        market.placeBet(marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 1 ether);

        PolymarketMatchMarket.Market memory stored = market.getMarket(marketId);
        assertEq(stored.totalPool, 100 ether);
        assertEq(collateral.balanceOf(bob), STARTING_BALANCE);
    }

    function test_RevertWhenBettingAfterSettlementPayloadIsStored() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.prank(governance);
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 3);

        uint256 marketId = _createMarket(address(resolver));
        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw), 100 ether);

        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, _resolverPayload(_singleWinningPayout(0)), 0);

        assertTrue(resolver.isSettlementObserved(MIRROR_ID, CONDITION_ID));
        vm.expectRevert(PolymarketMatchMarket.SettlementAlreadyAvailable.selector);
        vm.prank(bob);
        market.placeBet(marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 1 ether);

        assertEq(market.getMarket(marketId).totalPool, 100 ether);
        assertEq(collateral.balanceOf(bob), STARTING_BALANCE);
    }

    function test_PlaceBetUpdatesEscrowAndRejectsAfterClose() public {
        uint256 marketId = _createMarket(address(mockResolver));

        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 100 ether);
        _placeBet(bob, marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw), 200 ether);

        assertEq(market.userStake(marketId, alice, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin)), 100 ether);
        assertEq(market.outcomeTotal(marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw)), 200 ether);
        assertEq(collateral.balanceOf(address(market)), 300 ether);
        assertEq(collateral.balanceOf(alice), STARTING_BALANCE - 100 ether);

        vm.warp(_closesAt());
        vm.expectRevert(PolymarketMatchMarket.MarketNotOpen.selector);
        vm.prank(carol);
        market.placeBet(marketId, uint8(PolymarketMatchMarket.MatchOutcome.AwayWin), 100 ether);
    }

    function test_LockMarketRequiresClose() public {
        uint256 marketId = _createMarket(address(mockResolver));

        vm.expectRevert(PolymarketMatchMarket.MarketNotOpen.selector);
        market.lockMarket(marketId);

        vm.warp(_closesAt());
        market.lockMarket(marketId);

        PolymarketMatchMarket.Market memory stored = market.getMarket(marketId);
        assertEq(uint8(stored.status), uint8(PolymarketMatchMarket.MarketStatus.Locked));
    }

    function test_SettleMarketMapsEachThreeWayPayoutSlot() public {
        uint8[3] memory expectedOutcomes = [
            uint8(PolymarketMatchMarket.MatchOutcome.HomeWin),
            uint8(PolymarketMatchMarket.MatchOutcome.Draw),
            uint8(PolymarketMatchMarket.MatchOutcome.AwayWin)
        ];

        for (uint8 slot; slot < 3;) {
            MockPolymarketSettlementResolver slotResolver = new MockPolymarketSettlementResolver();
            uint256 marketId = _createFundedLockedMarket(address(slotResolver));
            slotResolver.setSettlement(MIRROR_ID, CONDITION_ID, POLYGON_CHAIN_ID, CTF, 3, 1, _singleWinningPayout(slot));

            market.settleMarket(marketId);

            PolymarketMatchMarket.Market memory stored = market.getMarket(marketId);
            assertEq(uint8(stored.status), uint8(PolymarketMatchMarket.MarketStatus.Settled));
            assertEq(stored.winningOutcome, expectedOutcomes[slot]);

            unchecked {
                ++slot;
            }
        }
    }

    function test_RevertWhenSettlementUnavailableOrAmbiguous() public {
        uint256 missingMarketId = _createFundedLockedMarket(address(mockResolver));
        vm.expectRevert(PolymarketMatchMarket.SettlementUnavailable.selector);
        market.settleMarket(missingMarketId);

        uint256 ambiguousMarketId = _createFundedLockedMarket(address(mockResolver));
        uint256[] memory ambiguous = new uint256[](3);
        ambiguous[0] = 1;
        ambiguous[1] = 1;
        _mockSettlement(ambiguous, POLYGON_CHAIN_ID, CTF, 3, 1);

        vm.expectRevert(PolymarketMatchMarket.AmbiguousPayout.selector);
        market.settleMarket(ambiguousMarketId);
    }

    function test_RevertWhenSettlementMetadataMismatch() public {
        uint256 marketId = _createFundedLockedMarket(address(mockResolver));
        _mockSettlement(_singleWinningPayout(1), 1, CTF, 3, 1);

        vm.expectRevert(PolymarketMatchMarket.SettlementMismatch.selector);
        market.settleMarket(marketId);

        MockPolymarketSettlementResolver ctfMismatchResolver = new MockPolymarketSettlementResolver();
        marketId = _createFundedLockedMarket(address(ctfMismatchResolver));
        ctfMismatchResolver.setSettlement(
            MIRROR_ID, CONDITION_ID, POLYGON_CHAIN_ID, address(0xBEEF), 3, 1, _singleWinningPayout(1)
        );

        vm.expectRevert(PolymarketMatchMarket.SettlementMismatch.selector);
        market.settleMarket(marketId);
    }

    function test_ClaimSplitsPoolProRataAndRejectsDuplicateOrLoser() public {
        uint256 marketId = _createMarket(address(mockResolver));
        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw), 100 ether);
        _placeBet(bob, marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw), 300 ether);
        _placeBet(carol, marketId, uint8(PolymarketMatchMarket.MatchOutcome.AwayWin), 600 ether);
        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(1), POLYGON_CHAIN_ID, CTF, 3, 1);
        market.settleMarket(marketId);

        assertEq(market.claimable(marketId, alice), 250 ether);
        assertEq(market.claimable(marketId, bob), 750 ether);
        assertEq(market.claimable(marketId, carol), 0);

        vm.prank(alice);
        assertEq(market.claim(marketId), 250 ether);
        assertEq(collateral.balanceOf(alice), STARTING_BALANCE - 100 ether + 250 ether);

        vm.expectRevert(PolymarketMatchMarket.NothingToClaim.selector);
        vm.prank(alice);
        market.claim(marketId);

        vm.expectRevert(PolymarketMatchMarket.NothingToClaim.selector);
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

        PolymarketMatchMarket.CreateMarketParams memory params = _createParams(address(mockResolver));
        params.collateral = address(feeToken);
        vm.prank(governance);
        uint256 marketId = market.createMarket(params);

        vm.expectRevert(
            abi.encodeWithSelector(PolymarketMatchMarket.InvalidCollateralTransfer.selector, 100 ether, 99 ether)
        );
        vm.prank(alice);
        market.placeBet(marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 100 ether);

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

        PolymarketMatchMarket.CreateMarketParams memory params = _createParams(address(mockResolver));
        params.collateral = address(feeToken);
        vm.prank(governance);
        uint256 marketId = market.createMarket(params);

        vm.prank(alice);
        market.placeBet(marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 100 ether);
        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(0), POLYGON_CHAIN_ID, CTF, 3, 1);
        market.settleMarket(marketId);

        feeToken.setFeeEnabled(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolymarketMatchMarket.InvalidCollateralPayout.selector, 100 ether, 99 ether, 100 ether
            )
        );
        vm.prank(alice);
        market.claim(marketId);

        assertFalse(market.claimed(marketId, alice));
        assertEq(feeToken.balanceOf(alice), 0);
        assertEq(feeToken.balanceOf(address(market)), 100 ether);
    }

    function test_NoWinningStakeVoidsAndRefunds() public {
        uint256 marketId = _createMarket(address(mockResolver));
        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 100 ether);
        _placeBet(carol, marketId, uint8(PolymarketMatchMarket.MatchOutcome.AwayWin), 200 ether);
        _lockMarket(marketId);
        _mockSettlement(_singleWinningPayout(1), POLYGON_CHAIN_ID, CTF, 3, 1);

        market.settleMarket(marketId);

        PolymarketMatchMarket.Market memory stored = market.getMarket(marketId);
        assertEq(uint8(stored.status), uint8(PolymarketMatchMarket.MarketStatus.Voided));

        vm.prank(alice);
        assertEq(market.refund(marketId), 100 ether);
        assertEq(collateral.balanceOf(alice), STARTING_BALANCE);

        vm.prank(carol);
        assertEq(market.refund(marketId), 200 ether);
        assertEq(collateral.balanceOf(carol), STARTING_BALANCE);
    }

    function test_VoidAfterOracleDeadlineEnablesRefund() public {
        uint256 marketId = _createMarket(address(mockResolver));
        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 100 ether);

        vm.expectRevert(PolymarketMatchMarket.OracleDeadlineNotReached.selector);
        vm.prank(governance);
        market.voidMarket(marketId);

        vm.warp(_oracleDeadline());
        vm.prank(governance);
        market.voidMarket(marketId);

        vm.prank(alice);
        assertEq(market.refund(marketId), 100 ether);
        assertEq(collateral.balanceOf(alice), STARTING_BALANCE);
    }

    function test_IntegrationSettlesFromNativeOracleAndRealResolver() public {
        NativeOracle oracle = _installNativeOracle();
        PolymarketSettlementResolver resolver = new PolymarketSettlementResolver();

        vm.startPrank(governance);
        oracle.setDefaultCallback(market.SOURCE_TYPE_POLYMARKET_SETTLEMENT(), address(resolver));
        resolver.registerMirror(MIRROR_ID, POLYGON_CHAIN_ID, CTF, CONDITION_ID, 3);
        vm.stopPrank();

        uint256 marketId = _createMarket(address(resolver));
        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 100 ether);
        _placeBet(bob, marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw), 200 ether);
        _placeBet(carol, marketId, uint8(PolymarketMatchMarket.MatchOutcome.AwayWin), 300 ether);
        _lockMarket(marketId);

        uint256[] memory payouts = _singleWinningPayout(2);
        bytes memory payload = _resolverPayload(payouts);

        vm.prank(systemCaller);
        oracle.record(6, MIRROR_ID, 1, SOURCE_BLOCK, payload, CALLBACK_GAS_LIMIT);

        market.settleMarket(marketId);

        PolymarketMatchMarket.Market memory stored = market.getMarket(marketId);
        assertEq(uint8(stored.status), uint8(PolymarketMatchMarket.MarketStatus.Settled));
        assertEq(stored.winningOutcome, uint8(PolymarketMatchMarket.MatchOutcome.AwayWin));
        assertEq(market.claimable(marketId, carol), 600 ether);
    }

    function _createMarket(
        address resolver
    ) internal returns (uint256 marketId) {
        PolymarketMatchMarket.CreateMarketParams memory params = _createParams(resolver);
        vm.prank(governance);
        marketId = market.createMarket(params);
    }

    function _createParams(
        address resolver
    ) internal view returns (PolymarketMatchMarket.CreateMarketParams memory params) {
        params.specHash = SPEC_HASH;
        params.opensAt = _opensAt();
        params.closesAt = _closesAt();
        params.oracleDeadline = _oracleDeadline();
        params.collateral = address(collateral);
        params.settlementRef = PolymarketMatchMarket.SettlementRef({
            sourceType: 6,
            mirrorId: MIRROR_ID,
            conditionId: CONDITION_ID,
            resolver: resolver,
            ctf: CTF,
            polygonChainId: POLYGON_CHAIN_ID,
            outcomeSlotCount: 3,
            slotToOutcome: _identitySlotMap(),
            mode: PolymarketMatchMarket.SettlementMode.SingleConditionThreeWay
        });
    }

    function _createFundedLockedMarket(
        address resolver
    ) internal returns (uint256 marketId) {
        marketId = _createMarket(resolver);
        _placeBet(alice, marketId, uint8(PolymarketMatchMarket.MatchOutcome.HomeWin), 100 ether);
        _placeBet(bob, marketId, uint8(PolymarketMatchMarket.MatchOutcome.Draw), 200 ether);
        _placeBet(carol, marketId, uint8(PolymarketMatchMarket.MatchOutcome.AwayWin), 300 ether);
        _lockMarket(marketId);
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
                outcomeSlotCount: 3,
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
        payouts = new uint256[](3);
        payouts[winningSlot] = 1;
    }

    function _identitySlotMap() internal pure returns (uint8[] memory slotToOutcome) {
        slotToOutcome = new uint8[](3);
        slotToOutcome[0] = uint8(PolymarketMatchMarket.MatchOutcome.HomeWin);
        slotToOutcome[1] = uint8(PolymarketMatchMarket.MatchOutcome.Draw);
        slotToOutcome[2] = uint8(PolymarketMatchMarket.MatchOutcome.AwayWin);
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

    function _oracleDeadline() internal view returns (uint64) {
        return uint64(block.timestamp + 2 hours);
    }
}
