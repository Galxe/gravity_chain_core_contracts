// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGBridgeSender } from "./IGBridgeSender.sol";
import { IGravityPortal } from "../IGravityPortal.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title GBridgeSender
/// @author Gravity Team
/// @notice Locks G tokens on Ethereum and bridges to Gravity via GravityPortal
/// @dev Deployed on Ethereum (or other EVM chains). NOT deployed on Gravity.
///      Works with GBridgeReceiver on Gravity to mint native G tokens.
contract GBridgeSender is IGBridgeSender, Ownable2Step {
    using SafeERC20 for IERC20;

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

    /// @notice Deploy the GBridgeSender
    /// @param gToken_ The G token (ERC20) contract address
    /// @param gravityPortal_ The GravityPortal contract address
    /// @param owner_ The owner address for Ownable2Step
    constructor(
        address gToken_,
        address gravityPortal_,
        address owner_
    ) Ownable(owner_) {
        if (gToken_ == address(0) || gravityPortal_ == address(0)) {
            revert ZeroAddress();
        }

        gToken = gToken_;
        gravityPortal = gravityPortal_;
    }

    // ========================================================================
    // BRIDGE FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGBridgeSender
    function bridgeToGravity(
        uint256 amount,
        address recipient
    ) external payable returns (uint128 messageNonce) {
        return _bridgeToGravity(amount, recipient);
    }

    /// @inheritdoc IGBridgeSender
    function bridgeToGravityWithPermit(
        uint256 amount,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (uint128 messageNonce) {
        IERC20Permit(gToken).permit(msg.sender, address(this), amount, deadline, v, r, s);
        return _bridgeToGravity(amount, recipient);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Internal function to bridge tokens to Gravity
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity chain
    /// @return messageNonce The portal nonce assigned to this bridge operation
    function _bridgeToGravity(
        uint256 amount,
        address recipient
    ) internal returns (uint128 messageNonce) {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroRecipient();

        // Transfer G tokens from sender to this contract (lock) using SafeERC20
        IERC20(gToken).safeTransferFrom(msg.sender, address(this), amount);

        // Encode bridge message: (amount, recipient)
        bytes memory message = abi.encode(amount, recipient);

        // Send message through GravityPortal (forwards ETH for fee)
        messageNonce = IGravityPortal(gravityPortal).send{ value: msg.value }(message);

        emit TokensLocked(msg.sender, recipient, amount, messageNonce);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGBridgeSender
    function calculateBridgeFee(
        uint256 amount,
        address recipient
    ) external view returns (uint256 requiredFee) {
        // Calculate message length for fee estimation
        bytes memory message = abi.encode(amount, recipient);
        return IGravityPortal(gravityPortal).calculateFee(message.length);
    }
}

