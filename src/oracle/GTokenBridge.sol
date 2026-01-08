// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGTokenBridge } from "./IGTokenBridge.sol";
import { IGravityPortal } from "./IGravityPortal.sol";

/// @title IERC20
/// @notice Minimal ERC20 interface for token transfers
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title GTokenBridge
/// @author Gravity Team
/// @notice Locks G tokens on Ethereum and bridges to Gravity via GravityPortal
/// @dev Deployed on Ethereum (or other EVM chains). NOT deployed on Gravity.
///      Works with NativeTokenMinter on Gravity to mint native G tokens.
contract GTokenBridge is IGTokenBridge {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice The G token contract (ERC20)
    address public immutable gToken;

    /// @notice The GravityPortal contract
    address public immutable gravityPortal;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the GTokenBridge
    /// @param gToken_ The G token (ERC20) contract address
    /// @param gravityPortal_ The GravityPortal contract address
    constructor(address gToken_, address gravityPortal_) {
        if (gToken_ == address(0) || gravityPortal_ == address(0)) {
            revert ZeroRecipient(); // Reusing error for zero address
        }

        gToken = gToken_;
        gravityPortal = gravityPortal_;
    }

    // ========================================================================
    // BRIDGE FUNCTION
    // ========================================================================

    /// @inheritdoc IGTokenBridge
    function bridgeToGravity(uint256 amount, address recipient) external payable returns (uint256 messageNonce) {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroRecipient();

        // Transfer G tokens from sender to this contract (lock)
        bool success = IERC20(gToken).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        // Encode bridge message: (amount, recipient)
        bytes memory message = abi.encode(amount, recipient);

        // Send message through GravityPortal (forwards ETH for fee)
        messageNonce = IGravityPortal(gravityPortal).sendMessage{ value: msg.value }(message);

        emit TokensLocked(msg.sender, recipient, amount, messageNonce);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGTokenBridge
    function calculateBridgeFee(uint256 amount, address recipient) external view returns (uint256 requiredFee) {
        // Calculate message length for fee estimation
        bytes memory message = abi.encode(amount, recipient);
        return IGravityPortal(gravityPortal).calculateFee(message.length);
    }
}

