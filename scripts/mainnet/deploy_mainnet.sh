#!/usr/bin/env bash
# =============================================================================
#  Gravity Bridge - Ethereum Mainnet Deploy + Verify
# =============================================================================
#  One command:  ./scripts/mainnet/deploy_mainnet.sh
#
#  What this does:
#    1. Validates env vars (fails fast on missing values).
#    2. Runs `forge script` with --broadcast --verify against Etherscan.
#    3. Both contracts (GravityPortal, GBridgeSender) are deployed and
#       source-code-verified in a single run.
#    4. Prints deployed addresses and writes ./deployments/mainnet.json.
#
#  Prerequisites (env):
#    GRAVITY_CORE_CONTRACT_EOA_OWNER          (address)  required
#    GRAVITY_CORE_CONTRACT_EOA_OWNER_PRIVATE_KEY (hex)    required (SECRET)
#    MAINNET_RPC_URL                          (url)      required
#    ETHERSCAN_API_KEY                        (string)   required (for --verify)
#
#  Optional overrides (all have sensible defaults inside the .s.sol):
#    G_TOKEN_ADDRESS            default: 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649
#    ETH_PRICE_USD              default: 2500
#    USD_CENTS_PER_32_BYTES     default: 10     (i.e. $0.10 per 32 B)
#    BASE_FEE_WEI               default: 0
# =============================================================================
set -euo pipefail

# -- helpers ------------------------------------------------------------------
red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
die()    { red "ERROR: $*"; exit 1; }

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        die "environment variable '$name' is not set"
    fi
}

# -- locate repo root ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# -- optional dotenv autoload -------------------------------------------------
# If .env.mainnet exists at repo root, load it. CI can skip by not having one.
if [[ -f "${REPO_ROOT}/.env.mainnet" ]]; then
    yellow "Loading ${REPO_ROOT}/.env.mainnet"
    # shellcheck disable=SC1091
    set -a
    . "${REPO_ROOT}/.env.mainnet"
    set +a
fi

# -- validate -----------------------------------------------------------------
require_var GRAVITY_CORE_CONTRACT_EOA_OWNER
require_var GRAVITY_CORE_CONTRACT_EOA_OWNER_PRIVATE_KEY
require_var MAINNET_RPC_URL
require_var ETHERSCAN_API_KEY

# Quick sanity on RPC: must report chainId 0x1 (mainnet).
CHAIN_HEX="$(cast chain-id --rpc-url "${MAINNET_RPC_URL}" 2>/dev/null || echo "")"
if [[ "${CHAIN_HEX}" != "1" ]]; then
    die "MAINNET_RPC_URL does not point at chainId 1 (got: '${CHAIN_HEX}'). Refusing to proceed."
fi

# Confirm deployer has non-zero balance for gas.
DEPLOYER_ADDR="${GRAVITY_CORE_CONTRACT_EOA_OWNER}"
BAL_WEI="$(cast balance "${DEPLOYER_ADDR}" --rpc-url "${MAINNET_RPC_URL}")"
if [[ "${BAL_WEI}" == "0" ]]; then
    die "Deployer ${DEPLOYER_ADDR} has zero ETH on mainnet. Fund it before deploying."
fi
green "Deployer balance: ${BAL_WEI} wei"

# -- banner -------------------------------------------------------------------
cat <<EOF
=============================================================
  Gravity Bridge Mainnet Deploy
-------------------------------------------------------------
  Owner EOA      : ${GRAVITY_CORE_CONTRACT_EOA_OWNER}
  G token        : ${G_TOKEN_ADDRESS:-0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649}
  ETH price USD  : ${ETH_PRICE_USD:-2500}
  cents / 32 B   : ${USD_CENTS_PER_32_BYTES:-10}
  baseFee wei    : ${BASE_FEE_WEI:-0}
  RPC            : ${MAINNET_RPC_URL}
=============================================================
EOF

# -- final human confirmation (skip with FORCE_DEPLOY=1) ----------------------
if [[ "${FORCE_DEPLOY:-0}" != "1" ]]; then
    read -r -p "Type 'DEPLOY MAINNET' to continue: " confirm
    if [[ "${confirm}" != "DEPLOY MAINNET" ]]; then
        die "aborted by user"
    fi
fi

# -- run forge script ---------------------------------------------------------
# PRIVATE_KEY is read by forge's --private-key (and, redundantly, by our
# script via vm.envUint) so the key only lives in memory for this process.
# --verify + --etherscan-api-key verifies both contracts in the same run.
mkdir -p "${REPO_ROOT}/deployments"

green "Running forge script (broadcast + verify)..."
forge script \
    scripts/mainnet/DeployBridgeMainnet.s.sol:DeployBridgeMainnet \
    --rpc-url "${MAINNET_RPC_URL}" \
    --private-key "${GRAVITY_CORE_CONTRACT_EOA_OWNER_PRIVATE_KEY}" \
    --broadcast \
    --verify \
    --etherscan-api-key "${ETHERSCAN_API_KEY}" \
    --slow \
    -vvv

# -- surface the artifact -----------------------------------------------------
ARTIFACT="${REPO_ROOT}/deployments/mainnet.json"
if [[ -f "${ARTIFACT}" ]]; then
    green "Deployment artifact:"
    cat "${ARTIFACT}"
    echo
else
    yellow "No artifact at ${ARTIFACT} (the broadcast may have failed silently; check logs)."
fi

green "Done."
