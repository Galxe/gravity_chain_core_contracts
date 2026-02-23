// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGBridgeReceiver, INativeMintPrecompile } from "./IGBridgeReceiver.sol";
import { BlockchainEventHandler } from "../BlockchainEventHandler.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";

/// @title GBridgeReceiver
/// @author Gravity Team
/// @notice Mints native G tokens when bridge messages are received from GBridgeSender
/// @dev Deployed on Gravity only. Inherits BlockchainEventHandler to receive oracle callbacks.
///      Uses a system precompile to mint native tokens.
contract GBridgeReceiver is IGBridgeReceiver, BlockchainEventHandler {
    // ========================================================================
    // IMMUTABLES
    // ========================================================================

    /// @notice Trusted GBridgeSender address on Ethereum
    /// @dev Only messages from this sender are processed
    address public immutable trustedBridge;

    /// @notice Trusted source chain ID (e.g., Ethereum mainnet = 1)
    uint256 public immutable trustedSourceId;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Processed nonces for replay protection
    mapping(uint128 => bool) private _processedNonces;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the GBridgeReceiver
    /// @param trustedBridge_ The trusted GBridgeSender address on Ethereum
    /// @param trustedSourceId_ The trusted source chain ID (e.g., 1 for Ethereum mainnet)
    constructor(
        address trustedBridge_,
        uint256 trustedSourceId_
    ) {
        trustedBridge = trustedBridge_;
        trustedSourceId = trustedSourceId_;
    }

    // ========================================================================
    // MESSAGE HANDLER (Override from BlockchainEventHandler)
    // ========================================================================

    /// @notice Handle a parsed portal message from BlockchainEventHandler
    /// @dev Called after BlockchainEventHandler parses the oracle payload
    /// @param sourceType The source type from NativeOracle (unused, for future extensibility)
    /// @param sourceId The source identifier (chain ID, validated against trustedSourceId)
    /// @param oracleNonce The oracle nonce for this record (unused)
    /// @param sender The sender address on Ethereum (must be trusted bridge)
    /// @param messageNonce The message nonce from the source chain
    /// @param message The message body: abi.encode(amount, recipient)
    /// @return shouldStore Always true - bridge events should be stored in NativeOracle for verification
    function _handlePortalMessage(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) internal override returns (bool shouldStore) {
        // Silence unused variable warnings - these are for future extensibility
        (sourceType, oracleNonce);

        // Verify source chain ID
        if (sourceId != trustedSourceId) {
            revert InvalidSourceChain(sourceId, trustedSourceId);
        }

        // Verify sender is the trusted bridge (defense in depth)
        if (sender != trustedBridge) {
            revert InvalidSender(sender, trustedBridge);
        }

        // Check for replay
        if (_processedNonces[messageNonce]) {
            revert AlreadyProcessed(messageNonce);
        }

        // Decode message: (amount, recipient)
        (uint256 amount, address recipient) = abi.decode(message, (uint256, address));

        // Mark nonce as processed BEFORE minting (CEI pattern)
        _processedNonces[messageNonce] = true;

        // Mint native tokens via precompile (precompile never reverts)
        bytes memory callData = abi.encodePacked(uint8(0x01), recipient, amount);
        (bool transferSuccess,) = SystemAddresses.NATIVE_MINT_PRECOMPILE.call(callData);
        if (!transferSuccess) {
            revert MintFailed(recipient, amount);
        }

        emit NativeMinted(recipient, amount, messageNonce);

        // Store bridge events in NativeOracle for verification and audit trail
        return true;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGBridgeReceiver
    function isProcessed(
        uint128 nonce
    ) external view returns (bool) {
        return _processedNonces[nonce];
    }
}

