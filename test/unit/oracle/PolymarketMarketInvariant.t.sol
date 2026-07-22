// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { PolymarketBinaryMarket } from "../../../src/oracle/market/PolymarketBinaryMarket.sol";
import { PolymarketMatchMarket } from "../../../src/oracle/market/PolymarketMatchMarket.sol";
import { IPolymarketSettlementResolver } from "../../../src/oracle/resolver/IPolymarketSettlementResolver.sol";
import { MockGToken } from "../../utils/MockGToken.sol";

interface IPolymarketMarketActions {
    function placeBet(
        uint256 marketId,
        uint8 outcome,
        uint256 amount
    ) external;

    function lockMarket(
        uint256 marketId
    ) external;

    function settleMarket(
        uint256 marketId
    ) external;

    function claim(
        uint256 marketId
    ) external returns (uint256 amount);

    function voidMarket(
        uint256 marketId
    ) external;

    function refund(
        uint256 marketId
    ) external returns (uint256 amount);
}

interface IPolymarketMarketAccounting {
    function outcomeTotal(
        uint256 marketId,
        uint8 outcome
    ) external view returns (uint256);

    function userStake(
        uint256 marketId,
        address user,
        uint8 outcome
    ) external view returns (uint256);

    function claimed(
        uint256 marketId,
        address user
    ) external view returns (bool);

    function claimable(
        uint256 marketId,
        address user
    ) external view returns (uint256);
}

contract InvariantPolymarketResolver is IPolymarketSettlementResolver {
    struct Settlement {
        bool exists;
        uint64 recordedAt;
        uint256 polygonChainId;
        address ctf;
        uint256 outcomeSlotCount;
        uint256[] payoutNumerators;
    }

    address internal constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;
    bytes32 internal constant QUESTION_ID = keccak256("invariant question");
    bytes32 internal constant SETTLEMENT_TX_HASH = keccak256("invariant settlement transaction");

    mapping(uint256 mirrorId => mapping(bytes32 conditionId => Settlement settlement)) private _settlements;

    function setSettlement(
        uint256 mirrorId,
        bytes32 conditionId,
        uint256 polygonChainId,
        address ctf,
        uint256 outcomeSlotCount,
        uint256[] memory payoutNumerators
    ) external {
        Settlement storage settlement = _settlements[mirrorId][conditionId];
        settlement.exists = true;
        settlement.recordedAt = uint64(block.timestamp);
        settlement.polygonChainId = polygonChainId;
        settlement.ctf = ctf;
        settlement.outcomeSlotCount = outcomeSlotCount;
        settlement.payoutNumerators = payoutNumerators;
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
    ) external view returns (ObservationStatus status, uint128 nonce, uint64 recordedAt) {
        Settlement storage settlement = _settlements[mirrorId][conditionId];
        if (!settlement.exists) return (ObservationStatus.None, 0, 0);
        return (ObservationStatus.ResolvedValid, 1, settlement.recordedAt);
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
        Settlement storage settlement = _settlements[mirrorId][conditionId];
        return (
            settlement.exists,
            1,
            settlement.polygonChainId,
            settlement.ctf,
            UMA_ORACLE,
            QUESTION_ID,
            settlement.outcomeSlotCount,
            SETTLEMENT_TX_HASH,
            0,
            1
        );
    }

    function getPayoutNumerators(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (uint256[] memory) {
        return _settlements[mirrorId][conditionId].payoutNumerators;
    }
}

contract PolymarketMarketHandler is Test {
    uint256 public constant ACTOR_COUNT = 5;
    uint256 public constant ACTOR_BALANCE = 1_000_000 ether;

    IPolymarketMarketActions public immutable market;
    InvariantPolymarketResolver public immutable resolver;
    MockGToken public immutable collateral;
    uint256 public immutable marketId;
    uint256 public immutable mirrorId;
    bytes32 public immutable conditionId;
    address public immutable ctf;
    uint64 public immutable closesAt;
    uint64 public immutable oracleDeadline;
    uint8 public immutable outcomeCount;

    address[ACTOR_COUNT] public actors;
    uint8 public phase;
    bool public invalidTransition;
    bool public settlementPrepared;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    constructor(
        address market_,
        InvariantPolymarketResolver resolver_,
        MockGToken collateral_,
        uint256 marketId_,
        uint256 mirrorId_,
        bytes32 conditionId_,
        address ctf_,
        uint64 closesAt_,
        uint64 oracleDeadline_,
        uint8 outcomeCount_
    ) {
        market = IPolymarketMarketActions(market_);
        resolver = resolver_;
        collateral = collateral_;
        marketId = marketId_;
        mirrorId = mirrorId_;
        conditionId = conditionId_;
        ctf = ctf_;
        closesAt = closesAt_;
        oracleDeadline = oracleDeadline_;
        outcomeCount = outcomeCount_;

        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = vm.addr(i + 1);
            actors[i] = actor;
            collateral_.mint(actor, ACTOR_BALANCE);
            vm.prank(actor);
            collateral_.approve(market_, type(uint256).max);
        }
    }

    function placeBet(
        uint256 actorSeed,
        uint8 outcomeSeed,
        uint96 amountSeed
    ) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 balance = collateral.balanceOf(actor);
        if (balance == 0) return;

        uint8 outcome = outcomeSeed % outcomeCount;
        uint256 amount = bound(uint256(amountSeed), 1, balance);

        vm.prank(actor);
        (bool success,) = address(market)
            .call(abi.encodeWithSelector(IPolymarketMarketActions.placeBet.selector, marketId, outcome, amount));
        if (!success) return;

        if (phase != 0) invalidTransition = true;
        totalDeposited += amount;
    }

    function lockMarket() external {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < closesAt) vm.warp(closesAt);

        (bool success,) =
            address(market).call(abi.encodeWithSelector(IPolymarketMarketActions.lockMarket.selector, marketId));
        if (!success) return;

        if (phase != 0) invalidTransition = true;
        phase = 1;
    }

    function settleMarket(
        uint8 winningSlotSeed
    ) external {
        if (phase == 1 && !settlementPrepared) {
            uint256[] memory payouts = new uint256[](outcomeCount);
            payouts[winningSlotSeed % outcomeCount] = 1;
            resolver.setSettlement(mirrorId, conditionId, 137, ctf, outcomeCount, payouts);
            settlementPrepared = true;
        }

        (bool success,) =
            address(market).call(abi.encodeWithSelector(IPolymarketMarketActions.settleMarket.selector, marketId));
        if (!success) return;

        if (phase != 1) invalidTransition = true;
        phase = 2;
    }

    function voidMarket() external {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < oracleDeadline) vm.warp(oracleDeadline);

        vm.prank(SystemAddresses.GOVERNANCE);
        (bool success,) =
            address(market).call(abi.encodeWithSelector(IPolymarketMarketActions.voidMarket.selector, marketId));
        if (!success) return;

        if (phase == 2) invalidTransition = true;
        phase = 2;
    }

    function claim(
        uint256 actorSeed
    ) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        vm.prank(actor);
        (bool success, bytes memory returnData) =
            address(market).call(abi.encodeWithSelector(IPolymarketMarketActions.claim.selector, marketId));
        if (success) totalWithdrawn += abi.decode(returnData, (uint256));
    }

    function refund(
        uint256 actorSeed
    ) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        vm.prank(actor);
        (bool success, bytes memory returnData) =
            address(market).call(abi.encodeWithSelector(IPolymarketMarketActions.refund.selector, marketId));
        if (success) totalWithdrawn += abi.decode(returnData, (uint256));
    }
}

