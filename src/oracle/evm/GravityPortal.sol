// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IGravityPortal } from "./IGravityPortal.sol";
import { PortalMessage } from "./PortalMessage.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";

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
///        - Fee ceilings: `setBaseFee` / `setFeePerByte` and the constructor revert
///          above MAX_BASE_FEE / MAX_FEE_PER_BYTE (M-2).
///        - Explicit fee accounting: `accumulatedFees` tracks fees taken by `send()`;
///          `withdrawFees` draws only from that ledger, not from arbitrary contract
///          balance (I-3).
contract GravityPortal is IGravityPortal, Ownable2Step, Pausable {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Hard ceiling on `baseFee`. The constructor and `setBaseFee` revert above this.
    /// @dev A defense-in-depth bound against a soft-DoS via an absurd fee; far above any
    ///      sane operating value (≈ $200 at ETH = $2000).
    uint256 public constant MAX_BASE_FEE = 0.1 ether;

    /// @notice Hard ceiling on `feePerByte`. The constructor and `setFeePerByte` revert above this.
    uint256 public constant MAX_FEE_PER_BYTE = 0.001 ether;

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

    /// @notice Fees collected via `send()` that are available to withdraw.
    /// @dev Incremented by the full `msg.value` of each `send()` (overpayment between
    ///      1x–2x of the required fee is absorbed). ETH force-sent to the contract is
    ///      deliberately NOT counted and is therefore not withdrawable via `withdrawFees`.
    uint256 public accumulatedFees;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the GravityPortal
    /// @param initialOwner The initial owner address
    /// @param initialBaseFee The initial base fee in wei (must be <= MAX_BASE_FEE)
    /// @param initialFeePerByte The initial fee per byte in wei (must be <= MAX_FEE_PER_BYTE)
    /// @param initialFeeRecipient The initial fee recipient address
    constructor(
        address initialOwner,
        uint256 initialBaseFee,
        uint256 initialFeePerByte,
        address initialFeeRecipient
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialBaseFee > MAX_BASE_FEE) revert FeeExceedsMaximum(initialBaseFee, MAX_BASE_FEE);
        if (initialFeePerByte > MAX_FEE_PER_BYTE) revert FeeExceedsMaximum(initialFeePerByte, MAX_FEE_PER_BYTE);

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

        // The whole msg.value is kept as fee; record it in the explicit ledger.
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
        if (newBaseFee > MAX_BASE_FEE) revert FeeExceedsMaximum(newBaseFee, MAX_BASE_FEE);
        baseFee = newBaseFee;
        emit FeeConfigUpdated(newBaseFee, feePerByte);
    }

    /// @inheritdoc IGravityPortal
    function setFeePerByte(
        uint256 newFeePerByte
    ) external onlyOwner {
        if (newFeePerByte > MAX_FEE_PER_BYTE) revert FeeExceedsMaximum(newFeePerByte, MAX_FEE_PER_BYTE);
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
        _withdrawFees(accumulatedFees);
    }

    /// @inheritdoc IGravityPortal
    function withdrawFees(
        uint256 amount
    ) external onlyOwner {
        _withdrawFees(amount);
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

    /// @notice Withdraw `amount` of accumulated fees to the fee recipient
    /// @dev Effects-before-interactions: the ledger is decremented before the transfer.
    /// @param amount The amount to withdraw
    function _withdrawFees(
        uint256 amount
    ) internal {
        if (amount == 0) revert NoFeesToWithdraw();

        uint256 available = accumulatedFees;
        if (amount > available) revert InsufficientAccumulatedFees(amount, available);

        accumulatedFees = available - amount;
        address recipient = feeRecipient;

        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert TransferFailed();

        emit FeesWithdrawn(recipient, amount);
    }
}
