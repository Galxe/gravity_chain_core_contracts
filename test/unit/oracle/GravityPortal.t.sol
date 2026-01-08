// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GravityPortal } from "../../../src/oracle/GravityPortal.sol";
import { IGravityPortal } from "../../../src/oracle/IGravityPortal.sol";

/// @title GravityPortalTest
/// @notice Unit tests for GravityPortal contract (deployed on Ethereum)
contract GravityPortalTest is Test {
    GravityPortal public portal;

    address public owner;
    address public feeRecipient;
    address public alice;
    address public bob;

    uint256 public constant INITIAL_BASE_FEE = 0.001 ether;
    uint256 public constant INITIAL_FEE_PER_BYTE = 100 wei;

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy portal
        portal = new GravityPortal(
            owner,
            INITIAL_BASE_FEE,
            INITIAL_FEE_PER_BYTE,
            feeRecipient
        );

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ========================================================================
    // CONSTRUCTOR TESTS
    // ========================================================================

    function test_Constructor() public view {
        assertEq(portal.owner(), owner);
        assertEq(portal.baseFee(), INITIAL_BASE_FEE);
        assertEq(portal.feePerByte(), INITIAL_FEE_PER_BYTE);
        assertEq(portal.feeRecipient(), feeRecipient);
        assertEq(portal.nonce(), 0);
    }

    function test_Constructor_RevertWhenZeroOwner() public {
        vm.expectRevert(IGravityPortal.ZeroAddress.selector);
        new GravityPortal(address(0), INITIAL_BASE_FEE, INITIAL_FEE_PER_BYTE, feeRecipient);
    }

    function test_Constructor_RevertWhenZeroFeeRecipient() public {
        vm.expectRevert(IGravityPortal.ZeroAddress.selector);
        new GravityPortal(owner, INITIAL_BASE_FEE, INITIAL_FEE_PER_BYTE, address(0));
    }

    // ========================================================================
    // SEND MESSAGE TESTS
    // ========================================================================

    function test_SendMessage() public {
        bytes memory message = abi.encode(uint256(100), bob);
        uint256 fee = portal.calculateFee(message.length);

        vm.prank(alice);
        uint256 nonce = portal.sendMessage{ value: fee }(message);

        assertEq(nonce, 0);
        assertEq(portal.nonce(), 1);
    }

    function test_SendMessage_EmitsEvent() public {
        bytes memory message = abi.encode(uint256(100), bob);
        uint256 fee = portal.calculateFee(message.length);

        // Build expected payload
        bytes memory expectedPayload = abi.encode(alice, uint256(0), message);
        bytes32 expectedHash = keccak256(expectedPayload);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IGravityPortal.MessageSent(expectedHash, alice, 0, expectedPayload);
        portal.sendMessage{ value: fee }(message);
    }

    function test_SendMessage_IncrementingNonce() public {
        bytes memory message = hex"1234";
        uint256 fee = portal.calculateFee(message.length);

        vm.startPrank(alice);
        assertEq(portal.sendMessage{ value: fee }(message), 0);
        assertEq(portal.sendMessage{ value: fee }(message), 1);
        assertEq(portal.sendMessage{ value: fee }(message), 2);
        vm.stopPrank();

        assertEq(portal.nonce(), 3);
    }

    function test_SendMessage_RevertWhenInsufficientFee() public {
        bytes memory message = abi.encode(uint256(100), bob);
        
        // The actual payload is abi.encode(sender, nonce, message) which is larger
        // than just the message, so sending 0 wei should definitely fail
        vm.prank(alice);
        vm.expectRevert(); // Will revert with InsufficientFee
        portal.sendMessage{ value: 0 }(message);
    }

    function test_SendMessageWithData() public {
        bytes memory message = abi.encode(uint256(100), bob);
        uint256 fee = portal.calculateFee(message.length);

        vm.prank(alice);
        uint256 nonce = portal.sendMessageWithData{ value: fee }(message);

        assertEq(nonce, 0);
        assertEq(portal.nonce(), 1);
    }

    function test_SendMessageWithData_EmitsEvent() public {
        bytes memory message = abi.encode(uint256(100), bob);
        uint256 fee = portal.calculateFee(message.length);

        bytes memory expectedPayload = abi.encode(alice, uint256(0), message);
        bytes32 expectedHash = keccak256(expectedPayload);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IGravityPortal.MessageSentWithData(expectedHash, alice, 0, expectedPayload);
        portal.sendMessageWithData{ value: fee }(message);
    }

    // ========================================================================
    // FEE CALCULATION TESTS
    // ========================================================================

    function test_CalculateFee() public view {
        // Test with 0 bytes
        assertEq(portal.calculateFee(0), INITIAL_BASE_FEE + 128 * INITIAL_FEE_PER_BYTE);

        // Test with 32 bytes
        assertEq(portal.calculateFee(32), INITIAL_BASE_FEE + 160 * INITIAL_FEE_PER_BYTE);

        // Test with 100 bytes (rounds up to 128)
        assertEq(portal.calculateFee(100), INITIAL_BASE_FEE + 256 * INITIAL_FEE_PER_BYTE);
    }

    function testFuzz_CalculateFee(uint256 messageLength) public view {
        messageLength = bound(messageLength, 0, 10000);

        uint256 fee = portal.calculateFee(messageLength);
        uint256 expectedPayloadLength = 128 + ((messageLength + 31) / 32) * 32;
        uint256 expectedFee = INITIAL_BASE_FEE + (expectedPayloadLength * INITIAL_FEE_PER_BYTE);

        assertEq(fee, expectedFee);
    }

    // ========================================================================
    // FEE MANAGEMENT TESTS
    // ========================================================================

    function test_SetBaseFee() public {
        uint256 newBaseFee = 0.002 ether;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IGravityPortal.FeeConfigUpdated(newBaseFee, INITIAL_FEE_PER_BYTE);
        portal.setBaseFee(newBaseFee);

        assertEq(portal.baseFee(), newBaseFee);
    }

    function test_SetBaseFee_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IGravityPortal.OnlyOwner.selector);
        portal.setBaseFee(0.002 ether);
    }

    function test_SetFeePerByte() public {
        uint256 newFeePerByte = 200 wei;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IGravityPortal.FeeConfigUpdated(INITIAL_BASE_FEE, newFeePerByte);
        portal.setFeePerByte(newFeePerByte);

        assertEq(portal.feePerByte(), newFeePerByte);
    }

    function test_SetFeePerByte_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IGravityPortal.OnlyOwner.selector);
        portal.setFeePerByte(200 wei);
    }

    function test_SetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IGravityPortal.FeeRecipientUpdated(feeRecipient, newRecipient);
        portal.setFeeRecipient(newRecipient);

        assertEq(portal.feeRecipient(), newRecipient);
    }

    function test_SetFeeRecipient_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IGravityPortal.OnlyOwner.selector);
        portal.setFeeRecipient(bob);
    }

    function test_SetFeeRecipient_RevertWhenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IGravityPortal.ZeroAddress.selector);
        portal.setFeeRecipient(address(0));
    }

    // ========================================================================
    // FEE WITHDRAWAL TESTS
    // ========================================================================

    function test_WithdrawFees() public {
        // Send some messages to accumulate fees
        bytes memory message = hex"1234";
        uint256 fee = portal.calculateFee(message.length);

        vm.prank(alice);
        portal.sendMessage{ value: fee }(message);

        uint256 portalBalance = address(portal).balance;
        uint256 recipientBalanceBefore = feeRecipient.balance;

        vm.expectEmit(true, true, true, true);
        emit IGravityPortal.FeesWithdrawn(feeRecipient, portalBalance);
        portal.withdrawFees();

        assertEq(address(portal).balance, 0);
        assertEq(feeRecipient.balance, recipientBalanceBefore + portalBalance);
    }

    function test_WithdrawFees_RevertWhenNoFees() public {
        vm.expectRevert(IGravityPortal.NoFeesToWithdraw.selector);
        portal.withdrawFees();
    }

    function test_WithdrawFees_AnyoneCanCall() public {
        // Accumulate fees
        bytes memory message = hex"1234";
        uint256 fee = portal.calculateFee(message.length);
        vm.prank(alice);
        portal.sendMessage{ value: fee }(message);

        // Anyone can call withdrawFees (but funds go to feeRecipient)
        vm.prank(bob);
        portal.withdrawFees();

        assertEq(address(portal).balance, 0);
    }

    // ========================================================================
    // OWNERSHIP TESTS
    // ========================================================================

    function test_TransferOwnership() public {
        vm.prank(owner);
        portal.transferOwnership(alice);

        assertEq(portal.owner(), alice);
    }

    function test_TransferOwnership_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IGravityPortal.OnlyOwner.selector);
        portal.transferOwnership(bob);
    }

    function test_TransferOwnership_RevertWhenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IGravityPortal.ZeroAddress.selector);
        portal.transferOwnership(address(0));
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_SendMessage(bytes calldata message, uint256 extraFee) public {
        extraFee = bound(extraFee, 0, 1 ether);
        uint256 requiredFee = portal.calculateFee(message.length);

        vm.prank(alice);
        uint256 nonce = portal.sendMessage{ value: requiredFee + extraFee }(message);

        assertEq(nonce, 0);
        assertGe(address(portal).balance, requiredFee);
    }

    function testFuzz_FeeConfiguration(uint256 baseFee, uint256 feePerByte) public {
        baseFee = bound(baseFee, 0, 1 ether);
        feePerByte = bound(feePerByte, 0, 10000 wei);

        vm.startPrank(owner);
        portal.setBaseFee(baseFee);
        portal.setFeePerByte(feePerByte);
        vm.stopPrank();

        assertEq(portal.baseFee(), baseFee);
        assertEq(portal.feePerByte(), feePerByte);
    }
}

