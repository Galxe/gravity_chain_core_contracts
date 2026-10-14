// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGBridgeReceiver, INativeMintPrecompile } from "./IGBridgeReceiver.sol";
import { BlockchainEventHandler } from "../BlockchainEventHandler.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { Errors } from "@src/foundation/Errors.sol";

/// @title GBridgeReceiver
/// @author Gravity Team
/// @notice Mints native G tokens when bridge messages are received from GBridgeSender
/// @dev Deployed on Gravity only. Inherits BlockchainEventHandler to receive oracle callbacks.
///      Uses a system precompile to mint native tokens. Portal is public, but this receiver only
///      processes messages authenticated as coming from trustedBridge on trustedSourceId.
///      InvalidSender rejects an untrusted address before decoding amounts or invoking mint.
///      NativeOracle isolates blockchain callback failures and still advances the source nonce,
///      so this rejection cannot hold up later deposits. A failed callback never means a mint succeeded.
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

    // @deprecated Kept for storage layout compatibility after hardfork.
    // Initial delivery is protected by NativeOracle's sequential nonce enforcement. Deferred
    // retries require an original-payload commitment and are deleted on successful execution.
    uint256 private __deprecated_processedNonces;

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
        if (trustedBridge_ == address(0)) revert Errors.ZeroAddress();
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
    /// @return shouldStore Legacy ABI flag, always true after mint; it no longer controls Oracle storage
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

        // Portal.send is intentionally permissionless. Reject untrusted source addresses here;
        // the Oracle records this InvalidSender error without blocking its shared nonce stream.
        // Retrying this rejected payload will still fail unless the trusted receiver itself changes.
        if (sender != trustedBridge) {
            revert InvalidSender(sender, trustedBridge);
        }

        // Replay protection is handled by NativeOracle's sequential nonce enforcement
        // for initial delivery. Its separate pending-only retry cannot replay a successful mint.

        // Decode message: (amount, recipient)
        (uint256 amount, address recipient) = abi.decode(message, (uint256, address));

        // Validate decoded data to prevent no-op mints and burns to address(0)
        if (amount == 0) revert Errors.ZeroAmount();
        if (recipient == address(0)) revert Errors.ZeroAddress();

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
}
