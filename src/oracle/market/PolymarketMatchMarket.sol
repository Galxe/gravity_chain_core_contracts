// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";
import { IPolymarketSettlementResolver } from "../resolver/IPolymarketSettlementResolver.sol";

/// @title PolymarketMatchMarket
/// @notice Pari-mutuel match market settled from a mirrored Polymarket CTF condition.
/// @dev V1 only supports one three-outcome condition. Split or ambiguous payouts are rejected.
contract PolymarketMatchMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant SOURCE_TYPE_POLYMARKET_SETTLEMENT = 6;
    uint256 public constant POLYGON_CHAIN_ID = 137;
    uint8 public constant SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION = 1;
    uint8 public constant MATCH_OUTCOME_COUNT = 3;

    bytes32 public constant VOID_REASON_ORACLE_DEADLINE_EXPIRED = keccak256("ORACLE_DEADLINE_EXPIRED");
    bytes32 public constant VOID_REASON_NO_WINNING_STAKE = keccak256("NO_WINNING_STAKE");

    enum MarketStatus {
        Open,
        Locked,
        Settled,
        Voided
    }

    enum MatchOutcome {
        HomeWin,
        Draw,
        AwayWin
    }

    enum SettlementMode {
        SingleConditionThreeWay,
        MultipleBinaryConditions
    }

    struct SettlementRef {
        uint32 sourceType;
        uint256 mirrorId;
        bytes32 conditionId;
        address resolver;
        address ctf;
        uint256 polygonChainId;
        uint8 outcomeSlotCount;
        uint8[] slotToOutcome;
        SettlementMode mode;
    }

    struct Market {
        bytes32 specHash;
        uint64 opensAt;
        uint64 closesAt;
        uint64 oracleDeadline;
        address collateral;
        MarketStatus status;
        uint8 outcomeCount;
        uint8 winningOutcome;
        uint256 totalPool;
    }

    struct CreateMarketParams {
        bytes32 specHash;
        uint64 opensAt;
        uint64 closesAt;
        uint64 oracleDeadline;
        address collateral;
        SettlementRef settlementRef;
    }

    uint256 private _nextMarketId = 1;

    mapping(uint256 marketId => Market market) private _markets;
    mapping(uint256 marketId => SettlementRef settlementRef) private _settlementRefs;

    mapping(uint256 marketId => mapping(uint8 outcome => uint256 total)) public outcomeTotal;
    mapping(uint256 marketId => mapping(address user => mapping(uint8 outcome => uint256 amount))) public userStake;
    mapping(uint256 marketId => mapping(address user => bool claimed)) public claimed;

    event MarketCreated(uint256 indexed marketId, bytes32 indexed specHash, uint256 indexed mirrorId);
    event BetPlaced(uint256 indexed marketId, address indexed user, uint8 indexed outcome, uint256 amount);
    event MarketLocked(uint256 indexed marketId);
    event MarketSettled(
        uint256 indexed marketId, uint8 indexed winningOutcome, bytes32 settlementTxHash, uint256 settlementLogIndex
    );
    event MarketVoided(uint256 indexed marketId, bytes32 reason);
    event Claimed(uint256 indexed marketId, address indexed user, uint256 amount);
    event Refunded(uint256 indexed marketId, address indexed user, uint256 amount);

    error InvalidMarketTime();
    error InvalidOutcome();
    error InvalidSettlementRef();
    error InvalidAmount();
    error MarketNotOpen();
    error MarketNotLocked();
    error MarketNotSettled();
    error MarketAlreadyFinalized();
    error SettlementUnavailable();
    error SettlementMismatch();
    error AmbiguousPayout();
    error OracleDeadlineNotReached();
    error NothingToClaim();
    error NothingToRefund();
    error MarketNotFound(uint256 marketId);
    error InvalidCollateralTransfer(uint256 expected, uint256 received);
    error InvalidCollateralPayout(uint256 expected, uint256 received, uint256 spent);

    function createMarket(
        CreateMarketParams calldata params
    ) external returns (uint256 marketId) {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _validateCreateMarketParams(params);

        marketId = _nextMarketId++;

        _markets[marketId] = Market({
            specHash: params.specHash,
            opensAt: params.opensAt,
            closesAt: params.closesAt,
            oracleDeadline: params.oracleDeadline,
            collateral: params.collateral,
            status: MarketStatus.Open,
            outcomeCount: MATCH_OUTCOME_COUNT,
            winningOutcome: type(uint8).max,
            totalPool: 0
        });

        SettlementRef storage ref = _settlementRefs[marketId];
        SettlementRef calldata input = params.settlementRef;
        ref.sourceType = input.sourceType;
        ref.mirrorId = input.mirrorId;
        ref.conditionId = input.conditionId;
        ref.resolver = input.resolver;
        ref.ctf = input.ctf;
        ref.polygonChainId = input.polygonChainId;
        ref.outcomeSlotCount = input.outcomeSlotCount;
        ref.mode = input.mode;
        for (uint256 i; i < input.slotToOutcome.length;) {
            ref.slotToOutcome.push(input.slotToOutcome[i]);
            unchecked {
                ++i;
            }
        }

        emit MarketCreated(marketId, params.specHash, input.mirrorId);
    }

    function placeBet(
        uint256 marketId,
        uint8 outcome,
        uint256 amount
    ) external nonReentrant {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        _requireOpenForBetting(market);
        if (outcome >= market.outcomeCount) revert InvalidOutcome();
        if (amount == 0) revert InvalidAmount();

        userStake[marketId][msg.sender][outcome] += amount;
        outcomeTotal[marketId][outcome] += amount;
        market.totalPool += amount;

        IERC20 collateral = IERC20(market.collateral);
        uint256 balanceBefore = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateral.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert InvalidCollateralTransfer(amount, received);

        emit BetPlaced(marketId, msg.sender, outcome, amount);
    }

    function lockMarket(
        uint256 marketId
    ) external {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        if (market.status == MarketStatus.Settled || market.status == MarketStatus.Voided) {
            revert MarketAlreadyFinalized();
        }
        if (market.status != MarketStatus.Open || block.timestamp < market.closesAt) revert MarketNotOpen();

        market.status = MarketStatus.Locked;
        emit MarketLocked(marketId);
    }

    function settleMarket(
        uint256 marketId
    ) external {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        if (market.status == MarketStatus.Settled || market.status == MarketStatus.Voided) {
            revert MarketAlreadyFinalized();
        }
        if (market.status != MarketStatus.Locked) revert MarketNotLocked();

        (uint8 winningOutcome, bytes32 txHash, uint256 logIndex) = _resolveWinningOutcome(marketId);

        if (outcomeTotal[marketId][winningOutcome] == 0) {
            market.status = MarketStatus.Voided;
            emit MarketVoided(marketId, VOID_REASON_NO_WINNING_STAKE);
            return;
        }

        market.status = MarketStatus.Settled;
        market.winningOutcome = winningOutcome;
        emit MarketSettled(marketId, winningOutcome, txHash, logIndex);
    }

    function claim(
        uint256 marketId
    ) external nonReentrant returns (uint256 amount) {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        if (market.status != MarketStatus.Settled) revert MarketNotSettled();
        if (claimed[marketId][msg.sender]) revert NothingToClaim();

        amount = claimable(marketId, msg.sender);
        if (amount == 0) revert NothingToClaim();

        claimed[marketId][msg.sender] = true;
        _transferExact(IERC20(market.collateral), msg.sender, amount);

        emit Claimed(marketId, msg.sender, amount);
    }

    function voidMarket(
        uint256 marketId
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        if (market.status == MarketStatus.Settled || market.status == MarketStatus.Voided) {
            revert MarketAlreadyFinalized();
        }
        if (block.timestamp < market.oracleDeadline) revert OracleDeadlineNotReached();

        market.status = MarketStatus.Voided;
        emit MarketVoided(marketId, VOID_REASON_ORACLE_DEADLINE_EXPIRED);
    }

    function refund(
        uint256 marketId
    ) external nonReentrant returns (uint256 amount) {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        if (market.status != MarketStatus.Voided) revert MarketAlreadyFinalized();
        if (claimed[marketId][msg.sender]) revert NothingToRefund();

        amount = _totalUserStake(marketId, msg.sender, market.outcomeCount);
        if (amount == 0) revert NothingToRefund();

        claimed[marketId][msg.sender] = true;
        _transferExact(IERC20(market.collateral), msg.sender, amount);

        emit Refunded(marketId, msg.sender, amount);
    }

    function getMarket(
        uint256 marketId
    ) external view returns (Market memory) {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        return market;
    }

    function getSettlementRef(
        uint256 marketId
    ) external view returns (SettlementRef memory) {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        return _settlementRefs[marketId];
    }

    function claimable(
        uint256 marketId,
        address user
    ) public view returns (uint256 amount) {
        Market storage market = _markets[marketId];
        _requireMarketExists(marketId, market);
        if (market.status != MarketStatus.Settled || claimed[marketId][user]) return 0;

        uint8 winningOutcome = market.winningOutcome;
        uint256 winningStake = userStake[marketId][user][winningOutcome];
        if (winningStake == 0) return 0;

        uint256 winningPool = outcomeTotal[marketId][winningOutcome];
        if (winningPool == 0) return 0;

        return Math.mulDiv(winningStake, market.totalPool, winningPool);
    }

    function _validateCreateMarketParams(
        CreateMarketParams calldata params
    ) internal view {
        if (
            params.specHash == bytes32(0) || params.collateral.code.length == 0
                || params.settlementRef.resolver.code.length == 0
        ) revert InvalidSettlementRef();
        if (params.opensAt >= params.closesAt || params.closesAt >= params.oracleDeadline) revert InvalidMarketTime();

        SettlementRef calldata ref = params.settlementRef;
        if (
            ref.sourceType != SOURCE_TYPE_POLYMARKET_SETTLEMENT || ref.mirrorId == 0 || ref.conditionId == bytes32(0)
                || ref.resolver == address(0) || ref.ctf == address(0) || ref.polygonChainId != POLYGON_CHAIN_ID
                || ref.mode != SettlementMode.SingleConditionThreeWay || ref.outcomeSlotCount != MATCH_OUTCOME_COUNT
                || ref.slotToOutcome.length != MATCH_OUTCOME_COUNT
        ) {
            revert InvalidSettlementRef();
        }

        uint256 seen;
        for (uint256 i; i < ref.slotToOutcome.length;) {
            uint8 outcome = ref.slotToOutcome[i];
            if (outcome >= MATCH_OUTCOME_COUNT) revert InvalidOutcome();
            uint256 mask = uint256(1) << outcome;
            if (seen & mask != 0) revert InvalidSettlementRef();
            seen |= mask;
            unchecked {
                ++i;
            }
        }
    }

    function _requireOpenForBetting(
        Market storage market
    ) internal view {
        if (
            market.status != MarketStatus.Open || block.timestamp < market.opensAt || block.timestamp >= market.closesAt
        ) {
            revert MarketNotOpen();
        }
    }

    function _requireMarketExists(
        uint256 marketId,
        Market storage market
    ) internal view {
        if (market.specHash == bytes32(0)) revert MarketNotFound(marketId);
    }

    function _resolveWinningOutcome(
        uint256 marketId
    ) internal view returns (uint8 winningOutcome, bytes32 txHash, uint256 logIndex) {
        SettlementRef storage ref = _settlementRefs[marketId];

        (
            bool exists,,
            uint256 polygonChainId,
            address ctf,,,
            uint256 outcomeSlotCount,
            bytes32 settlementTxHash,
            uint256 settlementLogIndex,
            uint8 settlementKind
        ) = IPolymarketSettlementResolver(ref.resolver).getSettlement(ref.mirrorId, ref.conditionId);

        if (!exists) revert SettlementUnavailable();
        if (
            polygonChainId != POLYGON_CHAIN_ID || ctf != ref.ctf || outcomeSlotCount != ref.outcomeSlotCount
                || settlementKind != SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION
        ) {
            revert SettlementMismatch();
        }

        uint256[] memory payouts = IPolymarketSettlementResolver(ref.resolver)
            .getPayoutNumerators({ mirrorId: ref.mirrorId, conditionId: ref.conditionId });
        if (payouts.length != ref.outcomeSlotCount) revert SettlementMismatch();

        uint256 positiveSlot = type(uint256).max;
        for (uint256 i; i < payouts.length;) {
            if (payouts[i] > 0) {
                if (positiveSlot != type(uint256).max) revert AmbiguousPayout();
                positiveSlot = i;
            }
            unchecked {
                ++i;
            }
        }
        if (positiveSlot == type(uint256).max) revert AmbiguousPayout();

        winningOutcome = ref.slotToOutcome[positiveSlot];
        if (winningOutcome >= MATCH_OUTCOME_COUNT) revert SettlementMismatch();
        txHash = settlementTxHash;
        logIndex = settlementLogIndex;
    }

    function _totalUserStake(
        uint256 marketId,
        address user,
        uint8 outcomeCount
    ) internal view returns (uint256 amount) {
        for (uint8 outcome; outcome < outcomeCount;) {
            amount += userStake[marketId][user][outcome];
            unchecked {
                ++outcome;
            }
        }
    }

    function _transferExact(
        IERC20 collateral,
        address recipient,
        uint256 amount
    ) internal {
        uint256 senderBefore = collateral.balanceOf(address(this));
        uint256 recipientBefore = collateral.balanceOf(recipient);
        collateral.safeTransfer(recipient, amount);
        uint256 senderAfter = collateral.balanceOf(address(this));
        uint256 recipientAfter = collateral.balanceOf(recipient);

        uint256 spent = senderBefore >= senderAfter ? senderBefore - senderAfter : type(uint256).max;
        uint256 received = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (spent != amount || received != amount) revert InvalidCollateralPayout(amount, received, spent);
    }
}
