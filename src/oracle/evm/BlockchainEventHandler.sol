// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IOracleCallback } from "../INativeOracle.sol";
import { PortalMessage } from "./PortalMessage.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";

/// @title BlockchainEventHandler
/// @author Gravity Team
/// @notice Abstract base contract for handling blockchain events from NativeOracle
/// @dev Implements IOracleCallback to receive oracle events. Parses portal message payload
///      and delegates to _handlePortalMessage() which derived contracts must implement.
///      Each handler is registered directly as a callback in NativeOracle for specific
///      (sourceType, sourceId) pairs.
abstract contract BlockchainEventHandler is IOracleCallback {
    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Only NativeOracle can call onOracleEvent
    error OnlyNativeOracle();

    // ========================================================================
    // ORACLE CALLBACK
    // ========================================================================

    /// @notice Called by NativeOracle when a blockchain event is recorded
    /// @dev Parses the portal message payload and delegates to _handlePortalMessage()
    /// @param sourceType The source type from NativeOracle (should be BLOCKCHAIN = 0)
    /// @param sourceId The source identifier (chain ID)
    /// @param oracleNonce The oracle nonce for this record
    /// @param payload The event payload encoded via PortalMessage: sender (20B) + nonce (16B) + message
    /// @return shouldStore Returns the value from _handlePortalMessage (derived contract decides)
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        bytes calldata payload
    ) external override returns (bool shouldStore) {
        // Only NativeOracle can call this
        if (msg.sender != SystemAddresses.NATIVE_ORACLE) {
            revert OnlyNativeOracle();
        }

        // Decode portal message payload: (sender, messageNonce, message)
        (address sender, uint128 messageNonce, bytes memory message) = PortalMessage.decode(payload);

        // Delegate to derived contract - it decides whether to store
        return _handlePortalMessage(sourceType, sourceId, oracleNonce, sender, messageNonce, message);
    }

    // ========================================================================
    // ABSTRACT FUNCTIONS
    // ========================================================================

    /// @notice Handle a parsed portal message
    /// @dev Override this in derived contracts to implement message handling logic
    /// @param sourceType The source type from NativeOracle
    /// @param sourceId The source identifier (chain ID)
    /// @param oracleNonce The oracle nonce for this record
    /// @param sender The sender address on the source chain (from portal message)
    /// @param messageNonce The message nonce from the source chain (from portal message)
    /// @param message The message body (application-specific encoding)
    /// @return shouldStore Whether NativeOracle should store this payload
    function _handlePortalMessage(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) internal virtual returns (bool shouldStore);
}

