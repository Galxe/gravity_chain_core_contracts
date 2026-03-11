# attack_jwk_manager_oracle_integration

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 94349ms
- **Steps**: 1

## Report

# Red Team Attack Report: JWKManager Contract

## Critical Findings

### 1. [High] Unbounded Gas Cost in `_regeneratePatchedJWKs` — Potential Permanent DoS

**Location**: `JWKManager.sol:336-361`

Every state mutation (`onOracleEvent`, `setPatches`, `initialize`) triggers a **full rebuild** of patched state:
1. Delete all patched providers (O(N) storage deletions)
2. Copy all observed providers to patched (O(N*M) storage writes)
3. Apply all patches (O(P) operations, each potentially O(N*M))

As `_observedIssuers` grows (it is **append-only** — no mechanism ever removes an observed issuer), each oracle callback costs more gas. Once total gas exceeds block gas limit, **no more JWK updates can be processed**, permanently bricking the oracle callback path.

**Attack scenario**: A compromised or buggy NativeOracle submits updates for many distinct issuers over time. Eventually the regeneration cost exceeds the block gas limit. At that point:
- `onOracleEvent` reverts on every call → JWK rotations stop
- `setPatches` also reverts → governance cannot patch either
- The system is permanently stuck with stale JWKs

**Severity justification**: Even without an attacker, organic growth of providers over time makes this a ticking time bomb. Governance has no way to clean up `_observedIssuers`.

---

### 2. [High] No `_initialized` Guard on `onOracleEvent` and `setPatches`

**Location**: `JWKManager.sol:117-154`, `JWKManager.sol:161-181`

Neither `onOracleEvent` nor `setPatches` checks `_initialized`. If NativeOracle or Governance sends a transaction before `initialize()` is called:

- `onOracleEvent`: A new issuer with version=1 gets written to observed state. When `initialize()` later runs, it also sets version=1 for potentially the same issuer. But the version check in `initialize` does **not use** `_issuerVersions` — it unconditionally writes `_issuerVersions[issuerHash] = 1`. This **resets the version counter**, allowing the oracle to replay version=2 even if version=2 was already processed pre-init.

- `setPatches`: Patches get stored and `_regeneratePatchedJWKs()` runs against empty observed state. When `initialize` later runs, it calls `_regeneratePatchedJWKs()` which applies stale patches that governance may have already superseded.

**Severity justification**: Depends on deployment ordering guarantees. If `initialize` is called in a genesis block before any other transactions, this is not exploitable. If not, it's a race condition that can corrupt version tracking.

---

### 3. [High] `sourceType` Not Validated in Oracle Callback

**Location**: `JWKManager.sol:128-129`

```solidity
// Silence unused variable warnings
(sourceType, sourceId, nonce);
```

The contract blindly ABI-decodes **any** payload from NativeOracle, regardless of `sourceType`. If NativeOracle routes a non-JWK event type to the JWKManager callback (e.g., due to a configuration error or a separate vulnerability in NativeOracle), the payload will be decoded as JWK data. If the ABI decoding happens to succeed (which it can for certain byte patterns), arbitrary data gets stored as JWK keys.

**Impact**: Corrupted JWK entries could allow forged JWT signatures to be validated, compromising keyless account authentication.

---

### 4. [Medium] Duplicate JWKs with Same `kid` Accepted by `_upsertObservedProvider`

**Location**: `JWKManager.sol:304-329`

`_upsertObservedProvider` does a `delete provider.jwks` followed by pushing all JWKs from the input array. It performs **no deduplication by `kid`**. If the oracle payload contains two JWKs with the same `kid` but different `n` (modulus) values, both are stored.

Query functions (`getJWK`, `hasJWK`) return the **first** match by linear scan. But `_upsertJWKToPatched` and `_removeJWKFromPatched` also match the first `kid`. This means:
- The second duplicate JWK is invisible to queries and patch operations
- It persists in storage and gets copied during regeneration
- It contributes to gas costs but can never be individually addressed

**Impact**: Wasted gas and potential confusion in off-chain systems that read raw storage or iterate JWK arrays.

---

### 5. [Medium] Governance Patch `RemoveAll` Doesn't Prevent Regeneration Cost

**Location**: `JWKManager.sol:336-361`

Even with a `RemoveAll` patch at index 0, `_regeneratePatchedJWKs` still:
1. Clears all patched state
2. **Copies ALL observed providers to patched** (full cost)
3. Then applies `RemoveAll` which clears everything again

This means the gas cost of regeneration is always at least proportional to the observed state size, regardless of patches. Governance cannot use `RemoveAll` as a mitigation for finding #1.

---

### 6. [Medium] Stale Issuer Entries in `_observedIssuers` After Hash Collision (Theoretical)

**Location**: `JWKManager.sol:304-316`

Observed providers are keyed by `keccak256(issuer)`. The `_observedIssuers` array stores the raw `bytes issuer`. If two different issuer byte strings collide on `keccak256` (theoretical), the second upsert would overwrite the first's `ProviderJWKsStorage` (since `exists` is already `true`), but the first issuer's raw bytes remain in `_observedIssuers`. During regeneration, the stale entry maps to the overwritten provider, causing the same provider to be copied twice (once under each raw issuer key, but both resolve to the same `issuerHash`).

**Severity justification**: keccak256 collision is computationally infeasible currently, but the code does not defend against it.

---

## Summary

| # | Finding | Severity | Exploitable Without Privileged Access? |
|---|---------|----------|---------------------------------------|
| 1 | Unbounded gas in regeneration → permanent DoS | **High** | No (requires many oracle updates over time) |
| 2 | Missing `_initialized` check on oracle/governance paths | **High** | No (requires pre-genesis transactions) |
| 3 | `sourceType` not validated in oracle callback | **High** | No (requires NativeOracle misconfiguration) |
| 4 | Duplicate `kid` entries accepted and unreachable | **Medium** | No (requires malformed oracle payload) |
| 5 | `RemoveAll` patch cannot reduce regeneration gas cost | **Medium** | N/A (design limitation) |
| 6 | Theoretical keccak256 collision handling | **Medium** | No (computationally infeasible) |

**Recommendation priority**: Finding #1 is the most actionable — consider incremental patching instead of full regeneration, or add a mechanism to prune `_observedIssuers`.

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | # Red Team Attack Report: JWKManager Contract

## Critical F | 94348ms |
