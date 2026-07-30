// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle } from "../../../src/oracle/INativeOracle.sol";
import { PriceFeedResolver } from "../../../src/oracle/resolver/PriceFeedResolver.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";
import { Errors } from "../../../src/foundation/Errors.sol";

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

    function test_BinanceCloseStoresOnlyLatestPriceAndProgress() public {
        bytes memory payload = _payload(FEED_ID, 1, 1_010, 196_12500000);
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

    function test_NextCloseOverwritesLatestPriceWithoutHistory() public {
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 196_12500000), CALLBACK_GAS_LIMIT);
        _record(FEED_ID, 2, 2_010, _payload(FEED_ID, 2, 2_010, 197_50000000), CALLBACK_GAS_LIMIT);

        (bool exists, uint64 roundId, uint64 resolvedAt,, int256 price) = resolver.latestPrice(FEED_ID);
        assertTrue(exists);
        assertEq(roundId, 2);
        assertEq(resolvedAt, 2_010);
        assertEq(price, 197_50000000);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 2);
    }

    function test_ZeroPriceRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 0), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_ExcessiveDecimalsRevertsAtomically() public {
        bytes memory payload = abi.encode(
            PriceFeedResolver.PricePayload({
                feedId: FEED_ID,
                roundId: 1,
                resolvedAt: 1_010,
                decimals: resolver.MAX_PRICE_DECIMALS() + 1,
                price: 196_12500000
            })
        );

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, payload, CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_StaleRoundRevertsWithoutAdvancingProgress() public {
        _record(FEED_ID, 1, 2_010, _payload(FEED_ID, 2, 2_010, 197_50000000), CALLBACK_GAS_LIMIT);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 2, 3_010, _payload(FEED_ID, 1, 3_010, 196_12500000), CALLBACK_GAS_LIMIT);

        (, uint64 roundId, uint64 resolvedAt,, int256 price) = resolver.latestPrice(FEED_ID);
        assertEq(roundId, 2);
        assertEq(resolvedAt, 2_010);
        assertEq(price, 197_50000000);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 1);
    }

    function test_StaleResolvedAtRevertsWithoutAdvancingProgress() public {
        _record(FEED_ID, 1, 2_010, _payload(FEED_ID, 1, 2_010, 196_12500000), CALLBACK_GAS_LIMIT);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 2, 2_010, _payload(FEED_ID, 2, 2_010, 197_50000000), CALLBACK_GAS_LIMIT);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 1);
    }

    function test_SourceIdMismatchRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID + 1, 1, 1_010, _payload(FEED_ID, 1, 1_010, 196_12500000), CALLBACK_GAS_LIMIT);

        (bool exists,,,,) = resolver.latestPrice(FEED_ID);
        assertFalse(exists);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID + 1), 0);
    }

    function test_CallbackGasFailureLeavesNoPayloadOrProgress() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 196_12500000), 1);
        _assertUnchanged();
    }

    function test_RevertWhenCallbackCalledOutsideNativeOracle() public {
        bytes memory payload = _payload(FEED_ID, 1, 1_010, 196_12500000);
        address caller = makeAddr("caller");

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, caller, SystemAddresses.NATIVE_ORACLE));
        vm.prank(caller);
        resolver.onOracleEvent(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1, payload);
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
        int256 price
    ) internal pure returns (bytes memory) {
        return abi.encode(
            PriceFeedResolver.PricePayload({
                feedId: feedId, roundId: roundId, resolvedAt: resolvedAt, decimals: 8, price: price
            })
        );
    }
}
