// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeTokenMinter, INativeMintPrecompile } from "./INativeTokenMinter.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { requireAllowed } from "@src/foundation/SystemAccessControl.sol";
import { Errors } from "@src/foundation/Errors.sol";

/// @title NativeTokenMinter
/// @author Gravity Team
/// @notice Mints native G tokens when bridge messages are received from GTokenBridge
/// @dev Deployed on Gravity only. Implements IMessageHandler for BlockchainEventRouter.
///      Uses a system precompile to mint native tokens.
contract NativeTokenMinter is INativeTokenMinter {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Address of the native mint precompile
    /// @dev This precompile is only callable by authorized system contracts
    address public constant NATIVE_MINT_PRECOMPILE = address(0x0000000000000000000000000001625F2100);

    // ========================================================================
    // IMMUTABLES
    // ========================================================================

    /// @notice Trusted GTokenBridge address on Ethereum
    /// @dev Only messages from this sender are processed
    address public immutable trustedBridge;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Processed nonces for replay protection
    mapping(uint256 => bool) private _processedNonces;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the NativeTokenMinter
    /// @param trustedBridge_ The trusted GTokenBridge address on Ethereum
    constructor(address trustedBridge_) {
        trustedBridge = trustedBridge_;
    }

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @inheritdoc INativeTokenMinter
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
            revert MinterNotInitialized();
        }
        _;
    }

    // ========================================================================
    // MESSAGE HANDLER
    // ========================================================================

    /// @notice Handle a routed message from BlockchainEventRouter
    /// @dev Only callable by BlockchainEventRouter
    /// @param sourceType The source type from NativeOracle
    /// @param sourceId The source identifier (chain ID)
    /// @param oracleNonce The oracle nonce for this record
    /// @param sender The sender address on Ethereum (must be trusted bridge)
    /// @param eventNonce The message nonce from the source chain
    /// @param message The message body: abi.encode(amount, recipient)
    function handleMessage(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        address sender,
        uint256 eventNonce,
        bytes calldata message
    ) external whenInitialized {
        // Silence unused variable warnings - these are for future extensibility
        (sourceType, sourceId, oracleNonce);

        // Only BlockchainEventRouter can call this
        if (msg.sender != SystemAddresses.BLOCKCHAIN_EVENT_ROUTER) {
            revert OnlyRouter();
        }

        // Verify sender is the trusted bridge (defense in depth)
        if (sender != trustedBridge) {
            emit MintFailed(eventNonce, abi.encodePacked("Invalid sender"));
            revert InvalidSender(sender, trustedBridge);
        }

        // Check for replay
        if (_processedNonces[eventNonce]) {
            emit MintFailed(eventNonce, abi.encodePacked("Already processed"));
            revert AlreadyProcessed(eventNonce);
        }

        // Decode message: (amount, recipient)
        (uint256 amount, address recipient) = abi.decode(message, (uint256, address));

        // Mark nonce as processed BEFORE minting (CEI pattern)
        _processedNonces[eventNonce] = true;

        // Mint native tokens via precompile
        try INativeMintPrecompile(NATIVE_MINT_PRECOMPILE).mint(recipient, amount) {
            emit NativeMinted(recipient, amount, eventNonce);
        } catch (bytes memory reason) {
            // Revert the nonce marking if mint failed
            _processedNonces[eventNonce] = false;
            emit MintFailed(eventNonce, reason);
            revert MintPrecompileFailed();
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc INativeTokenMinter
    function isProcessed(uint256 nonce) external view returns (bool) {
        return _processedNonces[nonce];
    }

    /// @inheritdoc INativeTokenMinter
    function isInitialized() external view returns (bool) {
        return _initialized;
    }
}
