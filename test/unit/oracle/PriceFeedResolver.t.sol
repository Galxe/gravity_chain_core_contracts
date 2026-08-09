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
    uint64 public constant FEED_ID = 1;
    uint256 public constant CALLBACK_GAS_LIMIT = 500_000;

    event PriceResolved(uint64 indexed feedId, uint32 indexed roundId, uint96 price, uint48 resolvedAtMs);

    function setUp() public {
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
        resolver = new PriceFeedResolver();

        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(SOURCE_TYPE_PRICE_FEED, address(resolver));
    }

    function test_StoresPackedV1PriceAndSourceProgress() public {
        bytes memory payload = _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0);

        vm.expectEmit(true, true, false, true, address(resolver));
        emit PriceResolved(FEED_ID, 1, 196_12500000, 1_010);
        _record(FEED_ID, 1, 1_010, payload, CALLBACK_GAS_LIMIT);

        (uint32 roundId, uint48 resolvedAtMs, uint96 price) = resolver.latestPrice(FEED_ID);
        assertEq(roundId, 1);
        assertEq(resolvedAtMs, 1_010);
        assertEq(price, 196_12500000);
        assertEq(resolver.PRICE_DECIMALS(), 8);

        INativeOracle.SourceProgress memory progress = oracle.getSourceProgress(SOURCE_TYPE_PRICE_FEED, FEED_ID);
        assertEq(progress.latestNonce, 1);
        assertEq(progress.latestPosition, 1_010);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).recordedAt, 0);
    }

    function test_GoldenVector() public pure {
        bytes memory payload = _payload(2001, 28_500_000, 1_710_000_059_999, 40_067_545_000, 1, 0);

        assertEq(payload, hex"0100000000000007d101b2e020018e23f2365f0000000000000009543637a800");
    }

    function test_PriceRoundOccupiesOneStorageSlot() public {
        uint32 roundId = 28_500_000;
        uint48 resolvedAtMs = 1_710_000_059_999;
        uint96 price = 40_067_545_000;
        _record(FEED_ID, 1, resolvedAtMs, _payload(FEED_ID, roundId, resolvedAtMs, price, 1, 0), CALLBACK_GAS_LIMIT);

        bytes32 valueSlot = keccak256(abi.encode(uint256(FEED_ID), uint256(0)));
        uint256 expected = uint256(roundId) | (uint256(resolvedAtMs) << 32) | (uint256(price) << 80);
        assertEq(uint256(vm.load(address(resolver), valueSlot)), expected);
        assertEq(uint256(vm.load(address(resolver), bytes32(uint256(valueSlot) + 1))), 0);
    }

    function test_MaximumFieldWidthsAreAccepted() public {
        uint64 feedId = type(uint64).max;
        _record(
            feedId,
            1,
            type(uint48).max,
            _payload(feedId, type(uint32).max, type(uint48).max, type(uint96).max, 1, 0),
            CALLBACK_GAS_LIMIT
        );

        (uint32 roundId, uint48 resolvedAtMs, uint96 price) = resolver.latestPrice(feedId);
        assertEq(roundId, type(uint32).max);
        assertEq(resolvedAtMs, type(uint48).max);
        assertEq(price, type(uint96).max);
    }

    function test_NextRoundOverwritesLatestPriceWithoutHistory() public {
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0), CALLBACK_GAS_LIMIT);
        _record(FEED_ID, 2, 2_010, _payload(FEED_ID, 2, 2_010, 197_50000000, 1, 0), CALLBACK_GAS_LIMIT);

        (uint32 roundId, uint48 resolvedAtMs, uint96 price) = resolver.latestPrice(FEED_ID);
        assertEq(roundId, 2);
        assertEq(resolvedAtMs, 2_010);
        assertEq(price, 197_50000000);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 2);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1).recordedAt, 0);
        assertEq(oracle.getRecord(SOURCE_TYPE_PRICE_FEED, FEED_ID, 2).recordedAt, 0);
    }

    function test_IndependentFeedsDoNotOverwriteEachOther() public {
        uint64 secondFeedId = 2;
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0), CALLBACK_GAS_LIMIT);
        _record(secondFeedId, 1, 1_010, _payload(secondFeedId, 1, 1_010, 28_50000000, 1, 0), CALLBACK_GAS_LIMIT);

        (,, uint96 firstPrice) = resolver.latestPrice(FEED_ID);
        (uint32 roundId,, uint96 secondPrice) = resolver.latestPrice(secondFeedId);
        assertEq(firstPrice, 196_12500000);
        assertEq(roundId, 1);
        assertEq(secondPrice, 28_50000000);
    }

    function test_RevertsForInvalidPayloadLength() public {
        _expectDirectRevert(
            abi.encodeWithSelector(PriceFeedResolver.InvalidPayloadLength.selector, 31), FEED_ID, new bytes(31)
        );
        _expectDirectRevert(
            abi.encodeWithSelector(PriceFeedResolver.InvalidPayloadLength.selector, 33), FEED_ID, new bytes(33)
        );
    }

    function test_RevertsForUnknownVersion() public {
        _expectDirectRevert(
            abi.encodeWithSelector(PriceFeedResolver.UnsupportedPayloadVersion.selector, uint8(2)),
            FEED_ID,
            _payload(FEED_ID, 1, 1_010, 196_12500000, 2, 0)
        );
    }

    function test_RevertsForNonzeroFlags() public {
        _expectDirectRevert(
            abi.encodeWithSelector(PriceFeedResolver.UnsupportedPayloadFlags.selector, uint8(1)),
            FEED_ID,
            _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 1)
        );
    }

    function test_RevertsForSourceIdOverflow() public {
        uint256 sourceId = uint256(type(uint64).max) + 1;
        _expectDirectRevert(
            abi.encodeWithSelector(PriceFeedResolver.SourceIdOverflow.selector, sourceId),
            sourceId,
            _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0)
        );
    }

    function test_RevertsForSourceIdMismatch() public {
        _expectDirectRevert(
            abi.encodeWithSelector(PriceFeedResolver.SourceIdMismatch.selector, uint64(FEED_ID + 1), FEED_ID),
            FEED_ID + 1,
            _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0)
        );
    }

    function test_ZeroRoundRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 0, 1_010, 196_12500000, 1, 0), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_ZeroResolvedAtRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1, _payload(FEED_ID, 1, 0, 196_12500000, 1, 0), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_ZeroPriceRevertsAtomically() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 0, 1, 0), CALLBACK_GAS_LIMIT);
        _assertUnchanged();
    }

    function test_StaleRoundRevertsWithoutAdvancingProgress() public {
        _record(FEED_ID, 1, 2_010, _payload(FEED_ID, 2, 2_010, 197_50000000, 1, 0), CALLBACK_GAS_LIMIT);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 2, 3_010, _payload(FEED_ID, 1, 3_010, 196_12500000, 1, 0), CALLBACK_GAS_LIMIT);

        (uint32 roundId, uint48 resolvedAtMs, uint96 price) = resolver.latestPrice(FEED_ID);
        assertEq(roundId, 2);
        assertEq(resolvedAtMs, 2_010);
        assertEq(price, 197_50000000);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 1);
    }

    function test_StaleResolvedAtRevertsWithoutAdvancingProgress() public {
        _record(FEED_ID, 1, 2_010, _payload(FEED_ID, 1, 2_010, 196_12500000, 1, 0), CALLBACK_GAS_LIMIT);

        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 2, 2_010, _payload(FEED_ID, 2, 2_010, 197_50000000, 1, 0), CALLBACK_GAS_LIMIT);
        assertEq(oracle.getLatestNonce(SOURCE_TYPE_PRICE_FEED, FEED_ID), 1);
    }

    function test_OldAbiPayloadIsRejected() public {
        bytes memory oldPayload = abi.encode(uint256(FEED_ID), uint64(1), uint64(1_010), uint8(8), int256(196_12500000));
        _expectDirectRevert(
            abi.encodeWithSelector(PriceFeedResolver.InvalidPayloadLength.selector, oldPayload.length),
            FEED_ID,
            oldPayload
        );
    }

    function test_CallbackGasFailureLeavesNoPriceOrProgress() public {
        vm.expectPartialRevert(Errors.OracleCallbackFailed.selector);
        _record(FEED_ID, 1, 1_010, _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0), 1);
        _assertUnchanged();
    }

    function test_RevertWhenCallbackCalledOutsideNativeOracle() public {
        bytes memory payload = _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0);
        address caller = makeAddr("caller");

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, caller, SystemAddresses.NATIVE_ORACLE));
        vm.prank(caller);
        resolver.onOracleEvent(SOURCE_TYPE_PRICE_FEED, FEED_ID, 1, payload);
    }

    function test_RevertWhenNativeOracleUsesWrongSourceType() public {
        vm.expectRevert(abi.encodeWithSelector(PriceFeedResolver.UnsupportedSourceType.selector, uint32(4)));
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        resolver.onOracleEvent(4, FEED_ID, 1, _payload(FEED_ID, 1, 1_010, 196_12500000, 1, 0));
    }

    function _expectDirectRevert(
        bytes memory reason,
        uint256 sourceId,
        bytes memory payload
    ) internal {
        vm.expectRevert(reason);
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        resolver.onOracleEvent(SOURCE_TYPE_PRICE_FEED, sourceId, 1, payload);
    }

    function _assertUnchanged() internal view {
        (uint32 roundId, uint48 resolvedAtMs, uint96 price) = resolver.latestPrice(FEED_ID);
        assertEq(roundId, 0);
        assertEq(resolvedAtMs, 0);
        assertEq(price, 0);
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
        uint64 feedId,
        uint32 roundId,
        uint48 resolvedAtMs,
        uint96 price,
        uint8 version,
        uint8 flags
    ) internal pure returns (bytes memory) {
        uint256 word = uint256(version) << 248 | uint256(feedId) << 184 | uint256(roundId) << 152
            | uint256(resolvedAtMs) << 104 | uint256(price) << 8 | uint256(flags);
        return abi.encodePacked(bytes32(word));
    }
}
