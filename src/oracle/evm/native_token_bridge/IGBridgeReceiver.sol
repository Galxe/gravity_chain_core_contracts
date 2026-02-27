// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IGBridgeReceiver
/// @author Gravity Team
/// @notice Interface for the GBridgeReceiver contract on Gravity
/// @dev Mints native G tokens when bridge messages are received from GBridgeSender.
///      Inherits from BlockchainEventHandler to receive routed messages from NativeOracle.
///      Uses a system precompile to mint native tokens.
interface IGBridgeReceiver {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when native G tokens are minted
    /// @param recipient The address receiving the minted tokens
    /// @param amount The amount of tokens minted
    /// @param nonce The bridge nonce (for tracking)
    event NativeMinted(address indexed recipient, uint256 amount, uint128 indexed nonce);

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Message sender is not the trusted bridge
    /// @param sender The actual sender
    /// @param expected The expected trusted bridge address
    error InvalidSender(address sender, address expected);

    /// @notice Nonce has already been processed (replay protection)
    /// @param nonce The duplicate nonce
    error AlreadyProcessed(uint128 nonce);

    /// @notice Native token mint via precompile failed
    /// @param recipient The intended recipient
    /// @param amount The amount that failed to mint
    error MintFailed(address recipient, uint256 amount);

    /// @notice Source chain ID does not match trusted source
    /// @param provided The provided source chain ID
    /// @param expected The expected trusted source chain ID
    error InvalidSourceChain(uint256 provided, uint256 expected);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check if a nonce has been processed
    /// @param nonce The nonce to check
    /// @return True if the nonce has been processed
    function isProcessed(
        uint128 nonce
    ) external view returns (bool);

    /// @notice Get the trusted bridge address on Ethereum
    /// @return The trusted GBridgeSender address
    function trustedBridge() external view returns (address);

    /// @notice Get the trusted source chain ID
    /// @return The trusted source chain ID
    function trustedSourceId() external view returns (uint256);
}

/// @title INativeMintPrecompile
/// @author Gravity Team
/// @notice Interface for the system precompile that mints native tokens
/// @dev This is a privileged precompile that only authorized contracts can call
interface INativeMintPrecompile {
    /// @notice Mint native tokens to a recipient
    /// @param recipient The address to receive the tokens
    /// @param amount The amount to mint (in wei)
    function mint(
        address recipient,
        uint256 amount
    ) external;
}

