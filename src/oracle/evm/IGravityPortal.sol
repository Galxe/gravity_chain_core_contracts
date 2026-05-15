// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IGravityPortal
/// @author Gravity Team
/// @notice Interface for the GravityPortal contract deployed on Ethereum
/// @dev Entry point for sending messages from Ethereum to Gravity chain.
///      Messages are fee-based with configurable baseFee and feePerByte.
///      Uses compact encoding: sender (20 bytes) + nonce (16 bytes) + message (variable).
///      The contract is Ownable2Step and Pausable; `pause()` halts `send()`.
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

    /// @notice Fee provided exceeds the maximum allowed (2x required fee)
    /// @param required The required fee amount
    /// @param provided The provided fee amount
    error ExcessiveFee(uint256 required, uint256 provided);

    /// @notice Fee transfer to recipient failed
    error TransferFailed();

    /// @notice A fee config value exceeds its hard ceiling
    /// @param provided The rejected value
    /// @param maximum The hard ceiling
    error FeeExceedsMaximum(uint256 provided, uint256 maximum);

    /// @notice Withdrawal amount exceeds the tracked accumulated fees
    /// @param requested The requested withdrawal amount
    /// @param available The currently accumulated fee balance
    error InsufficientAccumulatedFees(uint256 requested, uint256 available);

    // ========================================================================
    // MESSAGE BRIDGING
    // ========================================================================

    /// @notice Send a message to Gravity
    /// @dev The payload uses compact encoding: sender (20B) || nonce (16B) || message.
    ///      Reverts when the contract is paused.
    /// @param message The message body to send
    /// @return messageNonce The nonce assigned to this message
    function send(
        bytes calldata message
    ) external payable returns (uint128 messageNonce);

    // ========================================================================
    // FEE MANAGEMENT (Owner Only)
    // ========================================================================

    /// @notice Set the base fee for bridge operations
    /// @dev Reverts if newBaseFee > MAX_BASE_FEE.
    /// @param newBaseFee The new base fee in wei
    function setBaseFee(
        uint256 newBaseFee
    ) external;

    /// @notice Set the fee per byte of payload
    /// @dev Reverts if newFeePerByte > MAX_FEE_PER_BYTE.
    /// @param newFeePerByte The new fee per byte in wei
    function setFeePerByte(
        uint256 newFeePerByte
    ) external;

    /// @notice Set the fee recipient address
    /// @param newRecipient The new fee recipient
    function setFeeRecipient(
        address newRecipient
    ) external;

    /// @notice Withdraw all accumulated fees to the fee recipient
    function withdrawFees() external;

    /// @notice Withdraw a specific amount of accumulated fees to the fee recipient
    /// @param amount The amount to withdraw; must be <= accumulatedFees()
    function withdrawFees(
        uint256 amount
    ) external;

    // ========================================================================
    // PAUSE (Owner Only)
    // ========================================================================

    /// @notice Pause the contract — halts `send()`
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

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

    /// @notice Get the fees collected via `send()` that are available to withdraw
    /// @dev ETH force-sent to the contract is NOT counted here.
    /// @return The accumulated fee balance in wei
    function accumulatedFees() external view returns (uint256);

    /// @notice The hard ceiling on `baseFee`
    /// @return The maximum base fee in wei
    function MAX_BASE_FEE() external view returns (uint256);

    /// @notice The hard ceiling on `feePerByte`
    /// @return The maximum fee per byte in wei
    function MAX_FEE_PER_BYTE() external view returns (uint256);

    /// @notice Calculate the required fee for a message of given length
    /// @dev Fee = baseFee + (encodedPayloadLength * feePerByte)
    ///      Encoded payload = 36 bytes (sender + nonce) + message length
    /// @param messageLength Length of the message in bytes
    /// @return requiredFee The required fee in wei
    function calculateFee(
        uint256 messageLength
    ) external view returns (uint256 requiredFee);
}
