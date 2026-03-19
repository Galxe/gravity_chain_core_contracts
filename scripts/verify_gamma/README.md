# Gamma Hardfork Verification Scripts

Post-upgrade verification suite for the Gamma hardfork. Uses `cast` CLI to validate that all contract bytecode replacements were correctly applied on a live chain.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`)
- `python3` (for StakePool immutable patching)
- Access to a post-gamma RPC endpoint

## Quick Start

```bash
# 1. Generate expected codehashes (compiles contracts)
bash scripts/verify_gamma/generate_expected_hashes.sh

# 2. Verify against a live chain
bash scripts/verify_gamma/verify_gamma.sh <RPC_URL>
```

**Example:**
```bash
bash scripts/verify_gamma/verify_gamma.sh http://localhost:8545
```

## What It Verifies

### Phase 1 — Bytecode Hash Comparison

Compares on-chain `codehash` against expected values for:

| # | Contract | Address | Notes |
|---|----------|---------|-------|
| 1 | StakingConfig | `0x...1001` | — |
| 2 | ValidatorConfig | `0x...1002` | — |
| 3 | GovernanceConfig | `0x...1004` | — |
| 4 | Staking | `0x...2000` | — |
| 5 | ValidatorManagement | `0x...2001` | — |
| 6 | Reconfiguration | `0x...2003` | — |
| 7 | Blocker | `0x...2004` | — |
| 8 | ValidatorPerformanceTracker | `0x...2005` | — |
| 9 | Governance | `0x...3000` | — |
| 10 | NativeOracle | `0x...4000` | — |
| 11 | OracleRequestQueue | `0x...4002` | — |
| 12 | StakePool (×N) | dynamic | Addresses queried via `Staking.getAllPools()` |

### Phase 2 — Functional Smoke Tests

Calls new/changed functions to verify behavioral correctness:

- **StakingConfig**: `hasPendingConfig()`, `isInitialized()`, `MAX_LOCKUP_DURATION()`, `MAX_UNBONDING_DELAY()`, `getPendingConfig()`
- **ValidatorConfig**: `MAX_UNBONDING_DELAY()`
- **Governance**: `renounceOwnership()` correctly reverts
- **StakePool**: `getRewardBalance()`, `FACTORY()`, `MAX_LOCKUP_DURATION()`, `MAX_PENDING_BUCKETS()`
- **NativeOracle**: `getLatestNonce()`
- **Staking**: `getPoolCount()`

## Files

| File | Description |
|------|-------------|
| `addresses.sh` | System contract address constants |
| `generate_expected_hashes.sh` | Compiles contracts and computes expected codehashes |
| `expected_hashes.sh` | Auto-generated output (do not edit manually) |
| `verify_gamma.sh` | Main verification script |

## How StakePool Codehash Is Computed

StakePool has an `immutable FACTORY` variable embedded in the runtime bytecode. `forge inspect` outputs zeros at the immutable positions. The `generate_expected_hashes.sh` script:

1. Reads immutable reference offsets from the build artifact (`out/StakePool.sol/StakePool.json`)
2. Patches those positions with the Staking system address (`0x...2000`)
3. Computes `keccak256` of the patched bytecode

This produces the correct expected codehash without needing to deploy.

## Exit Codes

- `0` — All checks passed ✅
- `1` — One or more checks failed ❌
