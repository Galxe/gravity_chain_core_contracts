#!/usr/bin/env bash
# System contract addresses from SystemAddresses.sol
# Used by verify_gamma.sh and generate_expected_hashes.sh

# Runtime Configurations (0x1625F1xxx)
STAKE_CONFIG="0x0000000000000000000000000001625F1001"
VALIDATOR_CONFIG="0x0000000000000000000000000001625F1002"
GOVERNANCE_CONFIG="0x0000000000000000000000000001625F1004"

# Staking & Validator (0x1625F2xxx)
STAKING="0x0000000000000000000000000001625F2000"
VALIDATOR_MANAGER="0x0000000000000000000000000001625F2001"
RECONFIGURATION="0x0000000000000000000000000001625F2003"
BLOCKER="0x0000000000000000000000000001625F2004"
PERFORMANCE_TRACKER="0x0000000000000000000000000001625F2005"

# Governance (0x1625F3xxx)
GOVERNANCE="0x0000000000000000000000000001625F3000"

# Oracle (0x1625F4xxx)
NATIVE_ORACLE="0x0000000000000000000000000001625F4000"
ORACLE_REQUEST_QUEUE="0x0000000000000000000000000001625F4002"

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
