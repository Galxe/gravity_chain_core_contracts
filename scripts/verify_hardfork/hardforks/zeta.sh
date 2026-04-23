#!/usr/bin/env bash
# hardforks/zeta.sh — Zeta hardfork verification configuration.
#
# Defines which contracts to verify and the functional smoke tests to run
# for the Zeta hardfork. Sourced by verify.sh.
#
# Zeta upgrades (gravity-testnet-v1.4 → v1.5):
#   - PR #73 (StakePool): 2-step timelock for staker/operator/voter role
#     changes (propose → wait → accept), configurable per-role delay with
#     MIN_ROLE_CHANGE_DELAY = 1 day as floor. Upgraded pools skip constructor
#     so delay slots read 0; _effectiveDelay treats 0 as MIN_ROLE_CHANGE_DELAY.
#   - PR #79 (JWKManager): stricter JWK field non-empty validation on setPatches.
#   - PR #82 (Reconfiguration): apply ValidatorConfig.applyPendingConfig()
#     before _startDkgSession() in checkAndStartTransition/governanceReconfigure
#     so DKG snapshot matches post-apply validator set.
#   - PR #83 (Governance): add initialize(address) + _initialized guard at
#     slot 8; companion reth PR writes slot 0 (_owner) and slot 8 (=1) via
#     set_storage at Zeta activation.
#   - PR #85 (StakingConfig): single-field governance setters —
#     setMinimumStakeForNextEpoch / setLockupDurationForNextEpoch /
#     setUnbondingDelayForNextEpoch, overlaying pending config.
#   - PR #85 (ValidatorManagement): per-pool whitelist + permissionlessJoinEnabled
#     flag gating registerValidator / joinValidatorSet. Companion reth PR
#     batch-seeds _allowedPools[pool]=true for every active pool at Zeta activation.
#
# Workflow on a live node:
#   bash scripts/verify_hardfork/generate_hashes.sh zeta
#   bash scripts/verify_hardfork/verify.sh zeta https://rpc.testnet.gravity.xyz

HARDFORK_DISPLAY_NAME="Zeta Hardfork"

# ── System contracts upgraded in this hardfork ────────────────────────
# Format: "ContractName:address"
# These are verified for bytecode hash changes. JWKManager is deployed inside
# NativeOracle (shares the same bytecode slot via inheritance), so its ABI is
# verified functionally rather than by standalone codehash.
SYSTEM_CONTRACTS=(
    "Governance:${GOVERNANCE}"
    "StakingConfig:${STAKE_CONFIG}"
    "ValidatorManagement:${VALIDATOR_MANAGER}"
    "Reconfiguration:${RECONFIGURATION}"
)

# ── StakePool verification ────────────────────────────────────────────
# Zeta replaces StakePool bytecode on every existing pool (PR #73).
VERIFY_STAKEPOOL=true

# ── ReentrancyGuard storage slot (ERC-7201 namespaced) ───────────────
# Initialized during Gamma hardfork; must persist through Delta/Epsilon/Zeta.
REENTRANCY_GUARD_SLOT="0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00"

