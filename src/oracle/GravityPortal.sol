// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGravityPortal } from "./IGravityPortal.sol";

/// @title GravityPortal
/// @author Gravity Team
/// @notice Entry point on Ethereum for sending messages to Gravity chain
/// @dev Deployed on Ethereum (or other EVM chains). NOT deployed on Gravity.
///      Charges fees in native token (ETH) for message bridging.
///      Consensus engine monitors MessageSent events and bridges to Gravity.
contract GravityPortal is IGravityPortal {
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

    /// @notice Contract owner (can update fee configuration)
    address public owner;

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
    ) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();

        owner = initialOwner;
        baseFee = initialBaseFee;
        feePerByte = initialFeePerByte;
        feeRecipient = initialFeeRecipient;
    }

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Restrict to owner only
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ========================================================================
    // MESSAGE BRIDGING
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function sendMessage(bytes calldata message) external payable returns (uint256 messageNonce) {
        // Encode full payload: sender + nonce + message
        messageNonce = nonce++;
        bytes memory payload = abi.encode(msg.sender, messageNonce, message);

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
    function sendMessageWithData(bytes calldata message) external payable returns (uint256 messageNonce) {
        // Encode full payload: sender + nonce + message
        messageNonce = nonce++;
        bytes memory payload = abi.encode(msg.sender, messageNonce, message);

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
    function setBaseFee(uint256 newBaseFee) external onlyOwner {
        baseFee = newBaseFee;
        emit FeeConfigUpdated(newBaseFee, feePerByte);
    }

    /// @inheritdoc IGravityPortal
    function setFeePerByte(uint256 newFeePerByte) external onlyOwner {
        feePerByte = newFeePerByte;
        emit FeeConfigUpdated(baseFee, newFeePerByte);
    }

    /// @inheritdoc IGravityPortal
    function setFeeRecipient(address newRecipient) external onlyOwner {
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

    /// @notice Transfer ownership to a new address
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function calculateFee(uint256 messageLength) external view returns (uint256 requiredFee) {
        // Estimate encoded payload length:
        // sender (32 bytes) + nonce (32 bytes) + message length offset (32 bytes) + message length (32 bytes) + message
        // Simplified: ~128 bytes overhead + message length (rounded up to 32-byte words)
        uint256 estimatedPayloadLength = 128 + ((messageLength + 31) / 32) * 32;
        return _calculateFee(estimatedPayloadLength);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Calculate fee for a given payload length
    /// @param payloadLength The length of the encoded payload in bytes
    /// @return The required fee in wei
    function _calculateFee(uint256 payloadLength) internal view returns (uint256) {
        return baseFee + (payloadLength * feePerByte);
    }
}

