#!/usr/bin/env bash
# lib/helpers.sh — Shared helper functions for hardfork verification scripts.
#
# Source this file from any hardfork verification script.
# Provides: pass(), fail(), skip(), check_call(), check_reverts(), check_exists(),
#           normalize_cast_output(), verify_codehashes()

# ── Counters ──────────────────────────────────────────────────────────
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

# ── Output normalization ─────────────────────────────────────────────
# cast can return values like "31536000000000[3.153e13]" — strip the [...] suffix
normalize_cast_output() {
    echo "$1" | sed 's/\[.*\]//g' | tr -d ' \n' | tr '[:upper:]' '[:lower:]'
}

# ── Functional smoke test helpers ────────────────────────────────────

# check_call: Call a view function and compare result to expected value.
#   check_call "label" "address" "sig()(returnType)" "expected" [args...]
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

    result_norm=$(normalize_cast_output "$result")
    expected_norm=$(echo "$expected" | tr -d ' \n' | tr '[:upper:]' '[:lower:]')

    if [ "$result_norm" = "$expected_norm" ]; then
        pass "${label}: ${result_norm}"
    else
        fail "${label}: expected=${expected_norm}, got=${result_norm}"
    fi
}

# check_reverts: Verify that a call reverts.
#   check_reverts "label" "address" "sig()" [args...]
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

# check_exists: Verify that a function call does NOT revert (function exists).
#   check_exists "label" "address" "sig()(returnType)" [args...]
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

# ── Bytecode hash verification ───────────────────────────────────────

# verify_codehash: Compare on-chain codehash for a single contract.
#   verify_codehash "name" "address" "expected_hash"
verify_codehash() {
    local name="$1"
    local addr="$2"
    local expected="$3"

    if [ -z "$expected" ]; then
        skip "${name} (${addr}): no expected hash"
        return
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
}

# verify_system_contracts: Verify codehashes for all contracts in SYSTEM_CONTRACTS array.
# Expects: SYSTEM_CONTRACTS array and EXPECTED_HASH_<name> variables to be set.
verify_system_contracts() {
    echo "--- System Contracts ---"
    for entry in "${SYSTEM_CONTRACTS[@]}"; do
        name="${entry%%:*}"
        addr="${entry#*:}"
        expected_var="EXPECTED_HASH_${name}"
        expected="${!expected_var:-}"
        verify_codehash "$name" "$addr" "$expected"
    done
    echo ""
}

# verify_stakepool_instances: Verify StakePool codehashes via Staking.getAllPools().
# Sets pool_list variable for use by subsequent smoke tests.
# Expects: STAKING address, EXPECTED_HASH_StakePool variable.
verify_stakepool_instances() {
    echo "--- StakePool Instances ---"
    local stakepool_expected="${EXPECTED_HASH_StakePool:-}"
    if [ -z "$stakepool_expected" ]; then
        skip "StakePool: no expected hash"
        return
    fi

    local staking_addr="$1"
    pool_raw=$(cast call "$staking_addr" "getAllPools()(address[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

    if [ "$pool_raw" = "ERROR" ]; then
        fail "StakePool: failed to query getAllPools()"
        return
    fi

    pool_list=$(echo "$pool_raw" | tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
    pool_count=$(echo "$pool_list" | wc -l | tr -d ' ')
    echo "  Found ${pool_count} StakePool(s)"

    local pool_all_match=true
    local pool_idx=0
    while IFS= read -r pool_addr; do
        pool_idx=$((pool_idx + 1))
        pool_addr=$(echo "$pool_addr" | tr -d ' ')
        [ -z "$pool_addr" ] && continue

        onchain=$(cast codehash "$pool_addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

        if [ "$onchain" = "ERROR" ]; then
            fail "StakePool #${pool_idx} (${pool_addr}): failed to query codehash"
            pool_all_match=false
        elif [ "$onchain" = "$stakepool_expected" ]; then
            if [ "$pool_count" -le 10 ]; then
                pass "StakePool #${pool_idx} (${pool_addr}): codehash matches"
            fi
        else
            fail "StakePool #${pool_idx} (${pool_addr}): MISMATCH"
            echo "        expected: ${stakepool_expected}"
            echo "        got:      ${onchain}"
            pool_all_match=false
        fi
    done <<< "$pool_list"

    if [ "$pool_all_match" = true ] && [ "$pool_count" -gt 10 ]; then
        pass "All ${pool_count} StakePool instances: codehash matches"
    fi
    echo ""
}

# ── Summary ──────────────────────────────────────────────────────────

print_summary() {
    local hardfork_name="${1:-hardfork}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        ${hardfork_name} Verification — Summary              "
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
}
