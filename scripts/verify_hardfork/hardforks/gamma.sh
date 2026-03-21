#!/usr/bin/env bash
# hardforks/gamma.sh — Gamma hardfork verification configuration.
#
# Defines which contracts to verify and the functional smoke tests to run
# for the Gamma hardfork. Sourced by verify.sh.

HARDFORK_DISPLAY_NAME="Gamma Hardfork"

# ── System contracts upgraded in this hardfork ────────────────────────
# Format: "ContractName:address"
# These are verified for bytecode hash changes.
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

# ── StakePool verification ────────────────────────────────────────────
# Set to true if StakePool instances should also be verified.
VERIFY_STAKEPOOL=true

# ── Functional smoke tests ────────────────────────────────────────────
# Define a function that runs the hardfork-specific smoke tests.
# Has access to all variables from helpers.sh and addresses.sh.
run_smoke_tests() {
    echo "--- StakingConfig ---"
    check_call "hasPendingConfig()" "$STAKE_CONFIG" "hasPendingConfig()(bool)" "false"
    check_call "isInitialized()" "$STAKE_CONFIG" "isInitialized()(bool)" "true"
    # MAX_LOCKUP_DURATION = 4 * 365 * 86400 * 1_000_000 = 126144000000000
    check_call "MAX_LOCKUP_DURATION()" "$STAKE_CONFIG" "MAX_LOCKUP_DURATION()(uint64)" "126144000000000"
    # MAX_UNBONDING_DELAY = 365 * 86400 * 1_000_000 = 31536000000000
    check_call "MAX_UNBONDING_DELAY()" "$STAKE_CONFIG" "MAX_UNBONDING_DELAY()(uint64)" "31536000000000"
    check_exists "getPendingConfig()" "$STAKE_CONFIG" "getPendingConfig()(bool,(uint256,uint64,uint64,uint256))"
    echo ""

    echo "--- ValidatorConfig ---"
    check_call "MAX_UNBONDING_DELAY()" "$VALIDATOR_CONFIG" "MAX_UNBONDING_DELAY()(uint64)" "31536000000000"
    echo ""

    echo "--- Governance ---"
    check_reverts "renounceOwnership() reverts" "$GOVERNANCE" "renounceOwnership()"
    echo ""

    echo "--- StakePool (first pool) ---"
    if [ -n "${pool_list:-}" ]; then
        local first_pool
        first_pool=$(echo "$pool_list" | head -1 | tr -d ' ')
        if [ -n "$first_pool" ]; then
            check_exists "getRewardBalance()" "$first_pool" "getRewardBalance()(uint256)"
            check_call "FACTORY()" "$first_pool" "FACTORY()(address)" "$STAKING"
            check_call "MAX_LOCKUP_DURATION()" "$first_pool" "MAX_LOCKUP_DURATION()(uint64)" "126144000000000"
            check_call "MAX_PENDING_BUCKETS()" "$first_pool" "MAX_PENDING_BUCKETS()(uint256)" "1000"
        else
            skip "StakePool functional tests: no pool address available"
        fi
    else
        skip "StakePool functional tests: pool list not available"
    fi
    echo ""

    echo "--- NativeOracle ---"
    check_exists "getLatestNonce(0, 1)" "$NATIVE_ORACLE" "getLatestNonce(uint32,uint256)(uint128)" 0 1
    echo ""

    echo "--- Staking ---"
    check_exists "getPoolCount()" "$STAKING" "getPoolCount()(uint256)"
    echo ""
}
