# Hardfork Verification Framework

Generic verification suite for Gravity chain hardfork contract upgrades. Each hardfork is defined as a configuration file; the framework handles bytecode hash comparison and functional smoke tests.

## Quick Start

```bash
# 1. Generate expected codehashes (compiles contracts at HEAD)
bash scripts/verify_hardfork/generate_hashes.sh gamma

# 2. Verify against a live chain
bash scripts/verify_hardfork/verify.sh gamma http://localhost:8545
```

## Directory Structure

```
scripts/verify_hardfork/
├── verify.sh                  # Generic entry point
├── generate_hashes.sh         # Generic hash generator
├── README.md                  # This file
├── lib/
│   ├── addresses.sh           # System contract address constants
│   ├── helpers.sh             # Shared verification helpers
│   └── stakepool.sh           # StakePool immutable patching
├── hardforks/
│   ├── gamma.sh               # Gamma hardfork config
│   └── (delta.sh, ...)        # Future hardforks
└── generated/
    └── gamma_expected_hashes.sh   # Auto-generated (do not edit)
```

## Adding a New Hardfork

1. **Create config** at `hardforks/<name>.sh`:

```bash
#!/usr/bin/env bash
HARDFORK_DISPLAY_NAME="Delta Hardfork"

# Contracts upgraded in this hardfork
SYSTEM_CONTRACTS=(
    "ContractName:${ADDRESS_VAR}"
    # ...
)

# Whether to also verify StakePool instances
VERIFY_STAKEPOOL=false

# Functional smoke tests (optional)
run_smoke_tests() {
    check_call "label" "$ADDR" "sig()(type)" "expected"
    check_reverts "label" "$ADDR" "sig()"
    check_exists "label" "$ADDR" "sig()(type)"
}
```

2. **Generate hashes**: `bash scripts/verify_hardfork/generate_hashes.sh delta`
3. **Verify**: `bash scripts/verify_hardfork/verify.sh delta <RPC_URL>`

## Verification Phases

| Phase | What | How |
|-------|------|-----|
| 1 | Bytecode Hash Comparison | `cast codehash` on-chain vs expected from `forge inspect` |
| 2 | Functional Smoke Tests | `cast call` to verify new/changed functions work |

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`)
- `python3` (for StakePool immutable patching)
- Access to a post-hardfork RPC endpoint

## Exit Codes

- `0` — All checks passed ✅
- `1` — One or more checks failed ❌
