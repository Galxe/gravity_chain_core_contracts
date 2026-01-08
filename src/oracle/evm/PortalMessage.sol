// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PortalMessage Library
/// @author Gravity Team
/// @notice A library for compact encoding and decoding of portal messages using assembly
/// @dev Uses packed encoding: sender (20 bytes) + nonce (32 bytes) + message (variable)
///      Total overhead: 52 bytes (vs 128+ bytes with abi.encode)
library PortalMessage {
    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Insufficient data length for decoding
    /// @param length The actual length of the data
    /// @param required The minimum required length
    error InsufficientDataLength(uint256 length, uint256 required);

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Minimum payload length: 20 (sender) + 32 (nonce) = 52 bytes
    uint256 internal constant MIN_PAYLOAD_LENGTH = 52;

    /// @notice Offset for sender address (starts at position 0, 20 bytes)
    uint256 internal constant SENDER_OFFSET = 20;

    /// @notice Offset for nonce (starts at position 20, 32 bytes)
    uint256 internal constant NONCE_OFFSET = 52;

    // ========================================================================
    // ENCODING
    // ========================================================================

    /// @notice Encodes sender, nonce, and message into a compact byte array
    /// @dev Layout: sender (20 bytes) || nonce (32 bytes) || message (variable)
    /// @param sender The sender address
    /// @param messageNonce The message nonce
    /// @param message The message data
    /// @return payload The encoded payload
    function encode(
        address sender,
        uint256 messageNonce,
        bytes memory message
    ) internal pure returns (bytes memory payload) {
        // Calculate total length: 20 + 32 + message.length
        uint256 totalLength = MIN_PAYLOAD_LENGTH + message.length;

        // Allocate memory for the payload
        payload = new bytes(totalLength);

        // solhint-disable-next-line no-inline-assembly
        assembly {
            // payload points to the length slot, data starts at payload + 32
            let payloadData := add(payload, 32)

            // Store sender (20 bytes) at the beginning
            // We need to shift the address left by 96 bits (12 bytes) to align it
            // Then store it at payloadData, which will write 32 bytes but we only use 20
            mstore(payloadData, shl(96, sender))

            // Store nonce (32 bytes) at offset 20
            mstore(add(payloadData, 20), messageNonce)

            // Copy message data starting at offset 52
            // message points to length slot, data starts at message + 32
            let messageData := add(message, 32)
            let messageLen := mload(message)
            let destPtr := add(payloadData, 52)

            // Copy message in 32-byte chunks
            for { let i := 0 } lt(i, messageLen) { i := add(i, 32) } {
                mstore(add(destPtr, i), mload(add(messageData, i)))
            }
        }
    }

    /// @notice Encodes sender, nonce, and calldata message into a compact byte array
    /// @dev More gas-efficient version for calldata input
    /// @param sender The sender address
    /// @param messageNonce The message nonce
    /// @param message The message data (calldata)
    /// @return payload The encoded payload
    function encodeCalldata(
        address sender,
        uint256 messageNonce,
        bytes calldata message
    ) internal pure returns (bytes memory payload) {
        // Calculate total length: 20 + 32 + message.length
        uint256 totalLength = MIN_PAYLOAD_LENGTH + message.length;

        // Allocate memory for the payload
        payload = new bytes(totalLength);

        // solhint-disable-next-line no-inline-assembly
        assembly {
            // payload points to the length slot, data starts at payload + 32
            let payloadData := add(payload, 32)

            // Store sender (20 bytes) at the beginning
            mstore(payloadData, shl(96, sender))

            // Store nonce (32 bytes) at offset 20
            mstore(add(payloadData, 20), messageNonce)

            // Copy message calldata starting at offset 52
            calldatacopy(add(payloadData, 52), message.offset, message.length)
        }
    }

    // ========================================================================
    // DECODING
    // ========================================================================

    /// @notice Decodes a payload into sender, nonce, and message
    /// @dev Expects layout: sender (20 bytes) || nonce (32 bytes) || message (variable)
    /// @param payload The encoded payload
    /// @return sender The extracted sender address
    /// @return messageNonce The extracted nonce
    /// @return message The remaining message data
    function decode(
        bytes memory payload
    ) internal pure returns (address sender, uint256 messageNonce, bytes memory message) {
        if (payload.length < MIN_PAYLOAD_LENGTH) {
            revert InsufficientDataLength(payload.length, MIN_PAYLOAD_LENGTH);
        }

        uint256 messageLength = payload.length - MIN_PAYLOAD_LENGTH;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            // payload points to length slot, data starts at payload + 32
            let payloadData := add(payload, 32)

            // Load sender (20 bytes) from the beginning
            // mload loads 32 bytes, we need to shift right by 96 bits (12 bytes) to get the address
            sender := shr(96, mload(payloadData))

            // Load nonce (32 bytes) from offset 20
            messageNonce := mload(add(payloadData, 20))

            // Allocate memory for message
            // Get free memory pointer
            message := mload(0x40)

            // Store message length
            mstore(message, messageLength)

            // Update free memory pointer (length slot + data, rounded up to 32 bytes)
            mstore(0x40, add(add(message, 32), and(add(messageLength, 31), not(31))))

            // Copy message data
            let srcPtr := add(payloadData, 52)
            let destPtr := add(message, 32)

            for { let i := 0 } lt(i, messageLength) { i := add(i, 32) } {
                mstore(add(destPtr, i), mload(add(srcPtr, i)))
            }
        }
    }

    /// @notice Decodes only the sender from a payload (gas-efficient for partial decoding)
    /// @param payload The encoded payload
    /// @return sender The extracted sender address
    function decodeSender(
        bytes memory payload
    ) internal pure returns (address sender) {
        if (payload.length < SENDER_OFFSET) {
            revert InsufficientDataLength(payload.length, SENDER_OFFSET);
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            sender := shr(96, mload(add(payload, 32)))
        }
    }

    /// @notice Decodes only the nonce from a payload (gas-efficient for partial decoding)
    /// @param payload The encoded payload
    /// @return messageNonce The extracted nonce
    function decodeNonce(
        bytes memory payload
    ) internal pure returns (uint256 messageNonce) {
        if (payload.length < NONCE_OFFSET) {
            revert InsufficientDataLength(payload.length, NONCE_OFFSET);
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            messageNonce := mload(add(add(payload, 32), 20))
        }
    }

    /// @notice Decodes sender and nonce from a payload (gas-efficient for partial decoding)
    /// @param payload The encoded payload
    /// @return sender The extracted sender address
    /// @return messageNonce The extracted nonce
    function decodeSenderAndNonce(
        bytes memory payload
    ) internal pure returns (address sender, uint256 messageNonce) {
        if (payload.length < NONCE_OFFSET) {
            revert InsufficientDataLength(payload.length, NONCE_OFFSET);
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            let payloadData := add(payload, 32)
            sender := shr(96, mload(payloadData))
            messageNonce := mload(add(payloadData, 20))
        }
    }

    /// @notice Get the message portion of a payload without copying
    /// @dev Returns a memory slice pointing into the original payload
    /// @param payload The encoded payload
    /// @return messageStart Pointer to message start in memory
    /// @return messageLength Length of the message
    function getMessageSlice(
        bytes memory payload
    ) internal pure returns (uint256 messageStart, uint256 messageLength) {
        if (payload.length < MIN_PAYLOAD_LENGTH) {
            revert InsufficientDataLength(payload.length, MIN_PAYLOAD_LENGTH);
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Message starts at payload data + 52
            messageStart := add(add(payload, 32), 52)
            messageLength := sub(mload(payload), 52)
        }
    }
}

