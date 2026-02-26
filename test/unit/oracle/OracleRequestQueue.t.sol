// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { OracleRequestQueue } from "../../../src/oracle/ondemand/OracleRequestQueue.sol";
import { IOracleRequestQueue } from "../../../src/oracle/ondemand/IOracleRequestQueue.sol";
import { OnDemandOracleTaskConfig } from "../../../src/oracle/ondemand/OnDemandOracleTaskConfig.sol";
import { IOnDemandOracleTaskConfig } from "../../../src/oracle/ondemand/IOnDemandOracleTaskConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";

/// @title OracleRequestQueueTest
/// @notice Unit tests for OracleRequestQueue contract
contract OracleRequestQueueTest is Test {
    OracleRequestQueue public requestQueue;
    OnDemandOracleTaskConfig public taskConfig;

    // Test addresses
    address public governance;
    address public systemCaller;
    address public treasury;
    address public alice;
    address public bob;

    // Test data - Source types
    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;
    uint256 public constant NASDAQ_SOURCE_ID = 1;
    uint256 public constant NYSE_SOURCE_ID = 2;

    // Test configuration
    uint256 public constant DEFAULT_FEE = 0.01 ether;
    uint64 public constant DEFAULT_EXPIRATION = 1 hours;

    function setUp() public {
        governance = SystemAddresses.GOVERNANCE;
        systemCaller = SystemAddresses.SYSTEM_CALLER;
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy task config
        taskConfig = new OnDemandOracleTaskConfig();

        // Deploy request queue
        requestQueue = new OracleRequestQueue(address(taskConfig), treasury);

        // Set up a supported task type
        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, abi.encode("nasdaq config"));

        // Set up fee and expiration
        vm.startPrank(governance);
        requestQueue.setFee(SOURCE_TYPE_PRICE_FEED, DEFAULT_FEE);
        requestQueue.setExpiration(SOURCE_TYPE_PRICE_FEED, DEFAULT_EXPIRATION);
        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ========================================================================
    // CONSTRUCTOR TESTS
    // ========================================================================

    function test_Constructor() public view {
        assertEq(requestQueue.taskConfig(), address(taskConfig));
        assertEq(requestQueue.treasury(), treasury);
        assertEq(requestQueue.nextRequestId(), 1);
    }

    function test_Constructor_RevertWhenZeroTaskConfig() public {
        vm.expectRevert(OracleRequestQueue.ZeroAddress.selector);
        new OracleRequestQueue(address(0), treasury);
    }

    function test_Constructor_RevertWhenZeroTreasury() public {
        vm.expectRevert(OracleRequestQueue.ZeroAddress.selector);
        new OracleRequestQueue(address(taskConfig), address(0));
    }

    // ========================================================================
    // REQUEST SUBMISSION TESTS
    // ========================================================================

    function test_Request() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        assertEq(requestId, 1);
        assertEq(requestQueue.nextRequestId(), 2);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);
        assertEq(req.sourceType, SOURCE_TYPE_PRICE_FEED);
        assertEq(req.sourceId, NASDAQ_SOURCE_ID);
        assertEq(req.requester, alice);
        assertEq(req.requestData, requestData);
        assertEq(req.fee, DEFAULT_FEE);
        assertTrue(req.requestedAt > 0);
        assertEq(req.expiresAt, req.requestedAt + DEFAULT_EXPIRATION);
        assertFalse(req.fulfilled);
        assertFalse(req.refunded);
    }

    function test_Request_MultipleRequests() public {
        bytes memory requestData1 = abi.encode("AAPL");
        bytes memory requestData2 = abi.encode("GOOGL");

        vm.prank(alice);
        uint256 requestId1 =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData1);

        vm.prank(bob);
        uint256 requestId2 =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData2);

        assertEq(requestId1, 1);
        assertEq(requestId2, 2);
        assertEq(requestQueue.nextRequestId(), 3);
    }

    function test_Request_RevertWhenUnsupportedSourceType() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleRequestQueue.UnsupportedSourceType.selector, SOURCE_TYPE_PRICE_FEED, NYSE_SOURCE_ID
            )
        );
        vm.prank(alice);
        requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NYSE_SOURCE_ID, requestData);
    }

    function test_Request_RevertWhenInsufficientFee() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.expectRevert(
            abi.encodeWithSelector(OracleRequestQueue.InsufficientFee.selector, DEFAULT_FEE, DEFAULT_FEE - 1)
        );
        vm.prank(alice);
        requestQueue.request{ value: DEFAULT_FEE - 1 }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);
    }

    function test_Request_WithExcessFee() public {
        bytes memory requestData = abi.encode("AAPL");
        uint256 excessFee = DEFAULT_FEE + 0.05 ether;
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: excessFee }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);
        assertEq(req.fee, DEFAULT_FEE); // Only required fee is stored
        // Excess was refunded to alice
        assertEq(alice.balance, aliceBalanceBefore - DEFAULT_FEE);
    }

    function test_Request_WithZeroFeeConfig() public {
        // Set up a custom source type with zero fee (fee defaults to 0 for new source types)
        uint32 customSourceType = 100;
        uint256 customSourceId = 1;

        vm.prank(governance);
        taskConfig.setTaskType(customSourceType, customSourceId, abi.encode("custom config"));

        // Fee defaults to 0 for this new source type
        bytes memory requestData = abi.encode("custom data");

        vm.prank(alice);
        uint256 requestId = requestQueue.request{ value: 0 }(customSourceType, customSourceId, requestData);

        assertEq(requestId, 1);
    }

    // ========================================================================
    // FULFILLMENT TESTS
    // ========================================================================

    function test_MarkFulfilled() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(systemCaller);
        requestQueue.markFulfilled(requestId);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);
        assertTrue(req.fulfilled);
        assertFalse(req.refunded);

        // Fee should be transferred to treasury
        assertEq(treasury.balance, treasuryBalanceBefore + DEFAULT_FEE);
    }

    function test_MarkFulfilled_RevertWhenNotSystemCaller() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        vm.expectRevert();
        vm.prank(alice);
        requestQueue.markFulfilled(requestId);
    }

    function test_MarkFulfilled_RevertWhenRequestNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(OracleRequestQueue.RequestNotFound.selector, 999));
        vm.prank(systemCaller);
        requestQueue.markFulfilled(999);
    }

    function test_MarkFulfilled_RevertWhenAlreadyFulfilled() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        vm.prank(systemCaller);
        requestQueue.markFulfilled(requestId);

        vm.expectRevert(abi.encodeWithSelector(OracleRequestQueue.AlreadyFulfilled.selector, requestId));
        vm.prank(systemCaller);
        requestQueue.markFulfilled(requestId);
    }

    function test_MarkFulfilled_RevertWhenAlreadyRefunded() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        // Fast forward past expiration + grace period
        vm.warp(block.timestamp + DEFAULT_EXPIRATION + requestQueue.FULFILLMENT_GRACE_PERIOD() + 1);

        // Refund
        requestQueue.refund(requestId);

        vm.expectRevert(abi.encodeWithSelector(OracleRequestQueue.AlreadyRefunded.selector, requestId));
        vm.prank(systemCaller);
        requestQueue.markFulfilled(requestId);
    }

    // ========================================================================
    // REFUND TESTS
    // ========================================================================

    function test_Refund() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        uint256 aliceBalanceBefore = alice.balance;

        // Fast forward past expiration + grace period
        vm.warp(block.timestamp + DEFAULT_EXPIRATION + requestQueue.FULFILLMENT_GRACE_PERIOD() + 1);

        // Anyone can call refund
        vm.prank(bob);
        requestQueue.refund(requestId);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);
        assertFalse(req.fulfilled);
        assertTrue(req.refunded);

        // Fee should be refunded to alice (the requester)
        assertEq(alice.balance, aliceBalanceBefore + DEFAULT_FEE);
    }

    function test_Refund_RevertWhenNotExpired() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);
        uint64 effectiveExpiration = req.expiresAt + requestQueue.FULFILLMENT_GRACE_PERIOD();

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleRequestQueue.NotExpired.selector, requestId, effectiveExpiration, uint64(block.timestamp)
            )
        );
        requestQueue.refund(requestId);
    }

    function test_Refund_RevertWhenRequestNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(OracleRequestQueue.RequestNotFound.selector, 999));
        requestQueue.refund(999);
    }

    function test_Refund_RevertWhenAlreadyFulfilled() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        vm.prank(systemCaller);
        requestQueue.markFulfilled(requestId);

        // Fast forward past expiration + grace period
        vm.warp(block.timestamp + DEFAULT_EXPIRATION + requestQueue.FULFILLMENT_GRACE_PERIOD() + 1);

        vm.expectRevert(abi.encodeWithSelector(OracleRequestQueue.AlreadyFulfilled.selector, requestId));
        requestQueue.refund(requestId);
    }

    function test_Refund_RevertWhenAlreadyRefunded() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        // Fast forward past expiration + grace period
        vm.warp(block.timestamp + DEFAULT_EXPIRATION + requestQueue.FULFILLMENT_GRACE_PERIOD() + 1);

        requestQueue.refund(requestId);

        vm.expectRevert(abi.encodeWithSelector(OracleRequestQueue.AlreadyRefunded.selector, requestId));
        requestQueue.refund(requestId);
    }

    function test_Refund_AtExactExpirationPlusGrace() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);

        // Fast forward to exact expiration + grace period
        vm.warp(req.expiresAt + requestQueue.FULFILLMENT_GRACE_PERIOD());

        // Should succeed at exact expiration + grace period
        requestQueue.refund(requestId);

        assertTrue(requestQueue.getRequest(requestId).refunded);
    }

    // ========================================================================
    // CONFIGURATION TESTS
    // ========================================================================

    function test_SetFee() public {
        uint256 newFee = 0.05 ether;

        vm.prank(governance);
        requestQueue.setFee(SOURCE_TYPE_PRICE_FEED, newFee);

        assertEq(requestQueue.getFee(SOURCE_TYPE_PRICE_FEED), newFee);
    }

    function test_SetFee_RevertWhenNotGovernance() public {
        vm.expectRevert();
        vm.prank(alice);
        requestQueue.setFee(SOURCE_TYPE_PRICE_FEED, 0.05 ether);
    }

    function test_SetExpiration() public {
        uint64 newExpiration = 2 hours;

        vm.prank(governance);
        requestQueue.setExpiration(SOURCE_TYPE_PRICE_FEED, newExpiration);

        assertEq(requestQueue.getExpiration(SOURCE_TYPE_PRICE_FEED), newExpiration);
    }

    function test_SetExpiration_RevertWhenNotGovernance() public {
        vm.expectRevert();
        vm.prank(alice);
        requestQueue.setExpiration(SOURCE_TYPE_PRICE_FEED, 2 hours);
    }

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(governance);
        requestQueue.setTreasury(newTreasury);

        assertEq(requestQueue.treasury(), newTreasury);
    }

    function test_SetTreasury_RevertWhenNotGovernance() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectRevert();
        vm.prank(alice);
        requestQueue.setTreasury(newTreasury);
    }

    function test_SetTreasury_RevertWhenZeroAddress() public {
        vm.expectRevert(OracleRequestQueue.ZeroAddress.selector);
        vm.prank(governance);
        requestQueue.setTreasury(address(0));
    }

    // ========================================================================
    // QUERY TESTS
    // ========================================================================

    function test_IsExpired() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        assertFalse(requestQueue.isExpired(requestId));

        // Fast forward past expiration
        vm.warp(block.timestamp + DEFAULT_EXPIRATION);

        assertTrue(requestQueue.isExpired(requestId));
    }

    function test_IsExpired_NonExistentRequest() public view {
        assertFalse(requestQueue.isExpired(999));
    }

    function test_GetRequest_NotFound() public view {
        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(999);
        assertEq(req.requester, address(0));
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_RequestSubmitted() public {
        bytes memory requestData = abi.encode("AAPL");
        uint64 expectedExpiration = uint64(block.timestamp) + DEFAULT_EXPIRATION;

        vm.expectEmit(true, true, true, true);
        emit IOracleRequestQueue.RequestSubmitted(
            1, SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, alice, requestData, DEFAULT_FEE, expectedExpiration
        );

        vm.prank(alice);
        requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);
    }

    function test_Events_RequestFulfilled() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        vm.expectEmit(true, true, true, true);
        emit IOracleRequestQueue.RequestFulfilled(requestId);

        vm.prank(systemCaller);
        requestQueue.markFulfilled(requestId);
    }

    function test_Events_RequestRefunded() public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        vm.warp(block.timestamp + DEFAULT_EXPIRATION + requestQueue.FULFILLMENT_GRACE_PERIOD() + 1);

        vm.expectEmit(true, true, true, true);
        emit IOracleRequestQueue.RequestRefunded(requestId, alice, DEFAULT_FEE);

        requestQueue.refund(requestId);
    }

    function test_Events_FeeUpdated() public {
        uint256 newFee = 0.05 ether;

        vm.expectEmit(true, true, true, true);
        emit IOracleRequestQueue.FeeUpdated(SOURCE_TYPE_PRICE_FEED, DEFAULT_FEE, newFee);

        vm.prank(governance);
        requestQueue.setFee(SOURCE_TYPE_PRICE_FEED, newFee);
    }

    function test_Events_ExpirationUpdated() public {
        uint64 newExpiration = 2 hours;

        vm.expectEmit(true, true, true, true);
        emit IOracleRequestQueue.ExpirationUpdated(SOURCE_TYPE_PRICE_FEED, DEFAULT_EXPIRATION, newExpiration);

        vm.prank(governance);
        requestQueue.setExpiration(SOURCE_TYPE_PRICE_FEED, newExpiration);
    }

    function test_Events_TreasuryUpdated() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, true, true);
        emit IOracleRequestQueue.TreasuryUpdated(treasury, newTreasury);

        vm.prank(governance);
        requestQueue.setTreasury(newTreasury);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Request(
        bytes memory requestData,
        uint256 fee
    ) public {
        fee = bound(fee, DEFAULT_FEE, 10 ether);
        vm.deal(alice, fee);

        vm.prank(alice);
        uint256 requestId = requestQueue.request{ value: fee }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);
        assertEq(req.requestData, requestData);
        assertEq(req.fee, DEFAULT_FEE); // Only required fee stored, excess refunded
    }

    function testFuzz_FulfillAndRefundMutuallyExclusive(
        uint256 timeDelta
    ) public {
        bytes memory requestData = abi.encode("AAPL");

        vm.prank(alice);
        uint256 requestId =
            requestQueue.request{ value: DEFAULT_FEE }(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, requestData);

        IOracleRequestQueue.OracleRequest memory req = requestQueue.getRequest(requestId);
        uint64 effectiveExpiration = req.expiresAt + requestQueue.FULFILLMENT_GRACE_PERIOD();

        timeDelta = bound(timeDelta, 0, uint256(effectiveExpiration) + DEFAULT_EXPIRATION);
        vm.warp(block.timestamp + timeDelta);

        // Refund requires block.timestamp >= effectiveExpiration (expiresAt + grace period)
        bool canRefund = block.timestamp >= effectiveExpiration;

        if (canRefund) {
            // Can refund
            requestQueue.refund(requestId);
            assertTrue(requestQueue.getRequest(requestId).refunded);

            // Cannot fulfill after refund
            vm.expectRevert(abi.encodeWithSelector(OracleRequestQueue.AlreadyRefunded.selector, requestId));
            vm.prank(systemCaller);
            requestQueue.markFulfilled(requestId);
        } else {
            // Can fulfill before effective expiration
            vm.prank(systemCaller);
            requestQueue.markFulfilled(requestId);
            assertTrue(requestQueue.getRequest(requestId).fulfilled);
        }
    }

    function testFuzz_SetFee(
        uint32 sourceType,
        uint256 fee
    ) public {
        vm.prank(governance);
        requestQueue.setFee(sourceType, fee);

        assertEq(requestQueue.getFee(sourceType), fee);
    }

    function testFuzz_SetExpiration(
        uint32 sourceType,
        uint64 duration
    ) public {
        vm.prank(governance);
        requestQueue.setExpiration(sourceType, duration);

        assertEq(requestQueue.getExpiration(sourceType), duration);
    }
}

