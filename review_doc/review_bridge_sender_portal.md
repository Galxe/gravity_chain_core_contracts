# review_bridge_sender_portal

- **Agent**: ground_reviewer
- **Status**: success
- **Duration**: 54873ms
- **Steps**: 1

## Report

## Ground Review (Blue Team) — Ethereum-side Bridge Contracts

---

### Critical

**None found.**

---

### Warning

#### W-01: Permit front-running griefing in `bridgeToGravityWithPermit` (GBridgeSender.sol:81)

**Severity: Warning**

The `permit()` call can be front-run by an attacker who extracts the permit signature from the mempool and calls `permit()` directly on the token contract. When the user's `bridgeToGravityWithPermit` transaction executes, the `permit()` call reverts (nonce already consumed), causing the entire bridge transaction to fail — even though the allowance was already set.

**Mitigation:** Wrap the `permit()` call in a try/catch. If it reverts, fall through to `_bridgeToGravity` which will use the existing allowance set by the front-runner's `permit()` call.

---

#### W-02: Refund to `msg.sender` via low-level call can be griefed (GravityPortal.sol:78-79)

**Severity: Warning**

`GravityPortal.send()` refunds excess ETH via `msg.sender.call{value: refundAmount}("")`. Since `msg.sender` here is `GBridgeSender`, and `GBridgeSender` does **not** have a `receive()` or `fallback()` function, refunds from the portal back to GBridgeSender will revert with `RefundFailed()`.

This means users **must** send the exact fee amount when calling `bridgeToGravity`, otherwise the transaction reverts. This is fragile — if `baseFee` or `feePerByte` changes between the user's fee estimation and transaction execution, it will revert.

**Mitigation:** Add a `receive() external payable {}` to `GBridgeSender`, or document that exact fees are required. Alternatively, consider having GBridgeSender query the exact fee and forward only that amount.

---

#### W-03: No upper bound on `baseFee` / `feePerByte` (GravityPortal.sol:92-105)

**Severity: Warning**

Owner can set arbitrarily high fees, effectively DoS-ing the bridge. While `Ownable2Step` mitigates accidental key compromise, there is no sanity-check ceiling. This is a centralization risk.

**Mitigation:** Consider adding maximum fee caps as constants.

---

#### W-04: `emergencyWithdraw` allows partial withdrawal but marks `emergencyUsed = true` (GBridgeSender.sol:128-140)

**Severity: Warning**

The emergency withdrawal is one-shot. If the owner specifies an `amount` less than the full balance, the remaining locked tokens are permanently stuck — `emergencyUsed` is set to `true` and `initiateEmergencyWithdraw` can never be called again.

**Mitigation:** Either enforce withdrawing the full balance (`IERC20(gToken).balanceOf(address(this))`), or allow multiple withdrawals within a single emergency session before the flag is set.

---

### Info

#### I-01: `calculateBridgeFee` allocates memory unnecessarily (GBridgeSender.sol:147-154)

**Severity: Info**

`calculateBridgeFee` creates a `bytes memory message = abi.encode(amount, recipient)` just to get its `.length` (always 64 bytes). This wastes gas on memory allocation in a view function.

**Mitigation:** Replace with `return IGravityPortal(gravityPortal).calculateFee(64);` — the ABI encoding of two 32-byte words is always 64 bytes.

---

#### I-02: Assembly memory write overlap in `encode` is safe but fragile (PortalMessage.sol:61-65)

**Severity: Info**

The `mstore` at offset 0 writes 32 bytes (20 bytes sender + 12 bytes zero padding into nonce territory). The subsequent `mstore` at offset 20 overwrites those 12 bytes with the nonce. This is intentional and correct, but relies on careful ordering — the nonce write **must** come after the sender write. A comment noting this dependency would improve maintainability.

---

#### I-03: `nonce` comment says "next message will use this nonce" (IGravityPortal.sol:110)

**Severity: Info**

The `nonce()` getter comment says "next message will use this nonce", but since `send()` uses pre-increment (`++nonce`), the next message will actually use `nonce + 1`. The returned value is the **last used** nonce, not the next one.

---

#### I-04: `withdrawFees` sends entire balance (GravityPortal.sol:120-131)

**Severity: Info**

`withdrawFees` sends `address(this).balance` to `feeRecipient`. If any ETH is sent to the contract outside of `send()` (e.g., via `selfdestruct` from another contract), it would be swept along with legitimate fees. This is not a security issue but worth noting.

---

#### I-05: No event emitted on `initiateEmergencyWithdraw` cancellation path (GBridgeSender.sol:118-122)

**Severity: Info**

If the owner calls `initiateEmergencyWithdraw()` again before the timelock expires, the `emergencyUnlockTime` is silently reset to a new 7-day window. There is no explicit cancel mechanism and no event distinguishing a re-initiation from an initial one.

---

### Summary

| Severity | Count | Key Concerns |
|----------|-------|-------------|
| Critical | 0 | — |
| Warning | 4 | Permit front-run griefing, refund revert risk, no fee caps, partial emergency withdrawal trap |
| Info | 5 | Minor gas waste, assembly fragility, misleading comment, balance sweep, silent re-initiation |

Overall the code is well-structured with clean separation of concerns, proper use of `SafeERC20`, `Ownable2Step`, CEI pattern, and custom errors. The assembly in `PortalMessage` is correct and well-documented. The most actionable items are **W-01** (permit try/catch) and **W-02** (GBridgeSender lacks `receive()`).

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | ## Ground Review (Blue Team) — Ethereum-side Bridge Contract | 54873ms |
