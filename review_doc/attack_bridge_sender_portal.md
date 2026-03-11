# attack_bridge_sender_portal

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 113815ms
- **Steps**: 1

## Report

# Red Team Audit: Bridge Contracts (GBridgeSender, GravityPortal, PortalMessage, GBridgeReceiver)

---

## Finding 1: GBridgeSender Cannot Receive ETH Refunds — Overpayment Causes Transaction Revert

**Severity: High**

**Location:** `GBridgeSender.sol:107` + `GravityPortal.sol:76-79`

**Description:**  
`GBridgeSender` forwards the user's entire `msg.value` to `GravityPortal.send()`. If the user sends even 1 wei more than the exact required fee, the portal attempts to refund the excess to `msg.sender` — which is `GBridgeSender`:

```solidity
// GravityPortal.sol:78
(bool success,) = msg.sender.call{ value: refundAmount }("");
if (!success) revert RefundFailed();
```

**However, `GBridgeSender` has no `receive()` or `fallback()` function.** The refund call will always fail, causing the entire bridge transaction to revert with `RefundFailed()`.

**Impact:**  
- Users **must** send the **exact** fee amount — any overpayment reverts the transaction.
- Between calling `calculateBridgeFee()` and transaction execution, the owner can change `baseFee` or `feePerByte`, making the pre-calculated fee stale.
- This violates the standard UX pattern where users overpay and receive a refund, creating a race condition between fee estimation and execution.
- Front-end integrations that add a small buffer to fees (common practice) will **always fail**.

**Recommendation:** Add a `receive() external payable {}` to `GBridgeSender`, and implement a mechanism to refund excess ETH back to the original user (`msg.sender` of `bridgeToGravity`). Or alternatively, query the exact fee on-chain within `_bridgeToGravity` and forward only the required amount.

---

## Finding 2: Emergency Withdrawal One-Shot Design Permanently Locks Remaining Tokens

**Severity: Medium**

**Location:** `GBridgeSender.sol:128-140`

**Description:**  
`emergencyWithdraw` sets `emergencyUsed = true` regardless of the `amount` withdrawn:

```solidity
emergencyUnlockTime = 0;
emergencyUsed = true;  // Permanently disables emergency path
IERC20(gToken).safeTransfer(recipient, amount);
```

If the owner withdraws only a partial amount (e.g., to rescue a specific user's tokens), **all remaining locked tokens become permanently unrecoverable** through the emergency mechanism. The `initiateEmergencyWithdraw()` check `if (emergencyUsed) revert EmergencyAlreadyUsed()` prevents any future emergency withdrawals.

**Impact:** In a scenario where the bridge is compromised or permanently broken, the owner gets exactly one chance to withdraw the correct amount. A mistake in the `amount` parameter permanently locks the remaining tokens with no recovery path.

**Recommendation:** Either remove the one-shot restriction and allow multiple emergency withdrawals (with the timelock reset each time), or force `amount` to be the full token balance.

---

## Finding 3: No Cancellation Mechanism for Emergency Withdrawal Initiation

**Severity: Medium**

**Location:** `GBridgeSender.sol:118-122`

**Description:**  
Once `initiateEmergencyWithdraw()` is called, there is no way to cancel the pending timelock. The `emergencyUnlockTime` remains set indefinitely. If the initiation was accidental, or if the crisis resolves during the 7-day window, the owner has no option to abort.

The only way to "cancel" is to execute `emergencyWithdraw(addr, 0)` after the timelock, which permanently burns the one-shot mechanism (`emergencyUsed = true`) while transferring nothing — a destructive workaround that eliminates the safety net for future genuine emergencies.

**Recommendation:** Add a `cancelEmergencyWithdraw()` function that resets `emergencyUnlockTime = 0` without setting `emergencyUsed`.

---

## Finding 4: Permit Front-Running Denial of Service on `bridgeToGravityWithPermit`

**Severity: Medium**

**Location:** `GBridgeSender.sol:73-83`

**Description:**  
The `bridgeToGravityWithPermit` function calls `permit()` before transferring tokens:

```solidity
IERC20Permit(gToken).permit(msg.sender, address(this), amount, deadline, v, r, s);
return _bridgeToGravity(amount, recipient);
```

An attacker who observes the pending transaction in the mempool can extract the permit signature and front-run by calling `gToken.permit()` directly. This consumes the permit nonce, causing the victim's transaction to revert on the `permit()` call.

While the allowance IS set by the front-runner's call (so the user could retry with `bridgeToGravity` instead), this creates a griefing vector that forces users to submit a second transaction, wasting gas and degrading UX.

**Recommendation:** Wrap the `permit()` call in a try-catch. If it reverts, fall through to `_bridgeToGravity` anyway — the allowance may already be set from the front-runner's call or from a prior `approve`.

---

## Finding 5: GravityPortal Fee Parameters Have No Upper Bound — Owner Can DoS the Bridge

**Severity: Medium**

**Location:** `GravityPortal.sol:92-105`

**Description:**  
`setBaseFee` and `setFeePerByte` accept arbitrary `uint256` values with no sanity checks or upper bounds. A compromised owner key (or malicious owner) can set fees to `type(uint256).max`, effectively making the bridge unusable since no user could provide enough ETH to cover the fee.

```solidity
function setBaseFee(uint256 newBaseFee) external onlyOwner {
    baseFee = newBaseFee;  // No upper bound check
}
```

Combined with Finding 1 (no refund on overpayment), fee changes between estimation and execution can also cause legitimate user transactions to revert unexpectedly if the fee increases.

**Recommendation:** Implement reasonable maximum fee bounds (e.g., a cap) and/or a timelock on fee parameter changes to give users time to react.

---

## Summary

| # | Finding | Severity | Category |
|---|---------|----------|----------|
| 1 | GBridgeSender cannot receive ETH refunds — overpayment reverts bridge | **High** | Missing receive function / DoS |
| 2 | One-shot emergency can permanently lock remaining tokens | **Medium** | Business logic flaw |
| 3 | No cancellation for emergency withdrawal initiation | **Medium** | Missing functionality |
| 4 | Permit front-running DoS on `bridgeToGravityWithPermit` | **Medium** | Griefing / known ERC20Permit issue |
| 5 | Unbounded fee parameters enable owner-driven bridge DoS | **Medium** | Access control / parameter validation |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | # Red Team Audit: Bridge Contracts (GBridgeSender, GravityPo | 113815ms |
