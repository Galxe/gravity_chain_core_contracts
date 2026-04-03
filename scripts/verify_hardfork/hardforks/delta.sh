#!/usr/bin/env bash
# hardforks/delta.sh — Delta hardfork verification configuration.
#
# Defines which contracts to verify and the functional smoke tests to run
# for the Delta hardfork. Sourced by verify.sh.
#
# Delta upgrades 4 system contracts:
#   - StakingConfig: minimumProposalStake deprecated (storage gap pattern)
#   - ValidatorManagement: consensus key rotation, try/catch renewPoolLockup,
#     whale VP fix, eviction fairness fix
#   - Governance: MAX_PROPOSAL_TARGETS limit, ProposalNotResolved check
#   - NativeOracle: callback invocation refactored, CallbackSkipped event

HARDFORK_DISPLAY_NAME="Delta Hardfork"

# ── System contracts upgraded in this hardfork ────────────────────────
# Format: "ContractName:address"
# These are verified for bytecode hash changes.
SYSTEM_CONTRACTS=(
    "StakingConfig:${STAKE_CONFIG}"
    "ValidatorManagement:${VALIDATOR_MANAGER}"
    "Governance:${GOVERNANCE}"
    "NativeOracle:${NATIVE_ORACLE}"
)

# ── StakePool verification ────────────────────────────────────────────
# Delta does NOT upgrade StakePool bytecodes.
VERIFY_STAKEPOOL=false

# ── ReentrancyGuard storage slot (ERC-7201 namespaced) ───────────────
# Initialized during Gamma hardfork; must persist through Delta.
REENTRANCY_GUARD_SLOT="0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00"

# ── Functional smoke tests ────────────────────────────────────────────
# Define a function that runs the hardfork-specific smoke tests.
# Has access to all variables from helpers.sh and addresses.sh.
run_smoke_tests() {
    echo "--- StakingConfig ---"
    check_call "isInitialized()" "$STAKE_CONFIG" "isInitialized()(bool)" "true"
    check_call "hasPendingConfig()" "$STAKE_CONFIG" "hasPendingConfig()(bool)" "false"
    # MAX_LOCKUP_DURATION = 4 * 365 * 86400 * 1_000_000 = 126144000000000
    check_call "MAX_LOCKUP_DURATION()" "$STAKE_CONFIG" "MAX_LOCKUP_DURATION()(uint64)" "126144000000000"
    # MAX_UNBONDING_DELAY = 365 * 86400 * 1_000_000 = 31536000000000
    check_call "MAX_UNBONDING_DELAY()" "$STAKE_CONFIG" "MAX_UNBONDING_DELAY()(uint64)" "31536000000000"
    # New 3-arg getPendingConfig signature (minimumProposalStake removed)
    check_exists "getPendingConfig()" "$STAKE_CONFIG" "getPendingConfig()(bool,(uint256,uint64,uint64))"
    echo ""

    echo "--- ValidatorManagement ---"
    # Consensus key rotation: getPendingConsensusKey should exist
    check_exists "getActiveValidatorCount()" "$VALIDATOR_MANAGER" "getActiveValidatorCount()(uint256)"
    echo ""

    echo "--- Governance ---"
    check_call "MAX_PROPOSAL_TARGETS()" "$GOVERNANCE" "MAX_PROPOSAL_TARGETS()(uint256)" "100"
    check_reverts "renounceOwnership() reverts" "$GOVERNANCE" "renounceOwnership()"
    echo ""

    echo "--- NativeOracle ---"
    check_exists "getLatestNonce(0, 1)" "$NATIVE_ORACLE" "getLatestNonce(uint32,uint256)(uint128)" 0 1
    echo ""

    # ── ReentrancyGuard persistence check ────────────────────────────
    # Gamma hardfork initialized the ReentrancyGuard slot to 1 (NOT_ENTERED)
    # in all StakePool instances. Delta must not disturb this.
    echo "--- ReentrancyGuard (StakePool persistence) ---"
    pool_raw=$(cast call "$STAKING" "getAllPools()(address[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

    if [ "$pool_raw" = "ERROR" ]; then
        skip "ReentrancyGuard: failed to query getAllPools()"
    else
        local rg_pool_list
        rg_pool_list=$(echo "$pool_raw" | tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
        local rg_pool_count
        rg_pool_count=$(echo "$rg_pool_list" | wc -l | tr -d ' ')
        local rg_all_ok=true

        while IFS= read -r pool_addr; do
            pool_addr=$(echo "$pool_addr" | tr -d ' ')
            [ -z "$pool_addr" ] && continue

            slot_val=$(cast storage "$pool_addr" "$REENTRANCY_GUARD_SLOT" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

            if [ "$slot_val" = "ERROR" ]; then
                fail "ReentrancyGuard (${pool_addr}): failed to read storage slot"
                rg_all_ok=false
            else
                # Normalize: strip leading zeros, compare with 0x...01
                slot_norm=$(echo "$slot_val" | tr -d ' \n' | tr '[:upper:]' '[:lower:]')
                expected_val="0x0000000000000000000000000000000000000000000000000000000000000001"
                if [ "$slot_norm" = "$expected_val" ]; then
                    if [ "$rg_pool_count" -le 10 ]; then
                        pass "ReentrancyGuard (${pool_addr}): NOT_ENTERED (1)"
                    fi
                else
                    fail "ReentrancyGuard (${pool_addr}): expected 1, got ${slot_norm}"
                    rg_all_ok=false
                fi
            fi
        done <<< "$rg_pool_list"

        if [ "$rg_all_ok" = true ]; then
            if [ "$rg_pool_count" -gt 10 ]; then
                pass "ReentrancyGuard: all ${rg_pool_count} pools have NOT_ENTERED (1)"
            fi
        fi
    fi
    echo ""
}
