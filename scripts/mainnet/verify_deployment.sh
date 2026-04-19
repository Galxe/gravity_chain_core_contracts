#!/usr/bin/env bash
# =============================================================================
#  Gravity Bridge - Post-Deployment Verifier
# =============================================================================
#  Checks that the contracts on Ethereum mainnet match what we built locally,
#  AND (optionally) that the Gravity chain's system contracts + GBridgeReceiver
#  match their local build + trust our mainnet GBridgeSender.
#
#  Usage:
#      ./scripts/mainnet/verify_deployment.sh            # both sides
#      SKIP_GRAVITY=1 ./scripts/mainnet/verify_deployment.sh   # mainnet only
#      SKIP_MAINNET=1 ./scripts/mainnet/verify_deployment.sh   # Gravity only
#
#  Reads the same .env.mainnet as the deploy script for expected values, plus:
#      GRAVITY_RPC_URL             required for Gravity verification
#      GBRIDGE_RECEIVER_ADDRESS    optional (Gravity side); if unset, skips
#                                  receiver-specific checks but still verifies
#                                  the 0x1625F… system contracts
#
#  The script is READ-ONLY. No tx is sent on either chain.
# =============================================================================
set -euo pipefail

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
die()    { red "ERROR: $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# -- autoload .env.mainnet if present ----------------------------------------
if [[ -f "${REPO_ROOT}/.env.mainnet" ]]; then
    yellow "Loading ${REPO_ROOT}/.env.mainnet"
    set -a
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/.env.mainnet"
    set +a
fi

overall_rc=0

# =============================================================================
# (A) Ethereum mainnet
# =============================================================================
if [[ "${SKIP_MAINNET:-0}" != "1" ]]; then
    green "=== Verifying Ethereum mainnet ==="

    : "${MAINNET_RPC_URL:?MAINNET_RPC_URL is required}"
    : "${GRAVITY_CORE_CONTRACT_EOA_OWNER:?GRAVITY_CORE_CONTRACT_EOA_OWNER is required}"

    CHAIN_HEX="$(cast chain-id --rpc-url "${MAINNET_RPC_URL}" 2>/dev/null || echo "")"
    if [[ "${CHAIN_HEX}" != "1" ]]; then
        die "MAINNET_RPC_URL reports chainId '${CHAIN_HEX}', expected 1"
    fi

    # Addresses come from deployments/mainnet.json by default (written by the
    # deploy script). Allow explicit env override for cases where someone wants
    # to verify an address they did not produce locally.
    if [[ -z "${GRAVITY_PORTAL_ADDRESS:-}" || -z "${GBRIDGE_SENDER_ADDRESS:-}" ]]; then
        ART="${REPO_ROOT}/deployments/mainnet.json"
        if [[ -f "${ART}" ]]; then
            if command -v jq >/dev/null 2>&1; then
                export GRAVITY_PORTAL_ADDRESS="${GRAVITY_PORTAL_ADDRESS:-$(jq -r .gravityPortal "${ART}")}"
                export GBRIDGE_SENDER_ADDRESS="${GBRIDGE_SENDER_ADDRESS:-$(jq -r .gBridgeSender "${ART}")}"
                green "Using addresses from ${ART}:"
                echo "  GravityPortal : ${GRAVITY_PORTAL_ADDRESS}"
                echo "  GBridgeSender : ${GBRIDGE_SENDER_ADDRESS}"
            else
                yellow "jq not installed; the .s.sol script will read deployments/mainnet.json itself"
            fi
        else
            die "deployments/mainnet.json not found and GRAVITY_PORTAL_ADDRESS/GBRIDGE_SENDER_ADDRESS unset"
        fi
    fi

    set +e
    forge script \
        scripts/mainnet/VerifyBridgeMainnet.s.sol:VerifyBridgeMainnet \
        --rpc-url "${MAINNET_RPC_URL}" \
        -vvv
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        red "Ethereum mainnet verification FAILED (rc=$rc)"
        overall_rc=$rc
    else
        green "Ethereum mainnet verification PASSED"
    fi
fi

# =============================================================================
# (B) Gravity chain
# =============================================================================
if [[ "${SKIP_GRAVITY:-0}" != "1" ]]; then
    echo
    green "=== Verifying Gravity chain ==="

    if [[ -z "${GRAVITY_RPC_URL:-}" ]]; then
        yellow "GRAVITY_RPC_URL not set — skipping Gravity-side verification."
        yellow "Set GRAVITY_RPC_URL once Gravity mainnet is live."
    else
        GCHAIN_HEX="$(cast chain-id --rpc-url "${GRAVITY_RPC_URL}" 2>/dev/null || echo "")"
        green "Gravity chainId (from RPC): ${GCHAIN_HEX}"

        # GBridgeReceiver address is optional at this step; the .s.sol handles absence.
        set +e
        forge script \
            scripts/mainnet/VerifyGravityChain.s.sol:VerifyGravityChain \
            --rpc-url "${GRAVITY_RPC_URL}" \
            -vvv
        rc=$?
        set -e
        if [[ $rc -ne 0 ]]; then
            red "Gravity chain verification FAILED (rc=$rc)"
            overall_rc=$rc
        else
            green "Gravity chain verification PASSED"
        fi
    fi
fi

echo
if [[ $overall_rc -eq 0 ]]; then
    green "=========================================================="
    green "  VERIFIER: OK — everything matches"
    green "=========================================================="
else
    red "=========================================================="
    red "  VERIFIER: FAILED — see logs above"
    red "=========================================================="
fi
exit $overall_rc
