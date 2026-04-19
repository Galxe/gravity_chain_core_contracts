# Oracle/EVM Bridge — Security & Edge-Case Specification

Companion to [`oracle_evm_bridge.spec.md`](./oracle_evm_bridge.spec.md). That
document describes **what the contracts do**; this one enumerates the
**properties they must uphold** and the **adversarial scenarios they must
survive**. Every numbered item below has a matching test in
`test/e2e/SecuritySpec.t.sol`.

IDs:

- **I-N** — invariants that must hold for every reachable state.
- **S-N** — specific scenarios (attacks, edge cases) and their required
  outcomes.

---

## Scope & trust model

**In scope:**

- `GravityPortal` (Ethereum)
- `GBridgeSender` (Ethereum)
- `GBridgeReceiver` (Gravity)
- `PortalMessage` library

**Out of scope (assumed correct):**

- `NativeOracle` replay protection (sequential per-source nonce).
- The consensus engine's event capture on Ethereum.
- The `NATIVE_MINT_PRECOMPILE` in grevm.
- The G ERC-20 token on Ethereum (`0x9C7B…0649`).

**Trusted parties:**

- Portal / Sender **owner EOA** — can withdraw fees, change fee params,
  rotate the fee recipient, and (crucially) pull locked G tokens out of
  the Sender via `emergencyWithdraw` / `recoverERC20`. This is a
  deliberate custodial-bridge posture; see §Centralization.
- Gravity consensus — only `SystemAddresses.NATIVE_ORACLE` is authorized
  to invoke `GBridgeReceiver.onOracleEvent`.

---

## Invariants

### I-1 Conservation (non-rebasing token)

For any sequence of successfully delivered bridges over a non-rebasing,
non-fee-on-transfer ERC-20:

```
sum(actualReceived in TokensLocked events)
    == IERC20(gToken).balanceOf(address(sender))
    == sum(amount minted on Gravity by NATIVE_MINT_PRECOMPILE)
```

for bridges where the owner has not invoked `emergencyWithdraw` /
`recoverERC20`.

### I-2 Fee-on-transfer safety

If the G token takes a fee on transfer, the Sender must encode into the
message the **amount it actually received**, not the nominal amount
requested. A user never receives more on Gravity than was actually locked.

### I-3 Nonce monotonicity

`GravityPortal.nonce` is strictly increasing, starts at 0, and advances by
exactly 1 per successful `send`. Two successful `send` calls never share
the same `messageNonce`.

### I-4 Trust boundary

`GBridgeReceiver` mints **iff**

```
sourceId == trustedSourceId
AND decoded payload sender == trustedBridge
AND msg.sender == NATIVE_ORACLE
```

If any of the three fails, no mint occurs and the call reverts.

### I-5 Payload integrity

For any `(sender, nonce, message)` triple encoded by `PortalMessage`,
decoding the result returns the same triple bit-for-bit. Under-length
payloads (< 36 B) revert with `InsufficientDataLength`.

### I-6 No stuck ETH

Neither `GravityPortal` nor `GBridgeSender` accepts ETH outside of the
bridge flow. Attempts to transfer ETH to them via `address.call{value:…}("")`
or a bare transfer fail (no `receive`/`fallback` payable handler).

### I-7 Atomic Ethereum-side step

The Ethereum-side operation (`transferFrom` + `portal.send`) is atomic:
either the tokens are locked **and** the event is emitted, or neither
happens. A revert at any point leaves the user's balance and the portal's
nonce unchanged.

### I-8 Exact fee envelope

