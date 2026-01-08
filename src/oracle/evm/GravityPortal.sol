// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGravityPortal } from "./IGravityPortal.sol";
import { PortalMessage } from "./PortalMessage.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";

/// @title GravityPortal
/// @author Gravity Team
/// @notice Entry point on Ethereum for sending messages to Gravity chain
/// @dev Deployed on Ethereum (or other EVM chains). NOT deployed on Gravity.
///      Charges fees in native token (ETH) for message bridging.
///      Consensus engine monitors MessageSent events and bridges to Gravity.
///      Uses compact encoding via PortalMessage library: sender (20B) + nonce (32B) + message.
contract GravityPortal is IGravityPortal, Ownable2Step {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Base fee for any bridge operation (in wei)
    uint256 public baseFee;

    /// @notice Fee per byte of payload (in wei)
    uint256 public feePerByte;

    /// @notice Address receiving collected fees
    address public feeRecipient;

    /// @notice Monotonically increasing nonce for message ordering
    uint256 public nonce;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the GravityPortal
    /// @param initialOwner The initial owner address
    /// @param initialBaseFee The initial base fee in wei
    /// @param initialFeePerByte The initial fee per byte in wei
    /// @param initialFeeRecipient The initial fee recipient address
    constructor(
        address initialOwner,
        uint256 initialBaseFee,
        uint256 initialFeePerByte,
        address initialFeeRecipient
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();

        baseFee = initialBaseFee;
        feePerByte = initialFeePerByte;
        feeRecipient = initialFeeRecipient;
    }

    // ========================================================================
    // MESSAGE BRIDGING
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function sendMessage(
        bytes calldata message
    ) external payable returns (uint256 messageNonce) {
        // Encode full payload using compact encoding: sender (20B) + nonce (32B) + message
        messageNonce = nonce++;
        bytes memory payload = PortalMessage.encodeCalldata(msg.sender, messageNonce, message);

        // Calculate and validate fee
        uint256 requiredFee = _calculateFee(payload.length);
        if (msg.value < requiredFee) {
            revert InsufficientFee(requiredFee, msg.value);
        }

        // Compute payload hash
        bytes32 payloadHash = keccak256(payload);

        // Emit event for consensus engine to monitor (hash-only mode)
        emit MessageSent(payloadHash, msg.sender, messageNonce, payload);
    }

    /// @inheritdoc IGravityPortal
    function sendMessageWithData(
        bytes calldata message
    ) external payable returns (uint256 messageNonce) {
        // Encode full payload using compact encoding: sender (20B) + nonce (32B) + message
        messageNonce = nonce++;
        bytes memory payload = PortalMessage.encodeCalldata(msg.sender, messageNonce, message);

        // Calculate and validate fee
        uint256 requiredFee = _calculateFee(payload.length);
        if (msg.value < requiredFee) {
            revert InsufficientFee(requiredFee, msg.value);
        }

        // Compute payload hash
        bytes32 payloadHash = keccak256(payload);

        // Emit event for consensus engine to monitor (data mode - full storage on Gravity)
        emit MessageSentWithData(payloadHash, msg.sender, messageNonce, payload);
    }

    // ========================================================================
    // FEE MANAGEMENT (Owner Only)
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function setBaseFee(
        uint256 newBaseFee
    ) external onlyOwner {
        baseFee = newBaseFee;
        emit FeeConfigUpdated(newBaseFee, feePerByte);
    }

    /// @inheritdoc IGravityPortal
    function setFeePerByte(
        uint256 newFeePerByte
    ) external onlyOwner {
        feePerByte = newFeePerByte;
        emit FeeConfigUpdated(baseFee, newFeePerByte);
    }

    /// @inheritdoc IGravityPortal
    function setFeeRecipient(
        address newRecipient
    ) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /// @inheritdoc IGravityPortal
    function withdrawFees() external {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFeesToWithdraw();

        address recipient = feeRecipient;

        // Transfer fees to recipient
        (bool success,) = recipient.call{ value: balance }("");
        require(success, "Transfer failed");

        emit FeesWithdrawn(recipient, balance);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function calculateFee(
        uint256 messageLength
    ) external view returns (uint256 requiredFee) {
        // Estimate encoded payload length using compact encoding:
        // sender (20 bytes) + nonce (32 bytes) + message length = 52 + messageLength
        uint256 estimatedPayloadLength = PortalMessage.MIN_PAYLOAD_LENGTH + messageLength;
        return _calculateFee(estimatedPayloadLength);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Calculate fee for a given payload length
    /// @param payloadLength The length of the encoded payload in bytes
    /// @return The required fee in wei
    function _calculateFee(
        uint256 payloadLength
    ) internal view returns (uint256) {
        return baseFee + (payloadLength * feePerByte);
    }
}
