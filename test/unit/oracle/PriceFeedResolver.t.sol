// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";
import { INativeOracle } from "../../../src/oracle/INativeOracle.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { PriceFeedResolver } from "../../../src/oracle/resolver/PriceFeedResolver.sol";

contract PriceFeedResolverTest is Test {
    NativeOracle public oracle;
    PriceFeedResolver public resolver;

    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;
    uint256 public constant FEED_ID = 1;
    uint256 public constant CALLBACK_GAS_LIMIT = 500_000;

    event PriceResolved(
        uint256 indexed feedId, uint64 indexed roundId, int256 price, uint8 decimals, uint64 resolvedAt
    );

    function setUp() public {
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
        resolver = new PriceFeedResolver();

        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(SOURCE_TYPE_PRICE_FEED, address(resolver));
    }

    function test_StoresLatestPriceAndSourceProgress() public {
        bytes memory payload = _payload(FEED_ID, 1, 1_010, 8, 196_12500000);

        vm.expectEmit(true, true, false, true, address(resolver));
        emit PriceResolved(FEED_ID, 1, 196_12500000, 8, 1_010);
        _record(FEED_ID, 1, 1_010, payload, CALLBACK_GAS_LIMIT);

        (bool exists, uint64 roundId, uint64 resolvedAt, uint8 decimals, int256 price) = resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(roundId, 1);
        assertEq(resolvedAt, 1_010);
        assertEq(decimals, 8);
        assertEq(price, 196_12500000);

        INativeOracle.SourceProgress memory progress = oracle.getSourceProgress(SOURCE_TYPE_PRICE_FEED, FEED_ID);
        assertEq(progress.latestNonce, 1);
        assertEq(progress.latestPosition, 1_010);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).recordedAt, 0);
    }

    function test_NextRoundOverwritesLatestPriceWithoutHistory() public {
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 8, 196_12500000), CALLBACK_GAS_LIMIT);
        _record(FEED_ID, 2, 2_010, _payload(FEED_ID, 2, 2_010, 8, 197_50000000), CALLBACK_GAS_LIMIT);

        (bool exists, uint64 roundId, uint64 resolvedAt,, int256 price) = resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(roundId, 2);
        assertEq(resolvedAt, 2_010);
        assertEq(price, 197_50000000);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 2);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).recordedAt, 0);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 2).recordedAt, 0);
    }

    function test_IndependentFeedsDoNotOverwriteEachOther() public {
        uint256 secondFeedId = 2;
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 8, 196_12500000), CALLBACK_GAS_LIMIT);
        _record(secondFeedId, 1, 1_010, _payload(secondFeedId, 1, 1_010, 6, 28_500000), CALLBACK_GAS_LIMIT);

        (,,,, int256 firstPrice) = resolver.latestPrice(FEED_ID);
        (bool exists, uint64 roundId,, uint8 decimals, int256 secondPrice) = resolver.latestPrice(secondFeedId);
        assertEq(firstPrice, 196_12500000);
        assertTrue(exists);
        assertEq(roundId, 1);
        assertEq(decimals, 6);
        assertEq(secondPrice, 28_500000);
    }

    function test_ZeroRoundRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 0, 1_010, 8, 196_12500000), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_ZeroResolvedAtRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1, _payload(FEED_ID, 1, 0, 8, 196_12500000), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_ZeroPriceRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 8, 0), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_NegativePriceRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 8, -1), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_ExcessiveDecimalsRevertsAtomically() public {
        bytes memory payload = _payload(FEED_ID, 1, 1_010, resolver.MAX_PRICE_DECIMALS() + 1, 196_12500000);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, payload, CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_StaleRoundRevertsWithoutAdvancingProgress() public {
        _record(FEED_ID, 1, 2_010, _payload(FEED_ID, 2, 2_010, 8, 197_50000000), CALLBACK_GAS_LIMIT);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 2, 3_010, _payload(FEED_ID, 1, 3_010, 8, 196_12500000), CALLBACK_GAS_LIMIT);

        (, uint64 roundId, uint64 resolvedAt,, int256 price) = resolver.latestPrice(FEED_ID);
        assertEq(roundId, 2);
        assertEq(resolvedAt, 2_010);
        assertEq(price, 197_50000000);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 1);
    }

    function test_StaleResolvedAtRevertsWithoutAdvancingProgress() public {
        _record(FEED_ID, 1, 2_010, _payload(FEED_ID, 1, 2_010, 8, 196_12500000), CALLBACK_GAS_LIMIT);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 2, 2_010, _payload(FEED_ID, 2, 2_010, 8, 197_50000000), CALLBACK_GAS_LIMIT);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 1);
    }

    function test_SourceIdMismatchRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID + 1, 1, 1_010, _payload(FEED_ID, 1, 1_010, 8, 196_12500000), CALLBACK_GAS_LIMIT);

        (bool exists,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID + 1), 0);
    }

    function test_MalformedPayloadRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, hex"1234", CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_CallbackGasFailureLeavesNoPriceOrProgress() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 8, 196_12500000), 1);
        _assertUnchanged();
    }

    function test_RevertWhenCallbackCalledOutsideNativeOracle() public {
        bytes memory payload = _payload(FEED_ID, 1, 1_010, 8, 196_12500000);
        address caller = makeAddr("caller");

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, caller, SystemAddresses.NATIVE_ORACLE));
        vm.prank(caller);
        resolver.onOracleEvent(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1, payload);
    }

    function test_RevertWhenNativeOracleUsesWrongSourceType() public {
        vm.expectRevert(abi.encodeWithSelector(PriceFeedResolver.UnsupportedSourceType.selector, uint32(4)));
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        resolver.onOracleEvent(4, FEED_ID, 1, _payload(FEED_ID, 1, 1_010, 8, 196_12500000));
    }

    function _assertUnchanged() internal view {
        (bool exists,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 0);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).recordedAt, 0);
    }

    function _record(
        uint256 sourceId,
        uint128 nonce,
        uint256 sourcePosition,
        bytes memory payload,
        uint256 callbackGasLimit
    ) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.record(SOURCE_TYPE_PRICE_FEED, sourceId, nonce, sourcePosition, payload, callbackGasLimit);
    }

    function _payload(
        uint256 feedId,
        uint64 roundId,
        uint64 resolvedAt,
        uint8 decimals,
        int256 price
    ) internal pure returns (bytes memory) {
        return abi.encode(
            PriceFeedResolver.PricePayload({
                feedId: feedId, roundId: roundId, resolvedAt: resolvedAt, decimals: decimals, price: price
            })
        );
    }
}
