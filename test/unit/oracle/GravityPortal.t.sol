// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { IGravityPortal } from "@src/oracle/evm/IGravityPortal.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

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
        portal = new GravityPortal(owner, INITIAL_BASE_FEE, INITIAL_FEE_PER_BYTE, feeRecipient);

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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
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

    function test_SendMessage_EmitsEventWithCompactEncoding() public {
        bytes memory message = abi.encode(uint256(100), bob);
        uint256 fee = portal.calculateFee(message.length);

        // Build expected payload using compact encoding
        bytes memory expectedPayload = PortalMessage.encode(alice, uint256(0), message);
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

        // The actual payload is compact encoded so sending 0 wei should fail
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

    function test_SendMessageWithData_EmitsEventWithCompactEncoding() public {
        bytes memory message = abi.encode(uint256(100), bob);
        uint256 fee = portal.calculateFee(message.length);

        bytes memory expectedPayload = PortalMessage.encode(alice, uint256(0), message);
        bytes32 expectedHash = keccak256(expectedPayload);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IGravityPortal.MessageSentWithData(expectedHash, alice, 0, expectedPayload);
        portal.sendMessageWithData{ value: fee }(message);
    }

    // ========================================================================
    // COMPACT ENCODING VERIFICATION TESTS
    // ========================================================================

    function test_CompactEncodingFormat() public {
        bytes memory message = hex"deadbeef";
        uint256 fee = portal.calculateFee(message.length);

        vm.prank(alice);

        // Capture the event
        vm.recordLogs();
        portal.sendMessage{ value: fee }(message);

        // Get the emitted event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1, "Should emit one event");

        // Decode the payload from the event
        bytes memory payload = abi.decode(entries[0].data, (bytes));

        // Verify compact encoding: 20 (sender) + 32 (nonce) + message.length = 56 bytes
        assertEq(payload.length, 52 + message.length, "Compact payload length");

        // Decode and verify
        (address sender, uint256 nonce, bytes memory decodedMessage) = PortalMessage.decode(payload);
        assertEq(sender, alice, "Decoded sender");
        assertEq(nonce, 0, "Decoded nonce");
        assertEq(decodedMessage, message, "Decoded message");
    }

    function test_CompactEncodingSmallerThanAbi() public {
        bytes memory message = hex"0102030405060708";
        uint256 fee = portal.calculateFee(message.length);

        vm.prank(alice);

        vm.recordLogs();
        portal.sendMessage{ value: fee }(message);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes memory compactPayload = abi.decode(entries[0].data, (bytes));

        // Compare with ABI encoding
        bytes memory abiPayload = abi.encode(alice, uint256(0), message);

        // Compact should be significantly smaller
        assertLt(compactPayload.length, abiPayload.length, "Compact should be smaller");

        // Compact: 52 + 8 = 60 bytes
        // ABI: ~160+ bytes (with dynamic bytes overhead)
        assertEq(compactPayload.length, 60, "Compact should be exactly 60 bytes");
    }

    // ========================================================================
    // FEE CALCULATION TESTS
    // ========================================================================

    function test_CalculateFee() public view {
        // Test with 0 bytes: 52 (header) * feePerByte + baseFee
        assertEq(portal.calculateFee(0), INITIAL_BASE_FEE + 52 * INITIAL_FEE_PER_BYTE);

        // Test with 32 bytes: 84 bytes total
        assertEq(portal.calculateFee(32), INITIAL_BASE_FEE + 84 * INITIAL_FEE_PER_BYTE);

        // Test with 100 bytes: 152 bytes total
        assertEq(portal.calculateFee(100), INITIAL_BASE_FEE + 152 * INITIAL_FEE_PER_BYTE);
    }

    function testFuzz_CalculateFee(
        uint256 messageLength
    ) public view {
        messageLength = bound(messageLength, 0, 10000);

        uint256 fee = portal.calculateFee(messageLength);
        // Compact encoding: 52 bytes overhead + message length
        uint256 expectedPayloadLength = 52 + messageLength;
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
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
    // OWNABLE2STEP TESTS
    // ========================================================================

    function test_TransferOwnership_TwoStep() public {
        // Step 1: Owner initiates transfer
        vm.prank(owner);
        portal.transferOwnership(alice);

        // Owner is still the same
        assertEq(portal.owner(), owner);
        // Pending owner is set
        assertEq(portal.pendingOwner(), alice);
    }

    function test_AcceptOwnership() public {
        // Step 1: Owner initiates transfer
        vm.prank(owner);
        portal.transferOwnership(alice);

        // Step 2: New owner accepts
        vm.prank(alice);
        portal.acceptOwnership();

        // Ownership transferred
        assertEq(portal.owner(), alice);
        assertEq(portal.pendingOwner(), address(0));
    }

    function test_AcceptOwnership_RevertWhenNotPendingOwner() public {
        vm.prank(owner);
        portal.transferOwnership(alice);

        // Bob cannot accept
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        portal.acceptOwnership();
    }

    function test_TransferOwnership_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        portal.transferOwnership(bob);
    }

    function test_TransferOwnership_CanCancelByTransferringToZero() public {
        // Initiate transfer
        vm.prank(owner);
        portal.transferOwnership(alice);
        assertEq(portal.pendingOwner(), alice);

        // Cancel by transferring to zero (or another address)
        vm.prank(owner);
        portal.transferOwnership(address(0));
        assertEq(portal.pendingOwner(), address(0));

        // Alice can no longer accept
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        portal.acceptOwnership();
    }

    function test_TransferOwnership_CanChangeBeforeAccept() public {
        // Initiate transfer to alice
        vm.prank(owner);
        portal.transferOwnership(alice);

        // Change to bob before alice accepts
        vm.prank(owner);
        portal.transferOwnership(bob);

        assertEq(portal.pendingOwner(), bob);

        // Alice can no longer accept
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        portal.acceptOwnership();

        // Bob can accept
        vm.prank(bob);
        portal.acceptOwnership();
        assertEq(portal.owner(), bob);
    }

    function test_NewOwnerCanManageFees() public {
        // Transfer ownership
        vm.prank(owner);
        portal.transferOwnership(alice);
        vm.prank(alice);
        portal.acceptOwnership();

        // New owner can set fees
        vm.prank(alice);
        portal.setBaseFee(0.005 ether);
        assertEq(portal.baseFee(), 0.005 ether);

        // Old owner cannot
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        portal.setBaseFee(0.001 ether);
    }

    function test_RenounceOwnership() public {
        vm.prank(owner);
        portal.renounceOwnership();

        assertEq(portal.owner(), address(0));

        // No one can set fees now
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        portal.setBaseFee(0.002 ether);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_SendMessage(
        bytes calldata message,
        uint256 extraFee
    ) public {
        extraFee = bound(extraFee, 0, 1 ether);
        uint256 requiredFee = portal.calculateFee(message.length);

        vm.prank(alice);
        uint256 nonce = portal.sendMessage{ value: requiredFee + extraFee }(message);

        assertEq(nonce, 0);
        assertGe(address(portal).balance, requiredFee);
    }

    function testFuzz_FeeConfiguration(
        uint256 baseFee,
        uint256 feePerByte
    ) public {
        baseFee = bound(baseFee, 0, 1 ether);
        feePerByte = bound(feePerByte, 0, 10000 wei);

        vm.startPrank(owner);
        portal.setBaseFee(baseFee);
        portal.setFeePerByte(feePerByte);
        vm.stopPrank();

        assertEq(portal.baseFee(), baseFee);
        assertEq(portal.feePerByte(), feePerByte);
    }

    function testFuzz_PayloadEncodingConsistency(
        address sender,
        bytes memory message
    ) public {
        // Verify that the portal's encoding matches the library's encoding
        uint256 fee = portal.calculateFee(message.length);

        vm.deal(sender, fee);
        vm.prank(sender);

        vm.recordLogs();
        portal.sendMessage{ value: fee }(message);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes memory emittedPayload = abi.decode(entries[0].data, (bytes));

        // Decode using library
        (address decodedSender, uint256 decodedNonce, bytes memory decodedMessage) =
            PortalMessage.decode(emittedPayload);

        assertEq(decodedSender, sender, "Sender should match");
        assertEq(decodedNonce, 0, "First message nonce should be 0");
        assertEq(keccak256(decodedMessage), keccak256(message), "Message should match");
    }
}
