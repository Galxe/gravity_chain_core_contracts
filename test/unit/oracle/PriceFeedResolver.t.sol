// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle } from "../../../src/oracle/INativeOracle.sol";
import { PriceFeedResolver } from "../../../src/oracle/resolver/PriceFeedResolver.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

contract PriceFeedResolverTest is Test {
    NativeOracle public oracle;
    PriceFeedResolver public resolver;

    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;
    uint256 public constant FEED_ID = 1;
    uint256 public constant CALLBACK_GAS_LIMIT = 2_000_000;

    function setUp() public {
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
        resolver = new PriceFeedResolver();

        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(SOURCE_TYPE_PRICE_FEED, address(resolver));
    }

    function test_BinanceCloseStoresLatestHistoricalAndRawPayload() public {
        bytes memory payload = _payload(1, 1_010, 196_12500000);
        _record(FEED_ID, 1, payload, CALLBACK_GAS_LIMIT);

        (bool exists, uint64 roundId, uint64 resolvedAt, uint8 decimals, int256 price) = resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(roundId, 1);
        assertEq(resolvedAt, 1_010);
        assertEq(decimals, 8);
        assertEq(price, 196_12500000);

        (bool historicalExists, uint64 historicalRoundId,,, int256 historicalPrice) = resolver.priceRounds(FEED_ID, 1);
        assertTrue(historicalExists);
        assertEq(historicalRoundId, 1);
        assertEq(historicalPrice, price);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).data, payload);
    }

    function test_ReplayStoredPayloadAfterCallbackGasFailure() public {
        bytes memory payload = _payload(1, 2_010, 196_12500000);

        _record(FEED_ID, 1, payload, 1);
        (bool exists,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);

        resolver.replayPrice(FEED_ID, 1);
        int256 price;
        (exists,,,, price) = resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(price, 196_12500000);
    }

    function test_ReplayBackfillsHistoricalRoundWithoutRewindingLatest() public {
        _record(FEED_ID, 1, _payload(1, 3_010, 196_12500000), 1);
        _record(FEED_ID, 2, _payload(2, 4_010, 197_50000000), CALLBACK_GAS_LIMIT);

        resolver.replayPrice(FEED_ID, 1);

        (bool historicalExists, uint64 historicalRoundId,,, int256 historicalPrice) = resolver.priceRounds(FEED_ID, 1);
        assertTrue(historicalExists);
        assertEq(historicalRoundId, 1);
        assertEq(historicalPrice, 196_12500000);

        (bool latestExists, uint64 latestRoundId,,, int256 latestPrice) = resolver.latestPrice(FEED_ID);
        assertTrue(latestExists);
        assertEq(latestRoundId, 2);
        assertEq(latestPrice, 197_50000000);
    }

    function test_ZeroPriceFailsCallbackButRawPayloadRemains() public {
        bytes memory payload = _payload(1, 5_010, 0);
        _record(FEED_ID, 1, payload, CALLBACK_GAS_LIMIT);

        (bool exists,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).data, payload);
    }

    function test_ExcessiveDecimalsFailCallbackButRawPayloadRemains() public {
        bytes memory payload = abi.encode(
            PriceFeedResolver.PricePayload({
                feedId: FEED_ID,
                roundId: 1,
                resolvedAt: 6_010,
                decimals: resolver.MAX_PRICE_DECIMALS() + 1,
                price: 196_12500000
            })
        );
        _record(FEED_ID, 1, payload, CALLBACK_GAS_LIMIT);

        (bool exists,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).data, payload);
    }

    function test_StaleRoundFailsCallbackButRawPayloadRemains() public {
        _record(FEED_ID, 1, _payload(2, 7_010, 197_50000000), CALLBACK_GAS_LIMIT);
        bytes memory payload = _payload(1, 8_010, 196_12500000);
        _record(FEED_ID, 2, payload, CALLBACK_GAS_LIMIT);

        (, uint64 latestRoundId,,, int256 latestPrice) = resolver.latestPrice(FEED_ID);
        assertEq(latestRoundId, 2);
        assertEq(latestPrice, 197_50000000);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 2).data, payload);
    }

    function test_StaleResolvedAtFailsCallbackButRawPayloadRemains() public {
        _record(FEED_ID, 1, _payload(1, 9_010, 196_12500000), CALLBACK_GAS_LIMIT);
        bytes memory payload = _payload(2, 9_010, 197_50000000);
        _record(FEED_ID, 2, payload, CALLBACK_GAS_LIMIT);

        (, uint64 latestRoundId, uint64 resolvedAt,, int256 latestPrice) = resolver.latestPrice(FEED_ID);
        assertEq(latestRoundId, 1);
        assertEq(resolvedAt, 9_010);
        assertEq(latestPrice, 196_12500000);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 2).data, payload);
    }

    function test_SourceIdMismatchFailsCallbackButRawPayloadRemains() public {
        uint256 otherFeedId = FEED_ID + 1;
        bytes memory payload = _payload(1, 10_010, 196_12500000);
        _record(otherFeedId, 1, payload, CALLBACK_GAS_LIMIT);

        (bool exists,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, otherFeedId, 1).data, payload);
    }

    function test_RevertWhenCallbackCalledOutsideNativeOracle() public {
        bytes memory payload = _payload(1, 11_010, 196_12500000);
        address caller = makeAddr("caller");

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, caller, SystemAddresses.NATIVE_ORACLE));
        vm.prank(caller);
        resolver.onOracleEvent(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1, payload);
    }

    function test_RevertWhenReplayingMissingRecord() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceFeedResolver.RecordUnavailable.selector, SOURCE_TYPE_PRICE_FEED, FEED_ID, uint128(1)
            )
        );
        resolver.replayPrice(FEED_ID, 1);
    }

    function _record(
        uint256 sourceId,
        uint128 nonce,
        bytes memory payload,
        uint256 callbackGasLimit
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.record(SOURCE_TYPE_PRICE_FEED, sourceId, nonce, 0, payload, callbackGasLimit);
    }

    function _payload(
        uint64 roundId,
        uint64 resolvedAt,
        int256 price
    ) internal pure returns (bytes memory) {
        return abi.encode(
            PriceFeedResolver.PricePayload({
                feedId: FEED_ID, roundId: roundId, resolvedAt: resolvedAt, decimals: 8, price: price
            })
        );
    }
}
