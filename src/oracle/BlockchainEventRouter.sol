// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IBlockchainEventRouter, IMessageHandler } from "./IBlockchainEventRouter.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title BlockchainEventRouter
/// @author Gravity Team
/// @notice Routes blockchain events from NativeOracle to application handlers based on sender
/// @dev Registered as callback for BLOCKCHAIN EventType sources in NativeOracle.
///      Decodes payload as: abi.encode(sender, nonce, message) and routes to registered handler.
///      Handler registration is controlled by GOVERNANCE.
contract BlockchainEventRouter is IBlockchainEventRouter {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Gas limit for handler execution
    /// @dev Prevents handlers from consuming excessive gas
    uint256 public constant HANDLER_GAS_LIMIT = 400_000;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Registered handlers: sender address => handler contract
    mapping(address => address) private _handlers;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @inheritdoc IBlockchainEventRouter
    function initialize() external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        _initialized = true;
    }

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Require the contract to be initialized
    modifier whenInitialized() {
        if (!_initialized) {
            revert RouterNotInitialized();
        }
        _;
    }

    // ========================================================================
    // HANDLER REGISTRATION (GOVERNANCE Only)
    // ========================================================================

    /// @inheritdoc IBlockchainEventRouter
    function registerHandler(address sender, address handler) external whenInitialized {
        requireAllowed(SystemAddresses.GOVERNANCE);

        _handlers[sender] = handler;

        emit HandlerRegistered(sender, handler);
    }

    /// @inheritdoc IBlockchainEventRouter
    function unregisterHandler(address sender) external whenInitialized {
        requireAllowed(SystemAddresses.GOVERNANCE);

        delete _handlers[sender];

        emit HandlerUnregistered(sender);
    }

    // ========================================================================
    // ORACLE CALLBACK
    // ========================================================================

    /// @notice Called by NativeOracle when a blockchain event is recorded
    /// @dev Decodes payload and routes to appropriate handler
    /// @param dataHash The hash of the recorded data
    /// @param payload The event payload: abi.encode(sender, nonce, message)
    function onOracleEvent(bytes32 dataHash, bytes calldata payload) external whenInitialized {
        // Only NativeOracle can call this
        if (msg.sender != SystemAddresses.NATIVE_ORACLE) {
            revert OnlyNativeOracle();
        }

        // Decode blockchain event payload: (sender, nonce, message)
        (address sender, uint256 eventNonce, bytes memory message) = abi.decode(
            payload,
            (address, uint256, bytes)
        );

        // Look up handler for this sender
        address handler = _handlers[sender];
        if (handler == address(0)) {
            // No handler registered - emit failure event but don't revert
            emit RoutingFailed(dataHash, sender, abi.encodePacked("No handler registered"));
            return;
        }

        // Route to handler with limited gas
        try IMessageHandler(handler).handleMessage{ gas: HANDLER_GAS_LIMIT }(
            dataHash,
            sender,
            eventNonce,
            message
        ) {
            emit MessageRouted(dataHash, sender, handler);
        } catch (bytes memory reason) {
            emit RoutingFailed(dataHash, sender, reason);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IBlockchainEventRouter
    function getHandler(address sender) external view returns (address handler) {
        return _handlers[sender];
    }

    /// @inheritdoc IBlockchainEventRouter
    function isInitialized() external view returns (bool) {
        return _initialized;
    }
}

