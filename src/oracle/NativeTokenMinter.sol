// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeTokenMinter, INativeMintPrecompile } from "./INativeTokenMinter.sol";
import { IMessageHandler } from "./IBlockchainEventRouter.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

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
    /// @param dataHash The hash of the original payload
    /// @param sender The sender address on Ethereum (must be trusted bridge)
    /// @param nonce The message nonce
    /// @param message The message body: abi.encode(amount, recipient)
    function handleMessage(
        bytes32 dataHash,
        address sender,
        uint256 nonce,
        bytes calldata message
    ) external whenInitialized {
        // Only BlockchainEventRouter can call this
        if (msg.sender != SystemAddresses.BLOCKCHAIN_EVENT_ROUTER) {
            revert OnlyRouter();
        }

        // Verify sender is the trusted bridge (defense in depth)
        if (sender != trustedBridge) {
            emit MintFailed(dataHash, nonce, abi.encodePacked("Invalid sender"));
            revert InvalidSender(sender, trustedBridge);
        }

        // Check for replay
        if (_processedNonces[nonce]) {
            emit MintFailed(dataHash, nonce, abi.encodePacked("Already processed"));
            revert AlreadyProcessed(nonce);
        }

        // Decode message: (amount, recipient)
        (uint256 amount, address recipient) = abi.decode(message, (uint256, address));

        // Mark nonce as processed BEFORE minting (CEI pattern)
        _processedNonces[nonce] = true;

        // Mint native tokens via precompile
        try INativeMintPrecompile(NATIVE_MINT_PRECOMPILE).mint(recipient, amount) {
            emit NativeMinted(recipient, amount, nonce);
        } catch (bytes memory reason) {
            // Revert the nonce marking if mint failed
            _processedNonces[nonce] = false;
            emit MintFailed(dataHash, nonce, reason);
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

