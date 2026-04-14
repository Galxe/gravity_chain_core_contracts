#!/usr/bin/env bash
# hardforks/epsilon.sh — Epsilon hardfork verification configuration.
#
# Defines which contracts to verify and the functional smoke tests to run
# for the Epsilon hardfork. Sourced by verify.sh.
#
# Epsilon upgrades (gravity-testnet-v1.3 → v1.4):
#   - PR #56 (D3-2): ValidatorManagement underbonded eviction (Phase 1) +
#     percentage-based performance threshold (Phase 2), skip epoch 1
#   - PR #63: Reconfiguration moves evictUnderperformingValidators() out of
#     _applyReconfiguration and into checkAndStartTransition / governanceReconfigure,
#     fixing DKG synchronization
#   - PR #63: ValidatorConfig autoEvictThreshold(uint256) → __deprecated; new
#     autoEvictThresholdPct(uint64) appended at end of storage
#   - PR #66: GBridgeReceiver _processedNonces mapping replaced with
#     __deprecated_processedNonces gap; isProcessed() and AlreadyProcessed removed
#
# Workflow on a live node:
#   bash scripts/verify_hardfork/generate_hashes.sh epsilon
#   bash scripts/verify_hardfork/verify.sh epsilon https://rpc.testnet.gravity.xyz
#
# Override GBridgeReceiver address for non-testnet environments:
#   GBRIDGE_RECEIVER=0xabc... bash scripts/verify_hardfork/verify.sh epsilon $RPC

HARDFORK_DISPLAY_NAME="Epsilon Hardfork"

# ── System contracts upgraded in this hardfork ────────────────────────
# Format: "ContractName:address"
# These are verified for bytecode hash changes.
#
# NOTE: GBridgeReceiver is intentionally NOT in this list. It has two immutables
# (trustedBridge, trustedSourceId) whose values are deployment-environment-specific,
# so a forge-built deployedBytecode hash will not match the on-chain codehash without
# a per-environment patch. Verification of GBridgeReceiver is handled via functional
# smoke tests in run_smoke_tests below (isProcessed() removal is the canonical signal).
SYSTEM_CONTRACTS=(
    "ValidatorManagement:${VALIDATOR_MANAGER}"
    "Reconfiguration:${RECONFIGURATION}"
    "ValidatorConfig:${VALIDATOR_CONFIG}"
)

# ── StakePool verification ────────────────────────────────────────────
# Epsilon does NOT touch StakePool bytecode.
VERIFY_STAKEPOOL=false

# ── Functional smoke tests ────────────────────────────────────────────
run_smoke_tests() {
    echo "--- ValidatorConfig (PR #63) ---"
    # New getter must exist; old getter must be gone
    check_exists  "autoEvictThresholdPct() exists"        "$VALIDATOR_CONFIG" "autoEvictThresholdPct()(uint64)"
    check_reverts "autoEvictThreshold() removed"          "$VALIDATOR_CONFIG" "autoEvictThreshold()(uint256)"
    # Sanity: existing getters still work
    check_exists  "autoEvictEnabled()"                    "$VALIDATOR_CONFIG" "autoEvictEnabled()(bool)"
    check_exists  "minimumBond()"                         "$VALIDATOR_CONFIG" "minimumBond()(uint256)"
    check_exists  "isInitialized()"                       "$VALIDATOR_CONFIG" "isInitialized()(bool)"
    # Pre-hardfork hygiene: there should be no pending config straddling the upgrade,
    # because the PendingConfig struct layout changed (new __deprecated + uint64 fields).
    check_call    "hasPendingConfig() is false"           "$VALIDATOR_CONFIG" "hasPendingConfig()(bool)" "false"
    echo ""

    echo "--- ValidatorManagement (PR #56) ---"
    # No new public getters; codehash check is the primary signal. The function
    # signature itself must still resolve so its selector is in the dispatcher.
    # evictUnderperformingValidators() requires caller == Reconfiguration (requireAllowed),
    # so we use --from to impersonate the allowed caller; the call may still revert
    # due to state (e.g. epoch <= 1), but a NotAllowed revert means the selector exists.
    check_exists  "evictUnderperformingValidators() ABI"  "$VALIDATOR_MANAGER" "evictUnderperformingValidators()" --from "$RECONFIGURATION"
    check_exists  "getActiveValidatorCount()"             "$VALIDATOR_MANAGER" "getActiveValidatorCount()(uint256)"
    echo ""

    echo "--- Reconfiguration (PR #63) ---"
    # Call sites moved but ABI unchanged; ensure dispatcher still has both entry points.
    # checkAndStartTransition() requires caller == Blocker; governanceReconfigure() requires
    # caller == Governance. Use --from to satisfy requireAllowed access control.
    check_exists  "currentEpoch()"                        "$RECONFIGURATION" "currentEpoch()(uint64)"
    check_exists  "checkAndStartTransition() ABI"         "$RECONFIGURATION" "checkAndStartTransition()" --from "$BLOCKER"
    check_exists  "governanceReconfigure() ABI"           "$RECONFIGURATION" "governanceReconfigure()" --from "$GOVERNANCE"
    echo ""

    echo "--- GBridgeReceiver (PR #66) ---"
    # isProcessed() removed — selector should not be in the dispatcher
    check_reverts "isProcessed() removed"                 "$GBRIDGE_RECEIVER" "isProcessed(uint128)(bool)" 1
    # Surviving view methods must still resolve
    check_exists  "trustedBridge()"                       "$GBRIDGE_RECEIVER" "trustedBridge()(address)"
    check_exists  "trustedSourceId()"                     "$GBRIDGE_RECEIVER" "trustedSourceId()(uint256)"
    echo ""
}
