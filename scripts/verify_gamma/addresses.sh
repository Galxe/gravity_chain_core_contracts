#!/usr/bin/env bash
# System contract addresses from SystemAddresses.sol
# Used by verify_gamma.sh and generate_expected_hashes.sh

# Normalize address to 0x + 40 hex chars (20 bytes), left-padding with zeros.
_addr() {
    local raw="${1#0x}"
    printf '0x%040s' "$raw" | tr ' ' '0'
}

# Runtime Configurations (0x1625F1xxx)
STAKE_CONFIG=$(_addr 0x1625F1001)
VALIDATOR_CONFIG=$(_addr 0x1625F1002)
GOVERNANCE_CONFIG=$(_addr 0x1625F1004)

# Staking & Validator (0x1625F2xxx)
STAKING=$(_addr 0x1625F2000)
VALIDATOR_MANAGER=$(_addr 0x1625F2001)
RECONFIGURATION=$(_addr 0x1625F2003)
BLOCKER=$(_addr 0x1625F2004)
PERFORMANCE_TRACKER=$(_addr 0x1625F2005)

# Governance (0x1625F3xxx)
GOVERNANCE=$(_addr 0x1625F3000)

# Oracle (0x1625F4xxx)
NATIVE_ORACLE=$(_addr 0x1625F4000)
ORACLE_REQUEST_QUEUE=$(_addr 0x1625F4002)

# ============================================================================
# Contract name → address mapping (for iteration)
# ============================================================================
# These are the 11 system contracts upgraded in gamma hardfork.
# StakePool is handled separately (multiple instances, has immutable).

SYSTEM_CONTRACTS=(
    "StakingConfig:${STAKE_CONFIG}"
    "ValidatorConfig:${VALIDATOR_CONFIG}"
    "GovernanceConfig:${GOVERNANCE_CONFIG}"
    "Staking:${STAKING}"
    "ValidatorManagement:${VALIDATOR_MANAGER}"
    "Reconfiguration:${RECONFIGURATION}"
    "Blocker:${BLOCKER}"
    "ValidatorPerformanceTracker:${PERFORMANCE_TRACKER}"
    "Governance:${GOVERNANCE}"
    "NativeOracle:${NATIVE_ORACLE}"
    "OracleRequestQueue:${ORACLE_REQUEST_QUEUE}"
)