A user's `msg.value` is accepted **iff** `required ≤ msg.value ≤ 2 ×
required`. Otherwise the call reverts. Within that envelope no refund is
issued — the Portal retains the entire `msg.value`.

### I-9 Replay protection is oracle-side, not receiver-side

`GBridgeReceiver` does **not** enforce nonce uniqueness itself; it depends
on `NativeOracle`'s sequential-nonce rule. If a payload with a reused
oracle nonce were ever delivered to `onOracleEvent`, it would mint again.
This is intentional (see `__deprecated_processedNonces`) and is a
boundary condition that spec-level tests must assert.

---

## Adversarial scenarios

### S-1 Forged payload from a random sender

An attacker calls `GravityPortal.send` directly with a body that decodes
to `(amount, victim)`. The Portal embeds `msg.sender == attacker` into
the payload. When the oracle delivers that payload, the Receiver rejects
with `InvalidSender(attacker, trustedBridge)`. No mint.

**Covered by:** existing `CrossChainBridge.t.sol::test_E2E_Receiver_RejectsForgedPayloadFromRandomSender`.
Restated here for spec completeness.

### S-2 Fee-on-transfer G token

The G token deducts a 5 % burn on every transfer. Alice bridges
`100 ether`. Sender's balance-delta detects `actualReceived == 95 ether`.
`95 ether` is encoded into the message. Receiver mints exactly
`95 ether`. Conservation (I-1, with FoT caveat) holds.

### S-3 Mid-flight fee hike

Alice calls `calculateBridgeFee(…)` and prepares a tx with the computed
`msg.value`. Before her tx is mined, the owner raises `feePerByte` via
`setFeePerByte`. Alice's tx now underpays → `InsufficientFee`. The tx
reverts **atomically**: Alice's tokens are not debited, the Portal's
nonce is unchanged.

### S-4 Reentrant `withdrawFees`

Owner calls `withdrawFees`. `feeRecipient` is an attacker contract whose
`receive()` re-enters `GravityPortal.send` (or any other Portal function)
during the ETH transfer. Assert: no state corruption — each reentrant
`send` requires its own `msg.value`, and the already-transferred balance
cannot be double-spent. `nonce` advances coherently; no extra funds
leave.

### S-5 Permit front-run griefing

Alice publishes a permit signature and plans to call
`bridgeToGravityWithPermit`. An attacker front-runs by calling
`G.permit(alice, sender, amount, …)` directly on the token, consuming
Alice's permit nonce. Alice's bridge tx then reverts because the permit
is already spent. Assert: Alice's tokens are **untouched**; she can
sign a new permit and retry.

### S-6 Owner drains locked tokens (documented centralization)

The Sender owner calls `recoverERC20(gToken, attackerEOA, balance)` and
pulls all locked G tokens out. This is a **documented capability**, not
a bug. Users must understand that the bridge is custodial with respect
to the owner EOA. The test asserts the call succeeds and that the
Sender's balance drops to zero — so that any future change that silently
blocks this path is caught and forces an explicit architectural
decision.

### S-7 Non-owner cannot drain

Same call, but `msg.sender != owner` → reverts with
`OwnableUnauthorizedAccount`. Applies to all `onlyOwner` paths
(`setBaseFee`, `setFeePerByte`, `setFeeRecipient`, `withdrawFees`,
`emergencyWithdraw`, `recoverERC20`).

### S-8 Overpayment within the 2× envelope is absorbed

Alice sends `msg.value = 1.5 × required`. Tx succeeds; Portal retains
the full `msg.value`. Alice does not get a refund. Test pins this so
that a future "refund overpayment" change is a conscious break.

### S-9 Raw ETH to Portal / Sender

`address(portal).call{value: 1 ether}("")` and the same to `sender` —
both fail. The `send(bytes)` entry point is the **only** way ETH enters
the Portal. Sender never accepts ETH for non-bridge purposes.

### S-10 Under-length payload to Receiver

Oracle delivers a 10-byte payload. `PortalMessage.decode` reverts with
`InsufficientDataLength`. No mint, no partial state change.

### S-11 Malformed message body (correct payload wrapper)

Oracle delivers a payload whose body is not `abi.encode(uint256,
address)` — e.g., 31 arbitrary bytes. `abi.decode` in the Receiver
reverts. No mint.

### S-12 Replay at the receiver boundary (spec fence)

Document-only scenario: if `NATIVE_ORACLE`'s sequential-nonce rule were
bypassed and the same payload were delivered twice, the Receiver would
mint twice. The test constructs this artificial situation (by pranking
as `NATIVE_ORACLE` and calling `onOracleEvent` twice with the same
inputs) and asserts the **double mint happens** — pinning I-9 as a
deliberate boundary condition, so regressions introducing local replay
guards or, conversely, silently removing oracle-side guards are
detected.

### S-13 Unknown sourceType passes

The Receiver declares `sourceType` as unused. A call with e.g.
`sourceType = 42` succeeds so long as sourceId and sender match. Test
pins this — if the bridge ever gains type discrimination, this test
must be updated deliberately.

### S-14 Large body does not inflate fee unexpectedly

A user crafts a direct `portal.send` with a 10 KB body. The fee equals
`baseFee + (36 + 10 240) * feePerByte`. Test pins the formula end-to-end
so silent fee-formula changes are caught.

### S-15 Ownership transfer is two-step

Transferring Portal or Sender ownership requires both
`transferOwnership` and `acceptOwnership`. A pending transfer does not
change authority until accepted.

---

## Notes for future changes

- **If a decentralized governance replaces the single-EOA owner**,
  S-6/S-7 semantics shift and must be re-specified.
- **If the bridge extends to Gravity → Ethereum withdrawals**, a new
  conservation invariant (I-1 extended) is needed: minted-on-Ethereum
  must equal burned-on-Gravity.
- **If sourceType gains meaning** (e.g., distinguishing blockchain vs
  JWK sources), S-13 is invalidated and the Receiver must gate on it.
- **If per-receiver replay protection is re-enabled**, S-12 is
  invalidated; the `__deprecated_processedNonces` slot should be
  re-used, not a new slot, to preserve storage layout.
