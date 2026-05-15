// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGBridgeSender } from "./IGBridgeSender.sol";
import { IGravityPortal } from "../IGravityPortal.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title GBridgeSender
/// @author Gravity Team
/// @notice Locks G tokens on Ethereum and bridges to Gravity via GravityPortal
/// @dev Deployed on Ethereum (or other EVM chains). NOT deployed on Gravity.
///      Works with GBridgeReceiver on Gravity to mint native G tokens.
///
///      Hardening (see ETH-CONTRACTS-AUDIT-AND-DEPLOY-GUIDE.md §3-4):
///        - Pausable: the owner can halt new bridge deposits as a circuit breaker (M-1).
///        - Emergency withdrawal of locked G is gated by a 7-day timelock: the owner
///          requests, waits TIMELOCK_DELAY, then executes — unless cancelled. Only one
///          request may be in flight at a time (C-1).
///        - `recoverERC20` cannot move the G token; G can only leave via the timelocked
///          emergency path (I-1).
contract GBridgeSender is IGBridgeSender, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Delay between requesting and executing an emergency withdrawal
    uint256 public constant TIMELOCK_DELAY = 7 days;

    // ========================================================================
    // IMMUTABLE STATE
    // ========================================================================

    /// @notice The G token contract (ERC20)
    address public immutable gToken;

    /// @notice The GravityPortal contract
    address public immutable gravityPortal;

    // ========================================================================
    // EMERGENCY WITHDRAW TIMELOCK STATE
    // ========================================================================

    /// @notice Recipient of the single in-flight emergency withdrawal request
    address public pendingWithdrawRecipient;

    /// @notice Amount of the single in-flight emergency withdrawal request
    uint256 public pendingWithdrawAmount;

    /// @notice Timestamp at/after which the pending request can be executed.
    /// @dev Zero means there is no request in flight — this is the canonical "pending" flag.
    uint256 public pendingWithdrawExecutableAt;

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
    ) external payable whenNotPaused returns (uint128 messageNonce) {
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
    ) external payable whenNotPaused returns (uint128 messageNonce) {
        IERC20Permit(gToken).permit(msg.sender, address(this), amount, deadline, v, r, s);
        return _bridgeToGravity(amount, recipient);
    }

    // ========================================================================
    // PAUSE (Owner Only)
    // ========================================================================

    /// @inheritdoc IGBridgeSender
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IGBridgeSender
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================================================================
    // EMERGENCY WITHDRAW — 7-DAY TIMELOCK (Owner Only)
    // ========================================================================

    /// @inheritdoc IGBridgeSender
    function requestEmergencyWithdraw(
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();
        if (pendingWithdrawExecutableAt != 0) revert WithdrawalAlreadyPending();

        uint256 executableAt = block.timestamp + TIMELOCK_DELAY;
        pendingWithdrawRecipient = recipient;
        pendingWithdrawAmount = amount;
        pendingWithdrawExecutableAt = executableAt;

        emit EmergencyWithdrawRequested(recipient, amount, executableAt);
    }

    /// @inheritdoc IGBridgeSender
    function cancelEmergencyWithdraw() external onlyOwner {
        if (pendingWithdrawExecutableAt == 0) revert NoWithdrawalPending();

        _clearPendingWithdraw();

        emit EmergencyWithdrawCancelled();
    }

    /// @inheritdoc IGBridgeSender
    function executeEmergencyWithdraw() external onlyOwner {
        uint256 executableAt = pendingWithdrawExecutableAt;
        if (executableAt == 0) revert NoWithdrawalPending();
        if (block.timestamp < executableAt) {
            revert TimelockNotElapsed(executableAt, block.timestamp);
        }

        address recipient = pendingWithdrawRecipient;
        uint256 amount = pendingWithdrawAmount;

        // Effects before interactions: clear the request before transferring.
        _clearPendingWithdraw();

        IERC20(gToken).safeTransfer(recipient, amount);

        emit EmergencyWithdraw(recipient, amount);
    }

    /// @inheritdoc IGBridgeSender
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        if (token == gToken) revert CannotRecoverGToken();
        IERC20(token).safeTransfer(recipient, amount);
        emit ERC20Recovered(token, recipient, amount);
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

        // Use balance delta pattern to handle potential fee-on-transfer tokens
        uint256 balanceBefore = IERC20(gToken).balanceOf(address(this));
        IERC20(gToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualReceived = IERC20(gToken).balanceOf(address(this)) - balanceBefore;

        // Encode bridge message with actual received amount
        bytes memory message = abi.encode(actualReceived, recipient);

        // Send message through GravityPortal (forwards ETH for fee)
        messageNonce = IGravityPortal(gravityPortal).send{ value: msg.value }(message);

        emit TokensLocked(msg.sender, recipient, actualReceived, messageNonce);
    }

    /// @notice Clear the in-flight emergency withdrawal request
    function _clearPendingWithdraw() internal {
        pendingWithdrawRecipient = address(0);
        pendingWithdrawAmount = 0;
        pendingWithdrawExecutableAt = 0;
    }
}
