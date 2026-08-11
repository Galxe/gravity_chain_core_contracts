// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IOracleCallback } from "../INativeOracle.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";

/// @title PriceFeedResolver
/// @author Gravity Team
/// @notice Stores the latest consensus-approved Binance index-price round for each feed.
contract PriceFeedResolver is IOracleCallback {
    struct PriceRound {
        uint32 roundId;
        uint48 resolvedAtMs;
        uint96 price;
    }

    /// @notice NativeOracle source type reserved for deterministic price feeds.
    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;
    /// @notice Decimal precision implied by packed payload version 1.
    uint8 public constant PRICE_DECIMALS = 8;
    /// @notice Binance index-price packed payload version.
    uint8 public constant PAYLOAD_VERSION = 1;

    /// @notice Latest accepted round for each feed identifier.
    mapping(uint64 feedId => PriceRound round) public latestPrice;

    /// @notice Emitted after a newer price round is accepted.
    /// @param feedId Stable feed identifier matching the NativeOracle source ID.
    /// @param roundId Binance bucket open time divided by its interval in milliseconds.
    /// @param price Positive fixed-point price with `PRICE_DECIMALS` decimals.
    /// @param resolvedAtMs Binance bucket close time in milliseconds.
    event PriceResolved(uint64 indexed feedId, uint32 indexed roundId, uint96 price, uint48 resolvedAtMs);

    error UnsupportedSourceType(uint32 sourceType);
    error InvalidPayloadLength(uint256 length);
    error UnsupportedPayloadVersion(uint8 version);
    error UnsupportedPayloadFlags(uint8 flags);
    error SourceIdOverflow(uint256 sourceId);
    error SourceIdMismatch(uint64 expectedSourceId, uint64 providedFeedId);
    error StaleRound(uint32 latestRoundId, uint32 providedRoundId);
    error StaleResolvedAt(uint48 latestResolvedAtMs, uint48 providedResolvedAtMs);
    error InvalidPrice(uint96 price);

    /// @inheritdoc IOracleCallback
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128,
        bytes calldata payload
    ) external override returns (bool shouldStore) {
        requireAllowed(SystemAddresses.NATIVE_ORACLE);
        if (sourceType != SOURCE_TYPE_PRICE_FEED) revert UnsupportedSourceType(sourceType);
        if (payload.length != 32) revert InvalidPayloadLength(payload.length);
        if (sourceId > type(uint64).max) revert SourceIdOverflow(sourceId);

        uint256 word;
        assembly ("memory-safe") {
            word := calldataload(payload.offset)
        }

        uint8 version = uint8(word >> 248);
        if (version != PAYLOAD_VERSION) revert UnsupportedPayloadVersion(version);

        uint8 flags = uint8(word);
        if (flags != 0) revert UnsupportedPayloadFlags(flags);

        uint64 feedId = uint64(word >> 184);
        uint32 roundId = uint32(word >> 152);
        uint48 resolvedAtMs = uint48(word >> 104);
        uint96 price = uint96(word >> 8);
        uint64 narrowedSourceId = uint64(sourceId);
        if (feedId != narrowedSourceId) revert SourceIdMismatch(narrowedSourceId, feedId);

        PriceRound memory current = latestPrice[feedId];
        if (roundId == 0 || roundId <= current.roundId) {
            revert StaleRound(current.roundId, roundId);
        }
        if (resolvedAtMs == 0 || resolvedAtMs <= current.resolvedAtMs) {
            revert StaleResolvedAt(current.resolvedAtMs, resolvedAtMs);
        }
        if (price == 0) revert InvalidPrice(price);

        latestPrice[feedId] = PriceRound({ roundId: roundId, resolvedAtMs: resolvedAtMs, price: price });
        emit PriceResolved(feedId, roundId, price, resolvedAtMs);
        return false;
    }
}
