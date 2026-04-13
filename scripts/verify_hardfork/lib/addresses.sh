#!/usr/bin/env bash
# lib/addresses.sh — System contract address constants for Gravity chain.
#
# Shared across all hardfork verification scripts.
# Source: SystemAddresses.sol

# Normalize address to 0x + 40 hex chars (20 bytes), left-padding with zeros.
_addr() {
    local raw="${1#0x}"
    printf '0x%040s' "$raw" | tr ' ' '0'
}

# ── Runtime Configurations (0x1625F1xxx) ─────────────────────────────
STAKE_CONFIG=$(_addr 0x1625F1001)
VALIDATOR_CONFIG=$(_addr 0x1625F1002)
GOVERNANCE_CONFIG=$(_addr 0x1625F1004)

# ── Staking & Validator (0x1625F2xxx) ────────────────────────────────
STAKING=$(_addr 0x1625F2000)
VALIDATOR_MANAGER=$(_addr 0x1625F2001)
RECONFIGURATION=$(_addr 0x1625F2003)
BLOCKER=$(_addr 0x1625F2004)
PERFORMANCE_TRACKER=$(_addr 0x1625F2005)

# ── Governance (0x1625F3xxx) ─────────────────────────────────────────
GOVERNANCE=$(_addr 0x1625F3000)

# ── Oracle (0x1625F4xxx) ─────────────────────────────────────────────
NATIVE_ORACLE=$(_addr 0x1625F4000)
ORACLE_REQUEST_QUEUE=$(_addr 0x1625F4002)

# ── Bridge (dynamically deployed by Genesis, not a 0x1625Fxxxx slot) ──
# Default to gravity testnet deployment; override with `GBRIDGE_RECEIVER=0x... verify.sh ...`
GBRIDGE_RECEIVER="${GBRIDGE_RECEIVER:-0x595475934ed7d9faa7fca28341c2ce583904a44e}"