# ── Functional smoke tests ────────────────────────────────────────────
run_smoke_tests() {
    echo "--- Governance (PR #83) ---"
    # initialize() must have fired at Zeta activation — _initialized = true,
    # _owner must be non-zero (set via set_storage by reth).
    check_call    "isInitialized() == true"               "$GOVERNANCE" "isInitialized()(bool)" "true"
    owner_addr=$(cast call "$GOVERNANCE" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "REVERT")
    if [ "$owner_addr" = "REVERT" ] || [ -z "$owner_addr" ]; then
        fail "Governance.owner(): call reverted"
    elif [ "$(echo "$owner_addr" | tr '[:upper:]' '[:lower:]')" = "0x0000000000000000000000000000000000000000" ]; then
        fail "Governance.owner(): still zero — set_storage patch did not apply"
    else
        pass "Governance.owner() = ${owner_addr}"
    fi
    # Double-init must now revert (AlreadyInitialized) when called from Genesis
    check_reverts "initialize() double-init reverts"     "$GOVERNANCE" "initialize(address)" "$GENESIS" --from "$GENESIS"
    # Pre-existing invariants preserved
    check_call    "MAX_PROPOSAL_TARGETS()"               "$GOVERNANCE" "MAX_PROPOSAL_TARGETS()(uint256)" "100"
    check_reverts "renounceOwnership() reverts"           "$GOVERNANCE" "renounceOwnership()"
    echo ""

    echo "--- StakingConfig (PR #85) ---"
    # New single-field setters must be in the dispatcher. requireAllowed gate
    # means calls without --from $GOVERNANCE revert; that's fine for existence check.
    check_exists  "setMinimumStakeForNextEpoch() ABI"     "$STAKE_CONFIG" "setMinimumStakeForNextEpoch(uint256)" 0 --from "$GOVERNANCE"
    check_exists  "setLockupDurationForNextEpoch() ABI"   "$STAKE_CONFIG" "setLockupDurationForNextEpoch(uint64)" 0 --from "$GOVERNANCE"
    check_exists  "setUnbondingDelayForNextEpoch() ABI"   "$STAKE_CONFIG" "setUnbondingDelayForNextEpoch(uint64)" 0 --from "$GOVERNANCE"
    # Pre-existing invariants preserved
    check_call    "isInitialized()"                       "$STAKE_CONFIG" "isInitialized()(bool)" "true"
    echo ""

    echo "--- ValidatorManagement (PR #85) ---"
    # New whitelist API must exist
    check_exists  "isPermissionlessJoinEnabled()"         "$VALIDATOR_MANAGER" "isPermissionlessJoinEnabled()(bool)"
    check_exists  "isValidatorPoolAllowed()"              "$VALIDATOR_MANAGER" "isValidatorPoolAllowed(address)(bool)" "$VALIDATOR_MANAGER"
    check_exists  "setValidatorPoolAllowed() ABI"         "$VALIDATOR_MANAGER" "setValidatorPoolAllowed(address,bool)" "$VALIDATOR_MANAGER" false --from "$GOVERNANCE"
    check_exists  "setPermissionlessJoinEnabled() ABI"    "$VALIDATOR_MANAGER" "setPermissionlessJoinEnabled(bool)" false --from "$GOVERNANCE"

    # Existing active pools must be seeded in _allowedPools (companion reth
    # batch_storage_patches). Verify the first active pool, if any.
    pool_raw=$(cast call "$STAKING" "getAllPools()(address[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    if [ "$pool_raw" != "ERROR" ] && [ -n "$pool_raw" ]; then
        first_pool=$(echo "$pool_raw" | tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | head -1)
        if [ -n "$first_pool" ]; then
            check_call "isValidatorPoolAllowed(first_pool)" "$VALIDATOR_MANAGER" "isValidatorPoolAllowed(address)(bool)" "true" "$first_pool"
        else
            skip "_allowedPools seed check: no pools in getAllPools()"
        fi
    else
        skip "_allowedPools seed check: getAllPools() failed"
    fi
    echo ""

    echo "--- Reconfiguration (PR #82) ---"
    # ABI unchanged; both entry points still present (the internal call order
    # of applyPendingConfig before _startDkgSession is a behavioral change only).
    check_exists  "currentEpoch()"                        "$RECONFIGURATION" "currentEpoch()(uint64)"
    check_exists  "checkAndStartTransition() ABI"         "$RECONFIGURATION" "checkAndStartTransition()" --from "$BLOCKER"
    check_exists  "governanceReconfigure() ABI"           "$RECONFIGURATION" "governanceReconfigure()" --from "$GOVERNANCE"
    echo ""

    echo "--- StakePool (PR #73) ---"
    # MIN_ROLE_CHANGE_DELAY constant must be exposed as 1 day = 86400.
    # Sample the first pool, if any.
    if [ -n "${first_pool:-}" ]; then
        check_call    "MIN_ROLE_CHANGE_DELAY == 86400"       "$first_pool" "MIN_ROLE_CHANGE_DELAY()(uint64)" "86400"
        # 2-step role change API
        check_exists  "proposeStaker() ABI"                  "$first_pool" "proposeStaker(address)" "$VALIDATOR_MANAGER"
        check_exists  "acceptStaker() ABI"                   "$first_pool" "acceptStaker()"
        check_exists  "cancelStakerChange() ABI"             "$first_pool" "cancelStakerChange()"
        check_exists  "proposeOperator() ABI"                "$first_pool" "proposeOperator(address)" "$VALIDATOR_MANAGER"
        check_exists  "proposeVoter() ABI"                   "$first_pool" "proposeVoter(address)" "$VALIDATOR_MANAGER"
        # Per-role delay fields, should read 0 on upgraded pools (lazy default)
        check_exists  "stakerChangeDelay()"                  "$first_pool" "stakerChangeDelay()(uint64)"
        check_exists  "operatorChangeDelay()"                "$first_pool" "operatorChangeDelay()(uint64)"
        check_exists  "voterChangeDelay()"                   "$first_pool" "voterChangeDelay()(uint64)"
        # Pre-existing views still work
        check_call    "FACTORY()"                            "$first_pool" "FACTORY()(address)" "$STAKING"
        check_call    "MAX_LOCKUP_DURATION()"                "$first_pool" "MAX_LOCKUP_DURATION()(uint64)" "126144000000000"
        check_call    "MAX_PENDING_BUCKETS()"                "$first_pool" "MAX_PENDING_BUCKETS()(uint256)" "1000"
    else
        skip "StakePool smoke tests: no pool available"
    fi
    echo ""

    echo "--- JWKManager (PR #79) ---"
    # Validation tightening is only observable via setPatches() with an empty
    # field in one of the JWKs — that entrypoint is onlyGenesis and calldata-heavy,
    # so we only assert selector presence on the already-exposed views.
    check_exists  "getProviderCount()"                    "$NATIVE_ORACLE" "getProviderCount()(uint256)"
    check_exists  "getPatches()"                          "$NATIVE_ORACLE" "getPatches()"
    echo ""

    # ── ReentrancyGuard persistence check (inherited from Delta) ──────
    echo "--- ReentrancyGuard (StakePool persistence) ---"
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

        if [ "$rg_all_ok" = true ] && [ "$rg_pool_count" -gt 10 ]; then
            pass "ReentrancyGuard: all ${rg_pool_count} pools have NOT_ENTERED (1)"
        fi
    fi
    echo ""
}
