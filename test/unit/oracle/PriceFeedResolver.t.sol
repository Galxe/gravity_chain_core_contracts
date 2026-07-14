// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle } from "../../../src/oracle/INativeOracle.sol";
import { MultiSourceOracleResolver } from "../../../src/oracle/resolver/MultiSourceOracleResolver.sol";
import { PriceFeedResolver } from "../../../src/oracle/resolver/PriceFeedResolver.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

contract PriceFeedResolverTest is Test {
    NativeOracle public oracle;
    PriceFeedResolver public resolver;

    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;
    uint256 public constant FEED_ID = 1;
    uint256 public constant CALLBACK_GAS_LIMIT = 2_000_000;

    bytes32 public constant SOURCE_A = keccak256("source-a");
    bytes32 public constant SOURCE_B = keccak256("source-b");
    bytes32 public constant SOURCE_C = keccak256("source-c");

    function setUp() public {
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
        resolver = new PriceFeedResolver();

        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(SOURCE_TYPE_PRICE_FEED, address(resolver));
    }

    function test_WeightedMeanStoresLatestAndHistoricalRound() public {
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](3);
        observations[0] = _observation(SOURCE_A, 1_000, 100e8, 1);
        observations[1] = _observation(SOURCE_B, 1_000, 102e8, 2);
        observations[2] = _observation(SOURCE_C, 1_000, 98e8, 1);

        bytes memory payload = _payload(1, 1_010, resolver.PRICE_AGG_WEIGHTED_MEAN(), 3, 4, 60, observations);
        _record(1, payload, CALLBACK_GAS_LIMIT);

        (bool exists, uint64 roundId,,,, uint256 sourceCount, uint256 totalWeight, int256 price) =
            resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(roundId, 1);
        assertEq(sourceCount, 3);
        assertEq(totalWeight, 4);
        assertEq(price, 100_50000000);

        (bool historicalExists,,,,,,, int256 historicalPrice) = resolver.priceRounds(FEED_ID, 1);
        assertTrue(historicalExists);
        assertEq(historicalPrice, price);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).data, payload);
    }

    function test_WeightedMedianIgnoresLightOutlier() public {
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](3);
        observations[0] = _observation(SOURCE_A, 2_000, 100e8, 1);
        observations[1] = _observation(SOURCE_B, 2_000, 101e8, 3);
        observations[2] = _observation(SOURCE_C, 2_000, 110e8, 1);

        _record(1, _payload(1, 2_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), 3, 5, 60, observations), CALLBACK_GAS_LIMIT);

        (,,,,,,, int256 price) = resolver.latestPrice(FEED_ID);
        assertEq(price, 101e8);
    }

    function test_MaximumObservationSetFitsCallbackBudget() public {
        uint256 count = resolver.MAX_PRICE_OBSERVATIONS();
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](count);
        for (uint256 i; i < count; ++i) {
            observations[i] = _observation(bytes32(i + 1), 2_000, int256(100e8 + i), 1);
        }

        _record(
            1,
            _payload(1, 2_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), count, count, 60, observations),
            CALLBACK_GAS_LIMIT
        );

        (bool exists,,,,,,, int256 price) = resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(price, int256(100e8 + 7));
    }

    function test_ReplayStoredPayloadAfterCallbackGasFailure() public {
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](1);
        observations[0] = _observation(SOURCE_A, 3_000, 100e8, 1);
        bytes memory payload = _payload(1, 3_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), 1, 1, 60, observations);

        _record(1, payload, 1);
        (bool exists,,,,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);

        resolver.replayPrice(FEED_ID, 1);
        int256 price;
        (exists,,,,,,, price) = resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(price, 100e8);
    }

    function test_ReplayBackfillsHistoricalRoundWithoutRewindingLatest() public {
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](1);
        observations[0] = _observation(SOURCE_A, 3_000, 100e8, 1);
        _record(1, _payload(1, 3_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), 1, 1, 60, observations), 1);

        observations[0] = _observation(SOURCE_A, 4_000, 102e8, 1);
        _record(2, _payload(2, 4_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), 1, 1, 60, observations), CALLBACK_GAS_LIMIT);

        (bool latestExists, uint64 latestRoundId,,,,,, int256 latestPrice) = resolver.latestPrice(FEED_ID);
        assertTrue(latestExists);
        assertEq(latestRoundId, 2);
        assertEq(latestPrice, 102e8);

        resolver.replayPrice(FEED_ID, 1);

        (bool historicalExists, uint64 historicalRoundId,,,,,, int256 historicalPrice) =
            resolver.priceRounds(FEED_ID, 1);
        assertTrue(historicalExists);
        assertEq(historicalRoundId, 1);
        assertEq(historicalPrice, 100e8);

        (, latestRoundId,,,,,, latestPrice) = resolver.latestPrice(FEED_ID);
        assertEq(latestRoundId, 2);
        assertEq(latestPrice, 102e8);
    }

    function test_FutureObservationFailsCallbackButRawPayloadRemains() public {
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](1);
        observations[0] = _observation(SOURCE_A, 4_011, 100e8, 1);
        bytes memory payload = _payload(1, 4_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), 1, 1, 60, observations);

        _record(1, payload, CALLBACK_GAS_LIMIT);

        (bool exists,,,,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).data, payload);
    }

    function test_RejectsMoreThanMaximumObservations() public {
        uint256 count = resolver.MAX_PRICE_OBSERVATIONS() + 1;
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](count);
        for (uint256 i; i < count; ++i) {
            observations[i] = _observation(bytes32(i + 1), 5_000, 100e8, 1);
        }
        bytes memory payload = _payload(1, 5_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), 1, 1, 60, observations);

        _record(1, payload, CALLBACK_GAS_LIMIT);

        (bool exists,,,,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).data, payload);
    }

    function test_CompatibilityAliasRetainsPriceFeedAbi() public {
        MultiSourceOracleResolver compatibilityResolver = new MultiSourceOracleResolver();
        assertEq(compatibilityResolver.SOURCE_TYPE_PRICE_FEED(), SOURCE_TYPE_PRICE_FEED);
        assertEq(compatibilityResolver.MAX_PRICE_OBSERVATIONS(), resolver.MAX_PRICE_OBSERVATIONS());
    }

    function test_RevertWhenCallbackCalledOutsideNativeOracle() public {
        PriceFeedResolver.PriceObservation[] memory observations = new PriceFeedResolver.PriceObservation[](1);
        observations[0] = _observation(SOURCE_A, 6_000, 100e8, 1);
        bytes memory payload = _payload(1, 6_010, resolver.PRICE_AGG_WEIGHTED_MEDIAN(), 1, 1, 60, observations);
        address caller = makeAddr("caller");

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, caller, SystemAddresses.NATIVE_ORACLE));
        vm.prank(caller);
        resolver.onOracleEvent(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1, payload);
    }

    function _record(
        uint128 nonce,
        bytes memory payload,
        uint256 callbackGasLimit
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.record(SOURCE_TYPE_PRICE_FEED, FEED_ID, nonce, 0, payload, callbackGasLimit);
    }

    function _payload(
        uint64 roundId,
        uint64 resolvedAt,
        uint8 aggregationMode,
        uint256 minSourceCount,
        uint256 minTotalWeight,
        uint64 maxStaleness,
        PriceFeedResolver.PriceObservation[] memory observations
    ) internal pure returns (bytes memory) {
        return abi.encode(
            PriceFeedResolver.PricePayload({
                feedId: FEED_ID,
                roundId: roundId,
                resolvedAt: resolvedAt,
                decimals: 8,
                aggregationMode: aggregationMode,
                minSourceCount: minSourceCount,
                minTotalWeight: minTotalWeight,
                maxStaleness: maxStaleness,
                observations: observations
            })
        );
    }

    function _observation(
        bytes32 dataSourceId,
        uint64 observedAt,
        int256 price,
        uint256 weight
    ) internal pure returns (PriceFeedResolver.PriceObservation memory) {
        return PriceFeedResolver.PriceObservation({
            dataSourceId: dataSourceId, observedAt: observedAt, price: price, weight: weight
        });
    }
}
