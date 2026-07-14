// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeOracle, IOracleCallback } from "../INativeOracle.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";

/// @title PriceFeedResolver
/// @notice Validates and aggregates consensus-approved price observations.
/// @dev NativeOracle retains the canonical raw payload; this contract stores query-ready rounds.
contract PriceFeedResolver is IOracleCallback {
    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;

    uint8 public constant PRICE_AGG_WEIGHTED_MEAN = 1;
    uint8 public constant PRICE_AGG_WEIGHTED_MEDIAN = 2;
    uint256 public constant MAX_PRICE_OBSERVATIONS = 16;
    uint8 public constant MAX_PRICE_DECIMALS = 18;

    struct PriceObservation {
        bytes32 dataSourceId;
        uint64 observedAt;
        int256 price;
        uint256 weight;
    }

    struct PricePayload {
        uint256 feedId;
        uint64 roundId;
        uint64 resolvedAt;
        uint8 decimals;
        uint8 aggregationMode;
        uint256 minSourceCount;
        uint256 minTotalWeight;
        uint64 maxStaleness;
        PriceObservation[] observations;
    }

    struct PriceRound {
        bool exists;
        uint64 roundId;
        uint64 resolvedAt;
        uint8 decimals;
        uint8 aggregationMode;
        uint256 sourceCount;
        uint256 totalWeight;
        int256 price;
    }

    mapping(uint256 feedId => PriceRound round) public latestPrice;
    mapping(uint256 feedId => mapping(uint64 roundId => PriceRound round)) public priceRounds;

    event PriceResolved(
        uint256 indexed feedId,
        uint64 indexed roundId,
        int256 price,
        uint8 decimals,
        uint8 aggregationMode,
        uint256 sourceCount,
        uint256 totalWeight
    );

    error UnsupportedSourceType(uint32 sourceType);
    error SourceIdMismatch(uint256 expected, uint256 provided);
    error StaleRound(uint64 latestRoundId, uint64 providedRoundId);
    error RoundAlreadyResolved(uint256 feedId, uint64 roundId);
    error EmptyObservations();
    error TooManyObservations(uint256 maximum, uint256 provided);
    error InsufficientSources(uint256 required, uint256 provided);
    error InsufficientTotalWeight(uint256 required, uint256 provided);
    error InvalidThreshold();
    error InvalidAggregationMode(uint8 mode);
    error InvalidObservation(uint256 index);
    error InvalidDecimals(uint8 decimals);
    error DuplicateDataSource(bytes32 dataSourceId);
    error FutureObservation(uint256 index, uint64 observedAt, uint64 resolvedAt);
    error StaleObservation(uint256 index, uint64 observedAt, uint64 resolvedAt, uint64 maxStaleness);
    error WeightOverflow();
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
        if (priceRounds[payload.feedId][payload.roundId].exists) {
            revert RoundAlreadyResolved(payload.feedId, payload.roundId);
        }

        uint256 sourceCount = payload.observations.length;
        if (sourceCount == 0) revert EmptyObservations();
        if (sourceCount > MAX_PRICE_OBSERVATIONS) {
            revert TooManyObservations(MAX_PRICE_OBSERVATIONS, sourceCount);
        }
        if (payload.decimals > MAX_PRICE_DECIMALS) revert InvalidDecimals(payload.decimals);
        if (payload.minSourceCount == 0 || payload.minTotalWeight == 0) revert InvalidThreshold();
        if (sourceCount < payload.minSourceCount) revert InsufficientSources(payload.minSourceCount, sourceCount);

        uint256 totalWeight = _validateAndTotalWeight(payload);
        if (totalWeight < payload.minTotalWeight) {
            revert InsufficientTotalWeight(payload.minTotalWeight, totalWeight);
        }

        int256 resolvedPrice;
        if (payload.aggregationMode == PRICE_AGG_WEIGHTED_MEAN) {
            resolvedPrice = _weightedMean(payload.observations, totalWeight);
        } else if (payload.aggregationMode == PRICE_AGG_WEIGHTED_MEDIAN) {
            resolvedPrice = _weightedMedian(payload.observations, totalWeight);
        } else {
            revert InvalidAggregationMode(payload.aggregationMode);
        }

        PriceRound memory round = PriceRound({
            exists: true,
            roundId: payload.roundId,
            resolvedAt: payload.resolvedAt,
            decimals: payload.decimals,
            aggregationMode: payload.aggregationMode,
            sourceCount: sourceCount,
            totalWeight: totalWeight,
            price: resolvedPrice
        });

        priceRounds[payload.feedId][payload.roundId] = round;
        if (payload.roundId > current.roundId) latestPrice[payload.feedId] = round;

        emit PriceResolved(
            payload.feedId,
            payload.roundId,
            resolvedPrice,
            payload.decimals,
            payload.aggregationMode,
            sourceCount,
            totalWeight
        );
    }

    function _validateAndTotalWeight(
        PricePayload memory payload
    ) internal pure returns (uint256 totalWeight) {
        uint256 len = payload.observations.length;
        for (uint256 i; i < len;) {
            PriceObservation memory obs = payload.observations[i];
            if (obs.dataSourceId == bytes32(0) || obs.weight == 0 || obs.price <= 0) {
                revert InvalidObservation(i);
            }
            if (obs.observedAt > payload.resolvedAt) {
                revert FutureObservation(i, obs.observedAt, payload.resolvedAt);
            }
            if (payload.maxStaleness > 0 && uint256(obs.observedAt) + payload.maxStaleness < payload.resolvedAt) {
                revert StaleObservation(i, obs.observedAt, payload.resolvedAt, payload.maxStaleness);
            }
            for (uint256 j; j < i;) {
                if (payload.observations[j].dataSourceId == obs.dataSourceId) {
                    revert DuplicateDataSource(obs.dataSourceId);
                }
                unchecked {
                    ++j;
                }
            }
            totalWeight += obs.weight;
            unchecked {
                ++i;
            }
        }
        if (totalWeight > uint256(type(int256).max)) revert WeightOverflow();
    }

    function _weightedMean(
        PriceObservation[] memory observations,
        uint256 totalWeight
    ) internal pure returns (int256) {
        uint256 weightedSum;
        uint256 len = observations.length;
        for (uint256 i; i < len;) {
            uint256 price = uint256(observations[i].price);
            uint256 weight = observations[i].weight;
            if (price > uint256(type(int256).max) / weight) revert WeightOverflow();
            weightedSum += price * weight;
            if (weightedSum > uint256(type(int256).max)) revert WeightOverflow();
            unchecked {
                ++i;
            }
        }
        return int256(weightedSum / totalWeight);
    }

    function _weightedMedian(
        PriceObservation[] memory observations,
        uint256 totalWeight
    ) internal pure returns (int256) {
        uint256 threshold = totalWeight / 2 + (totalWeight % 2);
        uint256 len = observations.length;

        for (uint256 i; i < len;) {
            int256 candidate = observations[i].price;
            uint256 weightBelow;
            uint256 weightAt;

            for (uint256 j; j < len;) {
                PriceObservation memory obs = observations[j];
                if (obs.price < candidate) {
                    weightBelow += obs.weight;
                } else if (obs.price == candidate) {
                    weightAt += obs.weight;
                }
                unchecked {
                    ++j;
                }
            }

            if (weightBelow < threshold && weightBelow + weightAt >= threshold) return candidate;
            unchecked {
                ++i;
            }
        }

        revert InvalidObservation(0);
    }
}
