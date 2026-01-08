// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title INativeTokenMinter
/// @author Gravity Team
/// @notice Interface for the NativeTokenMinter contract on Gravity
/// @dev Mints native G tokens when bridge messages are received from GTokenBridge.
///      Inherits from BlockchainEventHandler to receive routed messages from NativeOracle.
///      Uses a system precompile to mint native tokens.
interface INativeTokenMinter {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when native G tokens are minted
    /// @param recipient The address receiving the minted tokens
    /// @param amount The amount of tokens minted
    /// @param nonce The bridge nonce (for tracking)
    event NativeMinted(address indexed recipient, uint256 amount, uint128 indexed nonce);

    /// @notice Emitted when minting fails (logged but doesn't revert router)
    /// @param nonce The bridge nonce that failed
    /// @param reason The failure reason
    event MintFailed(uint128 indexed nonce, bytes reason);

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

    /// @notice Minter has not been initialized
    error MinterNotInitialized();

    /// @notice Mint precompile call failed
    error MintPrecompileFailed();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the minter
    /// @dev Can only be called once by GENESIS
    function initialize() external;

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
    /// @return The trusted GTokenBridge address
    function trustedBridge() external view returns (address);

    /// @notice Check if the minter is initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool);
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
