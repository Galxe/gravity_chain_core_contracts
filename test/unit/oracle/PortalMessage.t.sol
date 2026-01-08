// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";

/// @title PortalMessageTest
/// @notice Comprehensive unit tests for PortalMessage library assembly encoding/decoding
contract PortalMessageTest is Test {
    // ========================================================================
    // ENCODE TESTS
    // ========================================================================

    function test_Encode_BasicMessage() public pure {
        address sender = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        uint128 messageNonce = 42;
        bytes memory message = hex"deadbeef";

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);

        // Expected length: 20 (sender) + 16 (nonce) + 4 (message) = 40
        assertEq(payload.length, 40, "Payload length mismatch");

        // Verify by decoding
        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);
        assertEq(decodedSender, sender, "Sender mismatch");
        assertEq(decodedNonce, messageNonce, "Nonce mismatch");
        assertEq(decodedMessage, message, "Message mismatch");
    }

    function test_Encode_EmptyMessage() public pure {
        address sender = address(0xDEAD);
        uint128 messageNonce = 0;
        bytes memory message = "";

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);

        // Expected length: 20 + 16 + 0 = 36 (MIN_PAYLOAD_LENGTH)
        assertEq(payload.length, 36, "Payload length mismatch");

        // Verify by decoding
        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);
        assertEq(decodedSender, sender, "Sender mismatch");
        assertEq(decodedNonce, messageNonce, "Nonce mismatch");
        assertEq(decodedMessage.length, 0, "Message should be empty");
    }

    function test_Encode_MaxNonce() public pure {
        address sender = address(0xBEEF);
        uint128 messageNonce = type(uint128).max;
        bytes memory message = hex"01";

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);

        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);
        assertEq(decodedSender, sender, "Sender mismatch");
        assertEq(decodedNonce, messageNonce, "Nonce mismatch");
        assertEq(decodedMessage, message, "Message mismatch");
    }

    function test_Encode_LargeMessage() public pure {
        address sender = address(0x1);
        uint128 messageNonce = 123456789;
        bytes memory message = new bytes(1000);
        for (uint256 i = 0; i < 1000; i++) {
            message[i] = bytes1(uint8(i % 256));
        }

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);

        // Expected length: 20 + 16 + 1000 = 1036
        assertEq(payload.length, 1036, "Payload length mismatch");

        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);
        assertEq(decodedSender, sender, "Sender mismatch");
        assertEq(decodedNonce, messageNonce, "Nonce mismatch");
        assertEq(keccak256(decodedMessage), keccak256(message), "Message content mismatch");
    }

    // ========================================================================
    // ENCODE CALLDATA TESTS
    // ========================================================================

    function test_EncodeCalldata_BasicMessage() public view {
        address sender = address(0xCAFE);
        uint128 messageNonce = 100;
        bytes memory message = hex"aabbccdd";

        // Use this.encodeCalldataHelper to test calldata version
        bytes memory payload = this.encodeCalldataHelper(sender, messageNonce, message);

        assertEq(payload.length, 40, "Payload length mismatch");

        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);
        assertEq(decodedSender, sender, "Sender mismatch");
        assertEq(decodedNonce, messageNonce, "Nonce mismatch");
        assertEq(decodedMessage, message, "Message mismatch");
    }

    function encodeCalldataHelper(
        address sender,
        uint128 messageNonce,
        bytes calldata message
    ) external pure returns (bytes memory) {
        return PortalMessage.encodeCalldata(sender, messageNonce, message);
    }

    // ========================================================================
    // DECODE TESTS
    // ========================================================================

    function test_Decode_RevertWhenInsufficientLength() public {
        bytes memory shortPayload = new bytes(35); // Less than MIN_PAYLOAD_LENGTH

        vm.expectRevert(abi.encodeWithSelector(PortalMessage.InsufficientDataLength.selector, 35, 36));
        this.decodeHelper(shortPayload);
    }

    function test_Decode_MinimumValidPayload() public pure {
        // Create minimum valid payload: 20 bytes sender + 16 bytes nonce = 36 bytes
        address expectedSender = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        uint128 expectedNonce = 999;
        bytes memory message = "";

        bytes memory payload = PortalMessage.encode(expectedSender, expectedNonce, message);

        (address sender, uint128 messageNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);

        assertEq(sender, expectedSender, "Sender mismatch");
        assertEq(messageNonce, expectedNonce, "Nonce mismatch");
        assertEq(decodedMessage.length, 0, "Message should be empty");
    }

    // ========================================================================
    // PARTIAL DECODE TESTS
    // ========================================================================

    function test_DecodeSender() public pure {
        address expectedSender = address(0xabCDEF1234567890ABcDEF1234567890aBCDeF12);
        uint128 messageNonce = 42;
        bytes memory message = hex"0102030405";

        bytes memory payload = PortalMessage.encode(expectedSender, messageNonce, message);
        address decodedSender = PortalMessage.decodeSender(payload);

        assertEq(decodedSender, expectedSender, "Sender mismatch");
    }

    function test_DecodeSender_RevertWhenTooShort() public {
        bytes memory shortPayload = new bytes(19); // Less than 20 bytes

        vm.expectRevert(abi.encodeWithSelector(PortalMessage.InsufficientDataLength.selector, 19, 20));
        this.decodeSenderHelper(shortPayload);
    }

    function test_DecodeNonce() public pure {
        address sender = address(0x1);
        uint128 expectedNonce = 12345678901234567890;
        bytes memory message = hex"ff";

        bytes memory payload = PortalMessage.encode(sender, expectedNonce, message);
        uint128 decodedNonce = PortalMessage.decodeNonce(payload);

        assertEq(decodedNonce, expectedNonce, "Nonce mismatch");
    }

    function test_DecodeNonce_RevertWhenTooShort() public {
        bytes memory shortPayload = new bytes(35); // Less than 36 bytes

        vm.expectRevert(abi.encodeWithSelector(PortalMessage.InsufficientDataLength.selector, 35, 36));
        this.decodeNonceHelper(shortPayload);
    }

    function test_DecodeSenderAndNonce() public pure {
        address expectedSender = address(0xfEDCBA0987654321FeDcbA0987654321fedCBA09);
        uint128 expectedNonce = type(uint128).max;
        bytes memory message = hex"68656c6c6f"; // "hello"

        bytes memory payload = PortalMessage.encode(expectedSender, expectedNonce, message);
        (address sender, uint128 messageNonce) = PortalMessage.decodeSenderAndNonce(payload);

        assertEq(sender, expectedSender, "Sender mismatch");
        assertEq(messageNonce, expectedNonce, "Nonce mismatch");
    }

    function test_DecodeSenderAndNonce_RevertWhenTooShort() public {
        bytes memory shortPayload = new bytes(35);

        vm.expectRevert(abi.encodeWithSelector(PortalMessage.InsufficientDataLength.selector, 35, 36));
        this.decodeSenderAndNonceHelper(shortPayload);
    }

    // ========================================================================
    // GET MESSAGE SLICE TESTS
    // ========================================================================

    function test_GetMessageSlice() public pure {
        address sender = address(0x1);
        uint128 messageNonce = 1;
        bytes memory message = hex"0102030405060708";

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);
        (uint256 messageStart, uint256 messageLength) = PortalMessage.getMessageSlice(payload);

        assertEq(messageLength, 8, "Message length mismatch");
        assertGt(messageStart, 0, "Message start should be non-zero");

        // Verify the slice points to correct data
        bytes memory extractedMessage = new bytes(messageLength);
        assembly {
            let destPtr := add(extractedMessage, 32)
            for { let i := 0 } lt(i, messageLength) { i := add(i, 32) } {
                mstore(add(destPtr, i), mload(add(messageStart, i)))
            }
        }
        assertEq(keccak256(extractedMessage), keccak256(message), "Slice content mismatch");
    }

    function test_GetMessageSlice_EmptyMessage() public pure {
        address sender = address(0x1);
        uint128 messageNonce = 1;
        bytes memory message = "";

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);
        (uint256 messageStart, uint256 messageLength) = PortalMessage.getMessageSlice(payload);

        assertEq(messageLength, 0, "Message length should be zero");
        assertGt(messageStart, 0, "Message start should be non-zero");
    }

    function test_GetMessageSlice_RevertWhenTooShort() public {
        bytes memory shortPayload = new bytes(35);

        vm.expectRevert(abi.encodeWithSelector(PortalMessage.InsufficientDataLength.selector, 35, 36));
        this.getMessageSliceHelper(shortPayload);
    }

    // ========================================================================
    // HELPER FUNCTIONS FOR REVERT TESTS
    // ========================================================================

    function decodeHelper(
        bytes memory payload
    ) external pure returns (address, uint128, bytes memory) {
        return PortalMessage.decode(payload);
    }

    function decodeSenderHelper(
        bytes memory payload
    ) external pure returns (address) {
        return PortalMessage.decodeSender(payload);
    }

    function decodeNonceHelper(
        bytes memory payload
    ) external pure returns (uint128) {
        return PortalMessage.decodeNonce(payload);
    }

    function decodeSenderAndNonceHelper(
        bytes memory payload
    ) external pure returns (address, uint128) {
        return PortalMessage.decodeSenderAndNonce(payload);
    }

    function getMessageSliceHelper(
        bytes memory payload
    ) external pure returns (uint256, uint256) {
        return PortalMessage.getMessageSlice(payload);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_EncodeDecodeRoundtrip(
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) public pure {
        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);

        // Verify length
        assertEq(payload.length, 36 + message.length, "Payload length mismatch");

        // Decode and verify
        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);

        assertEq(decodedSender, sender, "Sender roundtrip failed");
        assertEq(decodedNonce, messageNonce, "Nonce roundtrip failed");
        assertEq(keccak256(decodedMessage), keccak256(message), "Message roundtrip failed");
    }

    function testFuzz_EncodeCalldataRoundtrip(
        address sender,
        uint128 messageNonce,
        bytes calldata message
    ) external view {
        bytes memory payload = this.encodeCalldataHelper(sender, messageNonce, message);

        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);

        assertEq(decodedSender, sender, "Sender roundtrip failed");
        assertEq(decodedNonce, messageNonce, "Nonce roundtrip failed");
        assertEq(keccak256(decodedMessage), keccak256(message), "Message roundtrip failed");
    }

    function testFuzz_PartialDecode(
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) public pure {
        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);

        // Test all partial decode functions
        assertEq(PortalMessage.decodeSender(payload), sender, "decodeSender failed");
        assertEq(PortalMessage.decodeNonce(payload), messageNonce, "decodeNonce failed");

        (address s, uint128 n) = PortalMessage.decodeSenderAndNonce(payload);
        assertEq(s, sender, "decodeSenderAndNonce sender failed");
        assertEq(n, messageNonce, "decodeSenderAndNonce nonce failed");
    }

    function testFuzz_GetMessageSlice(
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) public pure {
        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);
        (, uint256 messageLength) = PortalMessage.getMessageSlice(payload);

        assertEq(messageLength, message.length, "Message length mismatch");
    }

    // ========================================================================
    // EDGE CASE TESTS
    // ========================================================================

    function test_ZeroAddressSender() public pure {
        address sender = address(0);
        uint128 messageNonce = 1;
        bytes memory message = hex"74657374"; // "test"

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);
        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);

        assertEq(decodedSender, address(0), "Zero address should roundtrip");
        assertEq(decodedNonce, messageNonce, "Nonce mismatch");
        assertEq(decodedMessage, message, "Message mismatch");
    }

    function test_ZeroNonce() public pure {
        address sender = address(0x1);
        uint128 messageNonce = 0;
        bytes memory message = hex"74657374"; // "test"

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);
        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);

        assertEq(decodedSender, sender, "Sender mismatch");
        assertEq(decodedNonce, 0, "Zero nonce should roundtrip");
        assertEq(decodedMessage, message, "Message mismatch");
    }

    function test_MaxValues() public pure {
        address sender = address(type(uint160).max);
        uint128 messageNonce = type(uint128).max;
        bytes memory message = hex"ffffffffffffffffffffffffffffffff";

        bytes memory payload = PortalMessage.encode(sender, messageNonce, message);
        (address decodedSender, uint128 decodedNonce, bytes memory decodedMessage) = PortalMessage.decode(payload);

        assertEq(decodedSender, sender, "Max sender mismatch");
        assertEq(decodedNonce, messageNonce, "Max nonce mismatch");
        assertEq(decodedMessage, message, "Message mismatch");
    }

    function test_NonAlignedMessageLength() public pure {
        address sender = address(0x1);
        uint128 messageNonce = 1;

        // Test various non-32-aligned message lengths
        for (uint256 len = 1; len <= 65; len++) {
            bytes memory message = new bytes(len);
            for (uint256 i = 0; i < len; i++) {
                message[i] = bytes1(uint8(i));
            }

            bytes memory payload = PortalMessage.encode(sender, messageNonce, message);
            (,, bytes memory decodedMessage) = PortalMessage.decode(payload);

            assertEq(decodedMessage.length, len, "Decoded message length mismatch");
            assertEq(keccak256(decodedMessage), keccak256(message), "Decoded message content mismatch");
        }
    }

    // ========================================================================
    // GAS COMPARISON TESTS
    // ========================================================================

    function test_GasComparison_Encode() public pure {
        address sender = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        uint128 messageNonce = 42;
        bytes memory message = hex"deadbeefcafebabe0102030405060708";

        // Compact encoding
        bytes memory compactPayload = PortalMessage.encode(sender, messageNonce, message);

        // ABI encoding for comparison
        bytes memory abiPayload = abi.encode(sender, messageNonce, message);

        // Compact should be significantly smaller
        assertLt(compactPayload.length, abiPayload.length, "Compact should be smaller than ABI encoding");

        // Verify compact payload is exactly 36 + message.length
        assertEq(compactPayload.length, 36 + message.length, "Compact length should be 36 + message.length");
    }
}
