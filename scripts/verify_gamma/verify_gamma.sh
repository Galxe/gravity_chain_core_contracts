#!/usr/bin/env bash
# verify_gamma.sh
#
# Verifies gamma hardfork contract upgrades on a live chain.
#
# Usage:
#   # First, generate expected hashes (once, from contract repo):
#   bash scripts/verify_gamma/generate_expected_hashes.sh
#
#   # Then verify against a live chain:
#   bash scripts/verify_gamma/verify_gamma.sh <RPC_URL>
#
# Exit code: 0 = all pass, 1 = any fail

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

if [ $# -lt 1 ]; then
    echo "Usage: $0 <RPC_URL>"
    echo ""
    echo "Example: $0 http://localhost:8545"
    echo ""
    echo "Make sure to run generate_expected_hashes.sh first!"
    exit 1
fi

RPC_URL="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source addresses and expected hashes
source "${SCRIPT_DIR}/addresses.sh"

if [ ! -f "${SCRIPT_DIR}/expected_hashes.sh" ]; then
    echo "❌ expected_hashes.sh not found. Run generate_expected_hashes.sh first."
    exit 1
fi
source "${SCRIPT_DIR}/expected_hashes.sh"

PASS=0
FAIL=0
SKIP=0

pass() {
    echo "  ✅ $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ❌ $1"
    FAIL=$((FAIL + 1))
}

skip() {
    echo "  ⏭️  $1"
    SKIP=$((SKIP + 1))
}

# ============================================================================
# Phase 1: Bytecode Hash Verification
# ============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Gamma Hardfork Verification — Phase 1               ║"
echo "║        Bytecode Hash Comparison                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "RPC: ${RPC_URL}"
echo ""

# 1a. System contracts (11 fixed addresses)
echo "--- System Contracts (11) ---"

for entry in "${SYSTEM_CONTRACTS[@]}"; do
    name="${entry%%:*}"
    addr="${entry#*:}"

    # Get expected hash variable name
    expected_var="EXPECTED_HASH_${name}"
    expected="${!expected_var:-}"

    if [ -z "$expected" ]; then
        skip "${name} (${addr}): no expected hash"
        continue
    fi

    onchain=$(cast codehash "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

    if [ "$onchain" = "ERROR" ]; then
        fail "${name} (${addr}): failed to query codehash"
    elif [ "$onchain" = "$expected" ]; then
        pass "${name}: codehash matches"
    else
        fail "${name} (${addr}): MISMATCH"
        echo "        expected: ${expected}"
        echo "        got:      ${onchain}"
    fi
done

echo ""

# 1b. StakePool instances (dynamic, queried on-chain)
echo "--- StakePool Instances ---"

STAKEPOOL_EXPECTED="${EXPECTED_HASH_StakePool:-}"
if [ -z "$STAKEPOOL_EXPECTED" ]; then
    skip "StakePool: no expected hash in expected_hashes.sh"
else
    # Query all pool addresses from Staking contract
    pool_raw=$(cast call "$STAKING" "getAllPools()(address[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

    if [ "$pool_raw" = "ERROR" ]; then
        fail "StakePool: failed to query getAllPools()"
    else
        # Parse the address array output from cast
        # cast returns: [addr1, addr2, ...]
        # Clean up the output: remove brackets, commas, whitespace
        pool_list=$(echo "$pool_raw" | tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
        pool_count=$(echo "$pool_list" | wc -l | tr -d ' ')

        echo "  Found ${pool_count} StakePool(s)"

        pool_all_match=true
        pool_idx=0
        while IFS= read -r pool_addr; do
            pool_idx=$((pool_idx + 1))
            pool_addr=$(echo "$pool_addr" | tr -d ' ')
            [ -z "$pool_addr" ] && continue

            onchain=$(cast codehash "$pool_addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

            if [ "$onchain" = "ERROR" ]; then
                fail "StakePool #${pool_idx} (${pool_addr}): failed to query codehash"
                pool_all_match=false
            elif [ "$onchain" = "$STAKEPOOL_EXPECTED" ]; then
                # Only print individual results if there are few pools, otherwise summarize
                if [ "$pool_count" -le 10 ]; then
                    pass "StakePool #${pool_idx} (${pool_addr}): codehash matches"
                fi
            else
                fail "StakePool #${pool_idx} (${pool_addr}): MISMATCH"
                echo "        expected: ${STAKEPOOL_EXPECTED}"
                echo "        got:      ${onchain}"
                pool_all_match=false
            fi
        done <<< "$pool_list"

        if [ "$pool_all_match" = true ]; then
            if [ "$pool_count" -gt 10 ]; then
                pass "All ${pool_count} StakePool instances: codehash matches"
            fi
        fi
    fi
fi

echo ""

# ============================================================================
# Phase 2: Functional Smoke Tests
# ============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Gamma Hardfork Verification — Phase 2               ║"
echo "║        Functional Smoke Tests                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Helper: normalize cast output
# cast can return values like "31536000000000[3.153e13]" — strip the [...] suffix
normalize_cast_output() {
    echo "$1" | sed 's/\[.*\]//g' | tr -d ' \n' | tr '[:upper:]' '[:lower:]'
}

# Helper: call a view function and check result
check_call() {
    local label="$1"
    local addr="$2"
    local sig="$3"
    local expected="$4"
    shift 4
    local args=("$@")

    result=$(cast call "$addr" "$sig" "${args[@]}" --rpc-url "$RPC_URL" 2>/dev/null || echo "REVERT")

    if [ "$result" = "REVERT" ]; then
        fail "${label}: call reverted"
        return
    fi

    # Normalize: strip [scientific notation], whitespace, and lowercase
    result_norm=$(normalize_cast_output "$result")
    expected_norm=$(echo "$expected" | tr -d ' \n' | tr '[:upper:]' '[:lower:]')

    if [ "$result_norm" = "$expected_norm" ]; then
        pass "${label}: ${result_norm}"
    else
        fail "${label}: expected=${expected_norm}, got=${result_norm}"
    fi
}

# Helper: verify a call reverts
check_reverts() {
    local label="$1"
    local addr="$2"
    local sig="$3"
    shift 3
    local args=("$@")

    result=$(cast call "$addr" "$sig" "${args[@]}" --rpc-url "$RPC_URL" 2>&1 || true)

    if echo "$result" | grep -qi "revert\|error\|execution reverted"; then
        pass "${label}: correctly reverts"
    else
        fail "${label}: expected revert but got success (${result})"
    fi
}

# Helper: verify a call does NOT revert (function exists)
check_exists() {
    local label="$1"
    local addr="$2"
    local sig="$3"
    shift 3
    local args=("$@")

    result=$(cast call "$addr" "$sig" "${args[@]}" --rpc-url "$RPC_URL" 2>/dev/null || echo "REVERT")

    if [ "$result" = "REVERT" ]; then
        fail "${label}: call reverted (function may not exist)"
    else
        pass "${label}: OK"
    fi
}

# --- 2.1 StakingConfig ---
echo "--- StakingConfig ---"

check_call "hasPendingConfig()" "$STAKE_CONFIG" "hasPendingConfig()(bool)" "false"
check_call "isInitialized()" "$STAKE_CONFIG" "isInitialized()(bool)" "true"

# MAX_LOCKUP_DURATION = 4 * 365 * 86400 * 1_000_000 = 126144000000000
# Note: Solidity `365 days` = exactly 365 * 86400 seconds (no leap year)
check_call "MAX_LOCKUP_DURATION()" "$STAKE_CONFIG" "MAX_LOCKUP_DURATION()(uint64)" "126144000000000"

# MAX_UNBONDING_DELAY = 365 * 86400 * 1_000_000 = 31536000000000
check_call "MAX_UNBONDING_DELAY()" "$STAKE_CONFIG" "MAX_UNBONDING_DELAY()(uint64)" "31536000000000"

check_exists "getPendingConfig()" "$STAKE_CONFIG" "getPendingConfig()(bool,(uint256,uint64,uint64,uint256))"

echo ""

# --- 2.2 ValidatorConfig ---
echo "--- ValidatorConfig ---"

check_call "MAX_UNBONDING_DELAY()" "$VALIDATOR_CONFIG" "MAX_UNBONDING_DELAY()(uint64)" "31536000000000"

echo ""

# --- 2.3 Governance ---
echo "--- Governance ---"

check_reverts "renounceOwnership() reverts" "$GOVERNANCE" "renounceOwnership()"

echo ""

# --- 2.4 StakePool (first pool) ---
echo "--- StakePool (first pool) ---"

if [ -n "${pool_list:-}" ]; then
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

# --- 2.5 NativeOracle ---
echo "--- NativeOracle ---"

check_exists "getLatestNonce(0, 1)" "$NATIVE_ORACLE" "getLatestNonce(uint32,uint256)(uint128)" 0 1

echo ""

# --- 2.6 Staking ---
echo "--- Staking ---"

check_exists "getPoolCount()" "$STAKING" "getPoolCount()(uint256)"

echo ""

# ============================================================================
# Summary
# ============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Summary                                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  ✅ Passed:  ${PASS}"
echo "  ❌ Failed:  ${FAIL}"
echo "  ⏭️  Skipped: ${SKIP}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "❌ VERIFICATION FAILED — ${FAIL} check(s) did not pass"
    exit 1
else
    echo "✅ ALL CHECKS PASSED"
    exit 0
fi
