// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IOracleCallback } from "./INativeOracle.sol";

/// @title IBlockchainEventRouter
/// @author Gravity Team
/// @notice Interface for the BlockchainEventRouter contract on Gravity
/// @dev Routes blockchain events from NativeOracle to application handlers based on sender address.
///      Registered as callback for BLOCKCHAIN EventType sources in NativeOracle.
///      Decodes payload as: abi.encode(sender, nonce, message)
interface IBlockchainEventRouter is IOracleCallback {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a handler is registered for a sender
    /// @param sender The sender address on the source chain
    /// @param handler The handler contract address on Gravity
    event HandlerRegistered(address indexed sender, address indexed handler);

    /// @notice Emitted when a handler is unregistered
    /// @param sender The sender address that was unregistered
    event HandlerUnregistered(address indexed sender);

    /// @notice Emitted when a message is successfully routed to a handler
    /// @param dataHash The hash of the original payload
    /// @param sender The sender address from the payload
    /// @param handler The handler that processed the message
    event MessageRouted(bytes32 indexed dataHash, address indexed sender, address indexed handler);

    /// @notice Emitted when routing fails (handler not found or handler reverted)
    /// @param dataHash The hash of the original payload
    /// @param sender The sender address from the payload
    /// @param reason The failure reason
    event RoutingFailed(bytes32 indexed dataHash, address indexed sender, bytes reason);

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Only NativeOracle can call onOracleEvent
    error OnlyNativeOracle();

    /// @notice No handler registered for the sender
    /// @param sender The sender address with no handler
    error HandlerNotRegistered(address sender);

    /// @notice Router has not been initialized
    error RouterNotInitialized();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the router
    /// @dev Can only be called once by GENESIS
    function initialize() external;

    // ========================================================================
    // HANDLER REGISTRATION (GOVERNANCE Only)
    // ========================================================================

    /// @notice Register a handler for a sender address
    /// @dev Only callable by GOVERNANCE
    /// @param sender The sender address on the source chain (e.g., GTokenBridge on Ethereum)
    /// @param handler The handler contract address on Gravity
    function registerHandler(address sender, address handler) external;

    /// @notice Unregister a handler for a sender address
    /// @dev Only callable by GOVERNANCE
    /// @param sender The sender address to unregister
    function unregisterHandler(address sender) external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the handler for a sender address
    /// @param sender The sender address
    /// @return handler The handler contract address (address(0) if not registered)
    function getHandler(address sender) external view returns (address handler);

    /// @notice Check if the router is initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool);
}

/// @title IMessageHandler
/// @author Gravity Team
/// @notice Interface for handlers that receive routed messages from BlockchainEventRouter
/// @dev Implement this interface to handle specific sender's messages
interface IMessageHandler {
    /// @notice Handle a routed message from BlockchainEventRouter
    /// @dev Only BlockchainEventRouter should call this
    /// @param dataHash The hash of the original payload
    /// @param sender The sender address on the source chain
    /// @param nonce The message nonce from the source chain
    /// @param message The message body (application-specific encoding)
    function handleMessage(
        bytes32 dataHash,
        address sender,
        uint256 nonce,
        bytes calldata message
    ) external;
}

