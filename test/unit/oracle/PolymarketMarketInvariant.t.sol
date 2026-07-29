// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { PolymarketBinaryMarket } from "../../../src/oracle/market/PolymarketBinaryMarket.sol";
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

    function finalizeMarket(
        uint256 marketId
    ) external;

    function claim(
        uint256 marketId
    ) external returns (uint256 amount);

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
    struct MirrorConfig {
        bool exists;
        uint256 polygonChainId;
        address ctf;
        bytes32 conditionId;
        uint256 outcomeSlotCount;
    }

    struct Settlement {
        bool exists;
        ObservationStatus status;
        uint8 winningSlot;
        uint64 recordedAt;
        uint256 polygonChainId;
        address ctf;
        uint256 outcomeSlotCount;
        uint256[] payoutNumerators;
    }

    address internal constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;
    bytes32 internal constant QUESTION_ID = keccak256("invariant question");
    bytes32 internal constant SETTLEMENT_TX_HASH = keccak256("invariant settlement transaction");

    mapping(uint256 mirrorId => MirrorConfig config) private _mirrorConfigs;
    mapping(uint256 mirrorId => mapping(bytes32 conditionId => Settlement settlement)) private _settlements;

    function setMirrorConfig(
        uint256 mirrorId,
        uint256 polygonChainId,
        address ctf,
        bytes32 conditionId,
        uint256 outcomeSlotCount
    ) external {
        _mirrorConfigs[mirrorId] = MirrorConfig(true, polygonChainId, ctf, conditionId, outcomeSlotCount);
    }

    function getMirrorConfig(
        uint256 mirrorId
    ) external view returns (bool, uint256, address, bytes32, uint256) {
        MirrorConfig storage config = _mirrorConfigs[mirrorId];
        return (config.exists, config.polygonChainId, config.ctf, config.conditionId, config.outcomeSlotCount);
    }

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

        uint256 positivePayoutCount;
        settlement.winningSlot = type(uint8).max;
        for (uint256 i; i < payoutNumerators.length; ++i) {
            if (payoutNumerators[i] > 0) {
                ++positivePayoutCount;
                if (positivePayoutCount == 1) settlement.winningSlot = uint8(i);
            }
        }
        if (positivePayoutCount == 1) settlement.status = ObservationStatus.ResolvedWinner;
        else if (positivePayoutCount > 1) settlement.status = ObservationStatus.ResolvedVoidable;
        else settlement.status = ObservationStatus.Invalid;
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
            ObservationStatus status,
            uint8 winningSlot,
            uint128 nonce,
            uint64 recordedAt,
            bytes32 txHash,
            uint256 logIndex
        )
    {
        Settlement storage settlement = _settlements[mirrorId][conditionId];
        if (!settlement.exists) return (ObservationStatus.None, type(uint8).max, 0, 0, bytes32(0), 0);
        return (settlement.status, settlement.winningSlot, 1, settlement.recordedAt, SETTLEMENT_TX_HASH, 0);
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

    function finalizeWinner(
        uint8 winningSlotSeed
    ) external {
        if (phase == 1 && !settlementPrepared) {
            uint256[] memory payouts = new uint256[](outcomeCount);
            payouts[winningSlotSeed % outcomeCount] = 1;
            resolver.setSettlement(mirrorId, conditionId, 137, ctf, outcomeCount, payouts);
            settlementPrepared = true;
        }

        _finalize();
    }

    function finalizeVoidable() external {
        if (phase == 1 && !settlementPrepared) {
            uint256[] memory payouts = new uint256[](outcomeCount);
            for (uint256 i; i < outcomeCount; ++i) {
                payouts[i] = 1;
            }
            resolver.setSettlement(mirrorId, conditionId, 137, ctf, outcomeCount, payouts);
            settlementPrepared = true;
        }

        _finalize();
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

    function _finalize() internal {
        (bool success,) =
            address(market).call(abi.encodeWithSelector(IPolymarketMarketActions.finalizeMarket.selector, marketId));
        if (!success) return;

        if (phase != 1) invalidTransition = true;
        phase = 2;
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
        selectors[2] = PolymarketMarketHandler.finalizeWinner.selector;
        selectors[3] = PolymarketMarketHandler.finalizeVoidable.selector;
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

    function testFuzz_CanonicalNonUniquePayoutRefundsEveryStake(
        uint96 firstStake,
        uint96 secondStake,
        uint96 thirdStake
    ) public {
        handler.placeBet(0, 0, firstStake);
        handler.placeBet(1, 1, secondStake);
        handler.placeBet(2, 2, thirdStake);
        handler.lockMarket();
        handler.finalizeVoidable();

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
        handler.finalizeWinner(winningOutcome);

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
        resolver.setMirrorConfig(MIRROR_ID, 137, CTF, CONDITION_ID, outcomeCount);
        PolymarketBinaryMarket.CreateMarketParams memory params = PolymarketBinaryMarket.CreateMarketParams({
            specHash: SPEC_HASH,
            opensAt: uint64(block.timestamp),
            closesAt: closesAt,
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
            marketAddress, resolver, collateral, marketId, MIRROR_ID, CONDITION_ID, CTF, closesAt, outcomeCount
        );
        _targetHandler();
    }

    function _marketSnapshot() internal view override returns (uint8 status, uint256 totalPool) {
        PolymarketBinaryMarket.Market memory stored = binaryMarket.getMarket(marketId);
        return (uint8(stored.status), stored.totalPool);
    }
}

contract PolymarketBinaryMultiMarketInvariantTest is StdInvariant, Test {
    uint8 internal constant STATUS_OPEN = 0;
    uint8 internal constant STATUS_LOCKED = 1;
    uint8 internal constant STATUS_SETTLED = 2;
    uint8 internal constant STATUS_VOIDED = 3;

    uint256 internal constant FIRST_MIRROR_ID = 7_202_626;
    uint256 internal constant SECOND_MIRROR_ID = 7_202_627;
    bytes32 internal constant FIRST_CONDITION_ID = keccak256("first shared-collateral condition");
    bytes32 internal constant SECOND_CONDITION_ID = keccak256("second shared-collateral condition");
    address internal constant CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;

    MockGToken internal collateral;
    InvariantPolymarketResolver internal resolver;
    PolymarketBinaryMarket internal market;
    IPolymarketMarketAccounting internal accounting;
    PolymarketMarketHandler internal firstHandler;
    PolymarketMarketHandler internal secondHandler;
    uint256 internal firstMarketId;
    uint256 internal secondMarketId;

    function setUp() public {
        vm.warp(1_700_000_000);
        collateral = new MockGToken();
        resolver = new InvariantPolymarketResolver();
        market = new PolymarketBinaryMarket();
        accounting = IPolymarketMarketAccounting(address(market));

        uint64 closesAt = uint64(block.timestamp + 1 days);
        firstMarketId = _createMarket(FIRST_MIRROR_ID, FIRST_CONDITION_ID, closesAt);
        secondMarketId = _createMarket(SECOND_MIRROR_ID, SECOND_CONDITION_ID, closesAt);

        firstHandler = new PolymarketMarketHandler(
            address(market), resolver, collateral, firstMarketId, FIRST_MIRROR_ID, FIRST_CONDITION_ID, CTF, closesAt, 2
        );
        secondHandler = new PolymarketMarketHandler(
            address(market),
            resolver,
            collateral,
            secondMarketId,
            SECOND_MIRROR_ID,
            SECOND_CONDITION_ID,
            CTF,
            closesAt,
            2
        );
        _targetHandler(firstHandler);
        _targetHandler(secondHandler);
    }

    function invariant_SharedCollateralRemainsSolventAcrossMarkets() public view {
        uint256 totalDeposited = firstHandler.totalDeposited() + secondHandler.totalDeposited();
        uint256 totalWithdrawn = firstHandler.totalWithdrawn() + secondHandler.totalWithdrawn();
        uint256 escrowed = collateral.balanceOf(address(market));

        assertEq(market.getMarket(firstMarketId).totalPool, firstHandler.totalDeposited());
        assertEq(market.getMarket(secondMarketId).totalPool, secondHandler.totalDeposited());
        assertEq(escrowed + totalWithdrawn, totalDeposited, "shared escrow plus withdrawals must equal deposits");
        assertLe(totalWithdrawn, totalDeposited, "aggregate withdrawals must not exceed deposits");

        uint256 outstanding =
            _outstandingLiability(firstHandler, firstMarketId) + _outstandingLiability(secondHandler, secondMarketId);
        assertGe(escrowed, outstanding, "shared collateral must cover all outstanding market liabilities");
        assertLe(totalWithdrawn + outstanding, totalDeposited, "paid and outstanding liabilities must remain solvent");
    }

    function _createMarket(
        uint256 mirrorId,
        bytes32 conditionId,
        uint64 closesAt
    ) internal returns (uint256 marketId) {
        resolver.setMirrorConfig(mirrorId, 137, CTF, conditionId, 2);

        uint8[] memory slotToOutcome = new uint8[](2);
        slotToOutcome[0] = 0;
        slotToOutcome[1] = 1;
        PolymarketBinaryMarket.CreateMarketParams memory params = PolymarketBinaryMarket.CreateMarketParams({
            specHash: keccak256(abi.encode("shared collateral invariant", mirrorId)),
            opensAt: uint64(block.timestamp),
            closesAt: closesAt,
            collateral: address(collateral),
            settlementRef: PolymarketBinaryMarket.SettlementRef({
                sourceType: 6,
                mirrorId: mirrorId,
                conditionId: conditionId,
                resolver: address(resolver),
                ctf: CTF,
                polygonChainId: 137,
                outcomeSlotCount: 2,
                slotToOutcome: slotToOutcome,
                mode: PolymarketBinaryMarket.SettlementMode.SingleConditionBinary
            })
        });

        vm.prank(SystemAddresses.GOVERNANCE);
        return market.createMarket(params);
    }

    function _targetHandler(
        PolymarketMarketHandler handler
    ) internal {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = PolymarketMarketHandler.placeBet.selector;
        selectors[1] = PolymarketMarketHandler.lockMarket.selector;
        selectors[2] = PolymarketMarketHandler.finalizeWinner.selector;
        selectors[3] = PolymarketMarketHandler.finalizeVoidable.selector;
        selectors[4] = PolymarketMarketHandler.claim.selector;
        selectors[5] = PolymarketMarketHandler.refund.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function _outstandingLiability(
        PolymarketMarketHandler handler,
        uint256 marketId
    ) internal view returns (uint256 outstanding) {
        uint8 status = uint8(market.getMarket(marketId).status);
        if (status == STATUS_OPEN || status == STATUS_LOCKED) return market.getMarket(marketId).totalPool;

        for (uint256 actorIndex; actorIndex < handler.ACTOR_COUNT(); ++actorIndex) {
            address actor = handler.actors(actorIndex);
            if (status == STATUS_VOIDED && !accounting.claimed(marketId, actor)) {
                outstanding += accounting.userStake(marketId, actor, 0);
                outstanding += accounting.userStake(marketId, actor, 1);
            } else if (status == STATUS_SETTLED) {
                outstanding += accounting.claimable(marketId, actor);
            }
        }
    }
}
