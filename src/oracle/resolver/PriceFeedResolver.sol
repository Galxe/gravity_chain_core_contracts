// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeOracle, IOracleCallback } from "../INativeOracle.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";

/// @title PriceFeedResolver
/// @notice Stores consensus-approved Binance index-price kline closes.
/// @dev NativeOracle retains the canonical raw payload; this contract stores query-ready rounds.
contract PriceFeedResolver is IOracleCallback {
    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;
    uint8 public constant MAX_PRICE_DECIMALS = 18;

    struct PricePayload {
        uint256 feedId;
        uint64 roundId;
        uint64 resolvedAt;
        uint8 decimals;
        int256 price;
    }

    struct PriceRound {
        bool exists;
        uint64 roundId;
        uint64 resolvedAt;
        uint8 decimals;
        int256 price;
    }

    mapping(uint256 feedId => PriceRound round) public latestPrice;
    mapping(uint256 feedId => mapping(uint64 roundId => PriceRound round)) public priceRounds;

    event PriceResolved(
        uint256 indexed feedId, uint64 indexed roundId, int256 price, uint8 decimals, uint64 resolvedAt
    );

    error UnsupportedSourceType(uint32 sourceType);
    error SourceIdMismatch(uint256 expected, uint256 provided);
    error StaleRound(uint64 latestRoundId, uint64 providedRoundId);
    error StaleResolvedAt(uint64 latestResolvedAt, uint64 providedResolvedAt);
    error RoundAlreadyResolved(uint256 feedId, uint64 roundId);
    error InvalidPrice(int256 price);
    error InvalidDecimals(uint8 decimals);
    error RecordUnavailable(uint32 sourceType, uint256 sourceId, uint128 nonce);

    /// @inheritdoc IOracleCallback
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128,
        bytes calldata payload
    ) external override returns (bool shouldStore) {
        requireAllowed(SystemAddresses.NATIVE_ORACLE);
        if (sourceType != SOURCE_TYPE_PRICE_FEED) revert UnsupportedSourceType(sourceType);

        _resolvePrice(sourceId, abi.decode(payload, (PricePayload)), false);
        return true;
    }

    /// @notice Replays a consensus-stored payload when its callback previously failed.
    /// @dev Anyone may call this because the payload is read from NativeOracle.
    function replayPrice(
        uint256 feedId,
        uint128 nonce
    ) external {
        INativeOracle.DataRecord memory record =
            INativeOracle(SystemAddresses.NATIVE_ORACLE).getRecord(SOURCE_TYPE_PRICE_FEED, feedId, nonce);
        if (record.recordedAt == 0) revert RecordUnavailable(SOURCE_TYPE_PRICE_FEED, feedId, nonce);
        _resolvePrice(feedId, abi.decode(record.data, (PricePayload)), true);
    }

    function _resolvePrice(
        uint256 sourceId,
        PricePayload memory payload,
        bool allowHistorical
    ) internal {
        if (sourceId != payload.feedId) revert SourceIdMismatch(payload.feedId, sourceId);

        PriceRound memory current = latestPrice[payload.feedId];
        if (payload.roundId == 0 || (!allowHistorical && payload.roundId <= current.roundId)) {
            revert StaleRound(current.roundId, payload.roundId);
        }
        if (!allowHistorical && payload.resolvedAt <= current.resolvedAt) {
            revert StaleResolvedAt(current.resolvedAt, payload.resolvedAt);
        }
        if (priceRounds[payload.feedId][payload.roundId].exists) {
            revert RoundAlreadyResolved(payload.feedId, payload.roundId);
        }
        if (payload.decimals > MAX_PRICE_DECIMALS) revert InvalidDecimals(payload.decimals);
        if (payload.price <= 0) revert InvalidPrice(payload.price);

        PriceRound memory round = PriceRound({
            exists: true,
            roundId: payload.roundId,
            resolvedAt: payload.resolvedAt,
            decimals: payload.decimals,
            price: payload.price
        });

        priceRounds[payload.feedId][payload.roundId] = round;
        if (payload.roundId > current.roundId) latestPrice[payload.feedId] = round;

        emit PriceResolved(payload.feedId, payload.roundId, payload.price, payload.decimals, payload.resolvedAt);
    }
}