abstract contract PolymarketMarketInvariantTestBase is StdInvariant, Test {
    uint8 internal constant STATUS_OPEN = 0;
    uint8 internal constant STATUS_LOCKED = 1;
    uint8 internal constant STATUS_SETTLED = 2;
    uint8 internal constant STATUS_VOIDED = 3;

    MockGToken internal collateral;
    InvariantPolymarketResolver internal resolver;
    PolymarketMarketHandler internal handler;
    IPolymarketMarketAccounting internal accounting;
    uint256 internal marketId;
    uint8 internal outcomeCount;
    address internal marketAddress;

    function _targetHandler() internal {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = PolymarketMarketHandler.placeBet.selector;
        selectors[1] = PolymarketMarketHandler.lockMarket.selector;
        selectors[2] = PolymarketMarketHandler.settleMarket.selector;
        selectors[3] = PolymarketMarketHandler.voidMarket.selector;
        selectors[4] = PolymarketMarketHandler.claim.selector;
        selectors[5] = PolymarketMarketHandler.refund.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function _marketSnapshot() internal view virtual returns (uint8 status, uint256 totalPool);

    function invariant_FundsAndLiabilitiesRemainConsistent() public view {
        (uint8 status, uint256 totalPool) = _marketSnapshot();
        assertEq(totalPool, handler.totalDeposited(), "market pool must equal successful deposits");
        assertEq(
            collateral.balanceOf(marketAddress) + handler.totalWithdrawn(),
            totalPool,
            "escrow plus withdrawals must equal deposits"
        );
        assertLe(handler.totalWithdrawn(), totalPool, "withdrawals must not exceed the pool");

        uint256 sumOfOutcomes;
        for (uint8 outcome; outcome < outcomeCount; ++outcome) {
            uint256 sumOfActorStakes;
            for (uint256 actorIndex; actorIndex < handler.ACTOR_COUNT(); ++actorIndex) {
                sumOfActorStakes += accounting.userStake(marketId, handler.actors(actorIndex), outcome);
            }

            uint256 outcomeStake = accounting.outcomeTotal(marketId, outcome);
            assertEq(sumOfActorStakes, outcomeStake, "actor stakes must equal outcome total");
            sumOfOutcomes += outcomeStake;
        }

        assertEq(sumOfOutcomes, totalPool, "outcome totals must equal market pool");

        uint256 outstanding;
        for (uint256 actorIndex; actorIndex < handler.ACTOR_COUNT(); ++actorIndex) {
            address actor = handler.actors(actorIndex);
            if (status == STATUS_VOIDED && !accounting.claimed(marketId, actor)) {
                for (uint8 outcome; outcome < outcomeCount; ++outcome) {
                    outstanding += accounting.userStake(marketId, actor, outcome);
                }
            } else if (status == STATUS_SETTLED) {
                outstanding += accounting.claimable(marketId, actor);
            }
        }

        if (status == STATUS_VOIDED) {
            assertEq(handler.totalWithdrawn() + outstanding, totalPool, "void refunds must preserve every stake");
        } else if (status == STATUS_SETTLED) {
            assertLe(handler.totalWithdrawn() + outstanding, totalPool, "winner liabilities must not exceed the pool");
        } else {
            assertEq(handler.totalWithdrawn(), 0, "pre-final markets cannot pay out");
        }
    }

    function invariant_StateTransitionsAreMonotonic() public view {
        (uint8 status,) = _marketSnapshot();
        assertFalse(handler.invalidTransition(), "a finalized market changed phase");

        uint8 phase = handler.phase();
        if (phase == 0) assertEq(status, STATUS_OPEN, "phase zero must remain open");
        else if (phase == 1) assertEq(status, STATUS_LOCKED, "phase one must remain locked");
        else assertTrue(status == STATUS_SETTLED || status == STATUS_VOIDED, "phase two must be terminal");
    }

    function testFuzz_VoidRefundsEveryStake(
        uint96 firstStake,
        uint96 secondStake,
        uint96 thirdStake
    ) public {
        handler.placeBet(0, 0, firstStake);
        handler.placeBet(1, 1, secondStake);
        handler.placeBet(2, 2, thirdStake);
        handler.voidMarket();

        for (uint256 actorIndex; actorIndex < handler.ACTOR_COUNT(); ++actorIndex) {
            handler.refund(actorIndex);
        }

        (uint8 status, uint256 totalPool) = _marketSnapshot();
        assertEq(status, STATUS_VOIDED);
        assertEq(handler.totalWithdrawn(), totalPool);
        assertEq(collateral.balanceOf(marketAddress), 0);
    }

    function testFuzz_WinnerPayoutsNeverExceedThePool(
        uint96 firstWinnerStake,
        uint96 secondWinnerStake,
        uint96 losingStake,
        uint8 winningOutcomeSeed
    ) public {
        uint8 winningOutcome = winningOutcomeSeed % outcomeCount;
        uint8 losingOutcome = (winningOutcome + 1) % outcomeCount;
        handler.placeBet(0, winningOutcome, firstWinnerStake);
        handler.placeBet(1, winningOutcome, secondWinnerStake);
        handler.placeBet(2, losingOutcome, losingStake);
        handler.lockMarket();
        handler.settleMarket(winningOutcome);

        (uint8 status, uint256 totalPool) = _marketSnapshot();
        assertEq(status, STATUS_SETTLED);

        uint256 outstanding =
            accounting.claimable(marketId, handler.actors(0)) + accounting.claimable(marketId, handler.actors(1));
        assertLe(outstanding, totalPool);

        handler.claim(0);
        handler.claim(1);
        handler.claim(2);
        assertLe(handler.totalWithdrawn(), totalPool);
        assertEq(collateral.balanceOf(marketAddress) + handler.totalWithdrawn(), totalPool);
    }
}

contract PolymarketBinaryMarketInvariantTest is PolymarketMarketInvariantTestBase {
    uint256 internal constant MIRROR_ID = 7_202_626;
    bytes32 internal constant CONDITION_ID = keccak256("binary invariant condition");
    bytes32 internal constant SPEC_HASH = keccak256("binary invariant market");
    address internal constant CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;

    PolymarketBinaryMarket internal binaryMarket;

    function setUp() public {
        vm.warp(1_700_000_000);
        collateral = new MockGToken();
        resolver = new InvariantPolymarketResolver();
        binaryMarket = new PolymarketBinaryMarket();
        marketAddress = address(binaryMarket);
        accounting = IPolymarketMarketAccounting(marketAddress);
        outcomeCount = 2;

        uint8[] memory slotToOutcome = new uint8[](outcomeCount);
        slotToOutcome[0] = 0;
        slotToOutcome[1] = 1;

        uint64 closesAt = uint64(block.timestamp + 1 days);
        uint64 oracleDeadline = uint64(block.timestamp + 2 days);
        PolymarketBinaryMarket.CreateMarketParams memory params = PolymarketBinaryMarket.CreateMarketParams({
            specHash: SPEC_HASH,
            opensAt: uint64(block.timestamp),
            closesAt: closesAt,
            oracleDeadline: oracleDeadline,
            collateral: address(collateral),
            settlementRef: PolymarketBinaryMarket.SettlementRef({
                sourceType: 6,
                mirrorId: MIRROR_ID,
                conditionId: CONDITION_ID,
                resolver: address(resolver),
                ctf: CTF,
                polygonChainId: 137,
                outcomeSlotCount: outcomeCount,
                slotToOutcome: slotToOutcome,
                mode: PolymarketBinaryMarket.SettlementMode.SingleConditionBinary
            })
        });

        vm.prank(SystemAddresses.GOVERNANCE);
        marketId = binaryMarket.createMarket(params);
        handler = new PolymarketMarketHandler(
            marketAddress,
            resolver,
            collateral,
            marketId,
            MIRROR_ID,
            CONDITION_ID,
            CTF,
            closesAt,
            oracleDeadline,
            outcomeCount
        );
        _targetHandler();
    }

    function _marketSnapshot() internal view override returns (uint8 status, uint256 totalPool) {
        PolymarketBinaryMarket.Market memory stored = binaryMarket.getMarket(marketId);
        return (uint8(stored.status), stored.totalPool);
    }
}

contract PolymarketMatchMarketInvariantTest is PolymarketMarketInvariantTestBase {
    uint256 internal constant MIRROR_ID = 1_897_398;
    bytes32 internal constant CONDITION_ID = keccak256("match invariant condition");
    bytes32 internal constant SPEC_HASH = keccak256("match invariant market");
    address internal constant CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;

    PolymarketMatchMarket internal matchMarket;

    function setUp() public {
        vm.warp(1_700_000_000);
        collateral = new MockGToken();
        resolver = new InvariantPolymarketResolver();
        matchMarket = new PolymarketMatchMarket();
        marketAddress = address(matchMarket);
        accounting = IPolymarketMarketAccounting(marketAddress);
        outcomeCount = 3;

        uint8[] memory slotToOutcome = new uint8[](outcomeCount);
        slotToOutcome[0] = 0;
        slotToOutcome[1] = 1;
        slotToOutcome[2] = 2;

        uint64 closesAt = uint64(block.timestamp + 1 days);
        uint64 oracleDeadline = uint64(block.timestamp + 2 days);
        PolymarketMatchMarket.CreateMarketParams memory params = PolymarketMatchMarket.CreateMarketParams({
            specHash: SPEC_HASH,
            opensAt: uint64(block.timestamp),
            closesAt: closesAt,
            oracleDeadline: oracleDeadline,
            collateral: address(collateral),
            settlementRef: PolymarketMatchMarket.SettlementRef({
                sourceType: 6,
                mirrorId: MIRROR_ID,
                conditionId: CONDITION_ID,
                resolver: address(resolver),
                ctf: CTF,
                polygonChainId: 137,
                outcomeSlotCount: outcomeCount,
                slotToOutcome: slotToOutcome,
                mode: PolymarketMatchMarket.SettlementMode.SingleConditionThreeWay
            })
        });

        vm.prank(SystemAddresses.GOVERNANCE);
        marketId = matchMarket.createMarket(params);
        handler = new PolymarketMarketHandler(
            marketAddress,
            resolver,
            collateral,
            marketId,
            MIRROR_ID,
            CONDITION_ID,
            CTF,
            closesAt,
            oracleDeadline,
            outcomeCount
        );
        _targetHandler();
    }

    function _marketSnapshot() internal view override returns (uint8 status, uint256 totalPool) {
        PolymarketMatchMarket.Market memory stored = matchMarket.getMarket(marketId);
        return (uint8(stored.status), stored.totalPool);
    }
}
