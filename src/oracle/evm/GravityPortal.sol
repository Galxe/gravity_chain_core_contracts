// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGravityPortal } from "./IGravityPortal.sol";
import { PortalMessage } from "./PortalMessage.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title GravityPortal
/// @author Gravity Team
/// @notice Entry point on Ethereum for sending messages to Gravity chain
/// @dev Deployed on Ethereum (or other EVM chains). NOT deployed on Gravity.
///      Charges fees in native token (ETH) for message bridging.
///      Consensus engine monitors MessageSent events and bridges to Gravity.
///      Uses compact encoding via PortalMessage library: sender (20B) + nonce (16B) + message.
///
///      Hardening (see ETH-CONTRACTS-AUDIT-AND-DEPLOY-GUIDE.md §4):
///        - Pausable: the owner can halt `send()` as a circuit breaker (M-1).
///        - `accumulatedFees`: an increase-only counter of fees ever taken by `send()`,
///          kept purely for off-chain accounting / observability (I-3).
///        - `withdrawFees` sweeps the contract's ETH balance (so nothing gets stuck);
///          `recoverERC20` rescues ERC-20s accidentally sent to the contract.
contract GravityPortal is IGravityPortal, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Base fee for any bridge operation (in wei)
    uint256 public baseFee;

    /// @notice Fee per byte of payload (in wei)
    uint256 public feePerByte;

    /// @notice Address receiving collected fees
    address public feeRecipient;

    /// @notice Monotonically increasing nonce for message ordering
    uint128 public nonce;

    /// @notice Lifetime cumulative total of fees taken by `send()` (in wei).
    /// @dev Increase-only — incremented by the full `msg.value` of every `send()` and
    ///      never decremented. It is a record/observability counter, NOT a withdrawable
    ///      balance: `withdrawFees` operates on `address(this).balance`, not on this value.
    uint256 public accumulatedFees;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the GravityPortal
    /// @param initialOwner The initial owner address
    /// @param initialBaseFee The initial base fee in wei
    /// @param initialFeePerByte The initial fee per byte in wei
    /// @param initialFeeRecipient The initial fee recipient address
    constructor(
        address initialOwner,
        uint256 initialBaseFee,
        uint256 initialFeePerByte,
        address initialFeeRecipient
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();

        baseFee = initialBaseFee;
        feePerByte = initialFeePerByte;
        feeRecipient = initialFeeRecipient;
    }

    // ========================================================================
    // MESSAGE BRIDGING
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function send(
        bytes calldata message
    ) external payable whenNotPaused returns (uint128 messageNonce) {
        // Assign nonce and increment
        messageNonce = ++nonce;

        // Encode payload: sender (20B) || nonce (16B) || message
        bytes memory payload = PortalMessage.encodeCalldata(msg.sender, messageNonce, message);

        // Calculate and validate fee based on payload length
        uint256 requiredFee = _calculateFee(payload.length);
        if (msg.value < requiredFee) {
            revert InsufficientFee(requiredFee, msg.value);
        }

        // Revert if overpayment is excessive (more than 2x required fee)
        // Small overpayments are absorbed as additional fees
        if (msg.value > 2 * requiredFee) {
            revert ExcessiveFee(requiredFee, msg.value);
        }

        // The whole msg.value is kept as fee; record it in the cumulative counter.
        accumulatedFees += msg.value;

        // Emit event for consensus engine to monitor
        // Nonce is extracted as indexed param for efficient consensus filtering
        emit MessageSent(messageNonce, block.number, payload);
    }

    // ========================================================================
    // FEE MANAGEMENT (Owner Only)
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function setBaseFee(
        uint256 newBaseFee
    ) external onlyOwner {
        baseFee = newBaseFee;
        emit FeeConfigUpdated(newBaseFee, feePerByte);
    }

    /// @inheritdoc IGravityPortal
    function setFeePerByte(
        uint256 newFeePerByte
    ) external onlyOwner {
        feePerByte = newFeePerByte;
        emit FeeConfigUpdated(baseFee, newFeePerByte);
    }

    /// @inheritdoc IGravityPortal
    function setFeeRecipient(
        address newRecipient
    ) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /// @inheritdoc IGravityPortal
    function withdrawFees() external onlyOwner {
        _withdrawFees(address(this).balance);
    }

    /// @inheritdoc IGravityPortal
    function withdrawFees(
        uint256 amount
    ) external onlyOwner {
        _withdrawFees(amount);
    }

    /// @inheritdoc IGravityPortal
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(recipient, amount);

        emit ERC20Recovered(token, recipient, amount);
    }

    // ========================================================================
    // PAUSE (Owner Only)
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IGravityPortal
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IGravityPortal
    function calculateFee(
        uint256 messageLength
    ) external view returns (uint256 requiredFee) {
        // Estimate encoded payload length using compact encoding:
        // sender (20 bytes) + nonce (16 bytes) + message length = 36 + messageLength
        uint256 estimatedPayloadLength = PortalMessage.MIN_PAYLOAD_LENGTH + messageLength;
        return _calculateFee(estimatedPayloadLength);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Calculate fee for a given payload length
    /// @param payloadLength The length of the encoded payload in bytes
    /// @return The required fee in wei
    function _calculateFee(
        uint256 payloadLength
    ) internal view returns (uint256) {
        return baseFee + (payloadLength * feePerByte);
    }

    /// @notice Withdraw `amount` of ETH from the contract balance to the fee recipient
    /// @dev Sweeps from `address(this).balance` so any ETH (fees + anything force-sent)
    ///      can always be recovered — nothing gets permanently stuck.
    /// @param amount The amount to withdraw (must be > 0 and <= the contract balance)
    function _withdrawFees(
        uint256 amount
    ) internal {
        if (amount == 0) revert NoFeesToWithdraw();

        uint256 balance = address(this).balance;
        if (amount > balance) revert InsufficientBalance(amount, balance);

        address recipient = feeRecipient;

        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert TransferFailed();

        emit FeesWithdrawn(recipient, amount);
    }
}
