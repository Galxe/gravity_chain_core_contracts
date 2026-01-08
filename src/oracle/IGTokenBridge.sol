// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IGTokenBridge
/// @author Gravity Team
/// @notice Interface for the GTokenBridge contract deployed on Ethereum
/// @dev Locks G tokens (ERC20) on Ethereum and sends bridge message via GravityPortal.
///      Works with NativeTokenMinter on Gravity to mint native G tokens.
interface IGTokenBridge {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when G tokens are locked for bridging
    /// @param from The address that locked the tokens
    /// @param recipient The recipient address on Gravity
    /// @param amount The amount of tokens locked
    /// @param nonce The portal nonce for this bridge operation
    event TokensLocked(
        address indexed from,
        address indexed recipient,
        uint256 amount,
        uint256 indexed nonce
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Cannot bridge zero amount
    error ZeroAmount();

    /// @notice Cannot bridge to zero address
    error ZeroRecipient();

    /// @notice Token transfer failed
    error TransferFailed();

    // ========================================================================
    // BRIDGE FUNCTION
    // ========================================================================

    /// @notice Lock G tokens and bridge to Gravity
    /// @dev Caller must approve this contract to spend G tokens first.
    ///      ETH must be sent to cover the portal fee.
    ///      Message format: abi.encode(amount, recipient)
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity chain
    /// @return messageNonce The portal nonce assigned to this bridge operation
    function bridgeToGravity(uint256 amount, address recipient) external payable returns (uint256 messageNonce);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the G token contract address
    /// @return The G token (ERC20) address
    function gToken() external view returns (address);

    /// @notice Get the GravityPortal contract address
    /// @return The GravityPortal address
    function gravityPortal() external view returns (address);

    /// @notice Calculate the fee required for bridging
    /// @dev Delegates to GravityPortal.calculateFee with the encoded message length
    /// @param amount The amount to bridge (used to calculate message length)
    /// @param recipient The recipient address (used to calculate message length)
    /// @return requiredFee The required fee in ETH
    function calculateBridgeFee(uint256 amount, address recipient) external view returns (uint256 requiredFee);
}

