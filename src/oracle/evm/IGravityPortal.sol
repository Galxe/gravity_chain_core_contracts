// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IGravityPortal
/// @author Gravity Team
/// @notice Interface for the GravityPortal contract deployed on Ethereum
/// @dev Entry point for sending messages from Ethereum to Gravity chain.
///      Messages are fee-based with configurable baseFee and feePerByte.
///      Uses compact encoding: sender (20 bytes) + nonce (16 bytes) + message (variable).
interface IGravityPortal {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a message is sent to Gravity
    /// @param nonce The unique nonce for this message (extracted for consensus engine)
    /// @param payload The encoded payload: sender (20B) || nonce (16B) || message
    event MessageSent(uint128 indexed nonce, uint256 indexed block_number, bytes payload);

    /// @notice Emitted when fee configuration is updated
    /// @param baseFee The new base fee
    /// @param feePerByte The new fee per byte
    event FeeConfigUpdated(uint256 baseFee, uint256 feePerByte);

    /// @notice Emitted when fee recipient is updated
    /// @param oldRecipient The previous fee recipient
    /// @param newRecipient The new fee recipient
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when fees are withdrawn
    /// @param recipient The address receiving the fees
    /// @param amount The amount withdrawn
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Insufficient fee provided for the message
    /// @param required The required fee amount
    /// @param provided The provided fee amount
    error InsufficientFee(uint256 required, uint256 provided);

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice No fees available to withdraw
    error NoFeesToWithdraw();

    /// @notice Fee refund to sender failed
    error RefundFailed();

    /// @notice Fee transfer to recipient failed
    error TransferFailed();

    // ========================================================================
    // MESSAGE BRIDGING
    // ========================================================================

    /// @notice Send a message to Gravity
    /// @dev The payload uses compact encoding: sender (20B) || nonce (16B) || message
    /// @param message The message body to send
    /// @return messageNonce The nonce assigned to this message
    function send(
        bytes calldata message
    ) external payable returns (uint128 messageNonce);

    // ========================================================================
    // FEE MANAGEMENT (Owner Only)
    // ========================================================================

    /// @notice Set the base fee for bridge operations
    /// @param newBaseFee The new base fee in wei
    function setBaseFee(
        uint256 newBaseFee
    ) external;

    /// @notice Set the fee per byte of payload
    /// @param newFeePerByte The new fee per byte in wei
    function setFeePerByte(
        uint256 newFeePerByte
    ) external;

    /// @notice Set the fee recipient address
    /// @param newRecipient The new fee recipient
    function setFeeRecipient(
        address newRecipient
    ) external;

    /// @notice Withdraw collected fees to the fee recipient
    function withdrawFees() external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the current base fee
    /// @return The base fee in wei
    function baseFee() external view returns (uint256);

    /// @notice Get the current fee per byte
    /// @return The fee per byte in wei
    function feePerByte() external view returns (uint256);

    /// @notice Get the current fee recipient
    /// @return The fee recipient address
    function feeRecipient() external view returns (address);

    /// @notice Get the current nonce (next message will use this nonce)
    /// @return The current nonce
    function nonce() external view returns (uint128);

    /// @notice Calculate the required fee for a message of given length
    /// @dev Fee = baseFee + (encodedPayloadLength * feePerByte)
    ///      Encoded payload = 36 bytes (sender + nonce) + message length
    /// @param messageLength Length of the message in bytes
    /// @return requiredFee The required fee in wei
    function calculateFee(
        uint256 messageLength
    ) external view returns (uint256 requiredFee);
}
