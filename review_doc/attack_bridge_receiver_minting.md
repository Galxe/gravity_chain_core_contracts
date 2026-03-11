# attack_bridge_receiver_minting

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 253190ms
- **Steps**: 1

## Report

Now I have the full picture. Here's my red team analysis:

---

# Red Team Attack Report: GBridgeReceiver Bridge System

## CRITICAL Findings

### 1. Permanent Fund Loss on Callback Failure — No Recovery Path
**Severity: Critical**

**Location:** `NativeOracle.record()` → `GBridgeReceiver.onOracleEvent()` interaction

**Vulnerability:** When `NativeOracle` invokes the `onOracleEvent` callback on `GBridgeReceiver` and the callback **reverts** (e.g., insufficient `callbackGasLimit`, out-of-gas during mint precompile call), the following happens:

1. NativeOracle **catches** the revert, emits `CallbackFailed`, and **stores the data anyway**
2. The oracle nonce **advances past** this record permanently
3. `_processedNonces[messageNonce]` is **NOT set** (the state change was reverted)
4. There is **no retry mechanism** in NativeOracle to re-invoke the callback

**Result:** Tokens are locked on Ethereum (in GBridgeSender), but never minted on Gravity. The user's funds are permanently stuck. The nonce is unprocessed, but there is no code path to re-trigger processing.

**Attack scenario:**
- The consensus engine sets an insufficient `callbackGasLimit` for a record
- The callback reverts due to OOG
- NativeOracle stores the payload but the mint never executes
- No contract-level recovery exists — governance would need to deploy a bespoke recovery contract to read stored data from NativeOracle and manually mint

**Mitigation:** Add a permissioned `retryCallback(sourceType, sourceId, nonce)` function to NativeOracle, or add a governance-callable `manualMint` function to GBridgeReceiver that reads stored but unprocessed records from NativeOracle.

---

### 2. Emergency Withdrawal Is One-Shot — Insufficient for Ongoing Operations
**Severity: High**

**Location:** `GBridgeSender.sol:118-140`

**Vulnerability:** `emergencyWithdraw` sets `emergencyUsed = true` on first use (line 137), permanently disabling both future emergency withdrawals AND re-initiation (line 119: `if (emergencyUsed) revert EmergencyAlreadyUsed()`). However:

1. After emergency withdrawal, **normal bridge operations continue to accept deposits** — users can still call `bridgeToGravity()` and lock tokens
2. If the bridge system is still broken (the reason emergency was triggered), newly locked tokens are also stuck
3. No second emergency withdrawal is possible, ever

**Attack scenario:**
- Bridge breaks, owner emergency-withdraws stuck funds
- Bridge appears fixed, users resume bridging
- Bridge breaks again — no emergency recovery available

**Mitigation:** Either (a) add a `pause()` mechanism that prevents new deposits when emergency is active, or (b) allow multiple emergency withdrawals with separate timelocks.

---

## HIGH Findings

### 3. `sourceType` Not Validated — Trusts Callback Registration Entirely
**Severity: High**

**Location:** `GBridgeReceiver.sol:70-71`

**Vulnerability:** `_handlePortalMessage` explicitly ignores `sourceType` (line 71: `(sourceType, oracleNonce);`). The contract relies entirely on NativeOracle's callback routing to ensure only `BLOCKCHAIN` (sourceType=0) events reach it.

If governance misconfigures a **default callback** by setting GBridgeReceiver as the handler for all sourceType=0 events (`setDefaultCallback(0, gBridgeReceiverAddress)`), then events from **any** blockchain source (not just the trusted one) would be routed to this contract. While `sourceId` validation (line 74) would catch mismatched chains, the defense-in-depth principle is violated.

More critically: if a governance error registers GBridgeReceiver as a default callback for a **different sourceType** (e.g., sourceType=3 PRICE_FEED), and a malicious price feed payload happens to ABI-decode as `(uint256, address)`, the contract would attempt to mint tokens.

**Mitigation:** Add `if (sourceType != EXPECTED_SOURCE_TYPE) revert InvalidSourceType();`

---

### 4. Nonce Space is `uint128` — Non-Sequential Processing Allows Griefing of Storage
**Severity: Medium**

**Location:** `GBridgeReceiver.sol:31` — `mapping(uint128 => bool) private _processedNonces`

**Vulnerability:** The `_processedNonces` mapping uses `uint128` keys from the GravityPortal's monotonically incrementing counter. Since nonces are processed **non-sequentially** (any nonce can be processed in any order as long as it hasn't been seen before), there is no way to compact or prune the mapping.

Over the lifetime of the bridge, this mapping grows unboundedly — every bridge operation adds a new storage slot that is never reclaimed. This is an economic concern (permanent state bloat) but not exploitable for fund theft.

More importantly, because nonces are not required to be sequential, there is **no way to detect gaps** — a missing nonce (from a failed callback, see Finding #1) is indistinguishable from a not-yet-processed nonce.

**Mitigation:** Consider tracking a `latestProcessedNonce` or a bitmap-based approach for sequential nonce ranges. This would also make gap detection possible.

---

### 5. Precompile Call Uses `abi.encodePacked` — Interface Mismatch with `INativeMintPrecompile`
**Severity: Medium**

**Location:** `GBridgeReceiver.sol:99-100` vs `IGBridgeReceiver.sol:68-76`

**Vulnerability:** The `INativeMintPrecompile` interface declares `mint(address, uint256)` (standard ABI encoding), but the actual call at line 99-100 uses:

```solidity
bytes memory callData = abi.encodePacked(uint8(0x01), recipient, amount);
```

This is a 53-byte raw payload (`0x01 || address(20) || uint256(32)`), NOT a standard ABI-encoded function call. The interface `INativeMintPrecompile` is therefore **misleading** — no consumer of the interface can correctly call the precompile using standard Solidity.

If the precompile implementation ever changes to expect standard ABI encoding (as the interface suggests), or if another contract uses `INativeMintPrecompile(addr).mint(...)` based on the interface, the call will produce incorrect behavior or fail silently.

This is not currently exploitable (the precompile is a system-level construct), but represents a dangerous maintenance trap.

---

## Summary

| # | Finding | Severity | Exploitable? |
|---|---------|----------|-------------|
| 1 | No callback retry — permanent fund loss | **Critical** | Yes — OOG or any revert in callback permanently strands user funds |
| 2 | One-shot emergency + no deposit pause | **High** | Yes — second failure after emergency has no recovery path |
| 3 | `sourceType` not validated | **High** | Requires governance misconfiguration, but no defense-in-depth |
| 4 | Unbounded nonce mapping, no gap detection | **Medium** | State bloat; masks failed bridge operations |
| 5 | Precompile interface/implementation mismatch | **Medium** | Maintenance trap; no current exploit vector |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | Now I have the full picture. Here's my red team analysis:

- | 253189ms |
