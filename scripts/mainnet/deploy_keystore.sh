#!/usr/bin/env bash
# =============================================================================
#  Gravity Bridge - Ethereum Mainnet Deploy + Verify  (encrypted keystore)
# =============================================================================
#  One command:  ./scripts/mainnet/deploy_keystore.sh
#
#  Counterpart to deploy_mainnet.sh, but signs with an ENCRYPTED FOUNDRY
#  KEYSTORE (`forge`/`cast` --account) instead of a plaintext private key.
#  No private key ever touches the environment, the shell history, or disk
#  in cleartext.
#
#  What this does:
#    1. Validates env vars (fails fast on missing values).
#    2. Sanity-checks the RPC (chainId 1) and the deployer balance.
#    3. Runs DeployBridgeKeystore.s.sol with --account/--sender, --broadcast,
#       and --verify. GravityPortal + GBridgeSender are deployed via the
#       canonical CreateX factory (CREATE3) at deterministic addresses,
#       ownership of both is transferred to the multisig (Ownable2Step,
#       pending), and both are source-verified on Etherscan in the same run.
#    4. Prints deployed addresses and writes ./deployments/mainnet.json.
#
#  After this script: the multisig must call acceptOwnership() on BOTH
#  contracts. See docs/mainnet/ETH-CONTRACTS-AUDIT-AND-DEPLOY-GUIDE.md §5.9.
#
#  Prerequisites (env — put them in .env.mainnet, auto-loaded below):
#    KEYSTORE_ACCOUNT    (string)  required  forge keystore name
#                                            (`cast wallet import <name> ...`)
#    DEPLOYER_ADDRESS    (address) required  the keystore EOA address
#    MAINNET_RPC_URL     (url)     required  must report chainId 1
#    ETHERSCAN_API_KEY   (string)  required  for --verify
#
#  Optional overrides (sensible defaults baked into DeployBridgeKeystore.s.sol):
#    MULTISIG_ADDRESS         default: verified production Safe (see the .s.sol)
#    FEE_RECIPIENT_ADDRESS    default: MULTISIG_ADDRESS
#    G_TOKEN_ADDRESS          default: 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649
#    BASE_FEE_WEI             default: 50_000_000_000_000   (≈ $0.10 at ETH = $2000)
#    FEE_PER_BYTE_WEI         default: 2_343_750_000_000    (≈ $0.15 / 32 B at ETH = $2000)
#
#  Modes:
#    DRY_RUN=1   simulate against a fork of MAINNET_RPC_URL — no broadcast,
#                no verify, no password prompt. Always do this first.
#    FORCE_DEPLOY=1   skip the interactive "DEPLOY MAINNET" confirmation.
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
if [[ -f "${REPO_ROOT}/.env.mainnet" ]]; then
    yellow "Loading ${REPO_ROOT}/.env.mainnet"
    set -a
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/.env.mainnet"
    set +a
fi

DRY_RUN="${DRY_RUN:-0}"

# -- validate -----------------------------------------------------------------
require_var DEPLOYER_ADDRESS
require_var MAINNET_RPC_URL
if [[ "${DRY_RUN}" != "1" ]]; then
    require_var KEYSTORE_ACCOUNT
    require_var ETHERSCAN_API_KEY
fi

# Quick sanity on RPC: must report chainId 1 (mainnet) — also true for a fork.
CHAIN_ID="$(cast chain-id --rpc-url "${MAINNET_RPC_URL}" 2>/dev/null || echo "")"
if [[ "${CHAIN_ID}" != "1" ]]; then
    die "MAINNET_RPC_URL does not report chainId 1 (got: '${CHAIN_ID}'). Refusing to proceed."
fi

# Confirm the deployer EOA has gas (skipped for dry-run; a fork can mint balance).
if [[ "${DRY_RUN}" != "1" ]]; then
    BAL_WEI="$(cast balance "${DEPLOYER_ADDRESS}" --rpc-url "${MAINNET_RPC_URL}")"
    if [[ "${BAL_WEI}" == "0" ]]; then
        die "Deployer ${DEPLOYER_ADDRESS} has zero ETH on mainnet. Fund it (~0.2 ETH) before deploying."
    fi
    green "Deployer balance: ${BAL_WEI} wei"
fi

# -- banner -------------------------------------------------------------------
cat <<EOF
=============================================================
  Gravity Bridge Mainnet Deploy (keystore + CreateX/CREATE3)
-------------------------------------------------------------
  Mode           : $([[ "${DRY_RUN}" == "1" ]] && echo "DRY RUN (simulate, no broadcast)" || echo "LIVE (broadcast + verify)")
  Keystore acct  : ${KEYSTORE_ACCOUNT:-<n/a for dry-run>}
  Deployer EOA   : ${DEPLOYER_ADDRESS}
  Multisig owner : ${MULTISIG_ADDRESS:-0xbD6e434dB90FD8AD4E28d85C133AD34cA6fbfB6D (script default)}
  Fee recipient  : ${FEE_RECIPIENT_ADDRESS:-<defaults to multisig>}
  G token        : ${G_TOKEN_ADDRESS:-0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649}
  baseFee wei    : ${BASE_FEE_WEI:-50000000000000   (≈ \$0.10 at ETH = \$2000)}
  feePerByte wei : ${FEE_PER_BYTE_WEI:-2343750000000  (≈ \$0.15 / 32 B at ETH = \$2000)}
  CreateX        : 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed (canonical)
  RPC            : ${MAINNET_RPC_URL}
=============================================================
EOF

# -- run forge script ---------------------------------------------------------
SCRIPT_TARGET="scripts/mainnet/DeployBridgeKeystore.s.sol:DeployBridgeKeystore"

if [[ "${DRY_RUN}" == "1" ]]; then
    green "Simulating against a fork of mainnet (no broadcast, no signing)..."
    # No --account: a simulation does not sign. --sender is enough for
    # vm.startBroadcast(address) to resolve the deployer.
    forge script "${SCRIPT_TARGET}" \
        --rpc-url "${MAINNET_RPC_URL}" \
        --sender "${DEPLOYER_ADDRESS}" \
        -vvvv
    green "Dry run complete. No transactions were broadcast."
    exit 0
fi

# -- final human confirmation (skip with FORCE_DEPLOY=1) ----------------------
if [[ "${FORCE_DEPLOY:-0}" != "1" ]]; then
    read -r -p "Type 'DEPLOY MAINNET' to broadcast: " confirm
    if [[ "${confirm}" != "DEPLOY MAINNET" ]]; then
        die "aborted by user"
    fi
fi

mkdir -p "${REPO_ROOT}/deployments"

green "Running forge script (broadcast + verify)..."
# --account decrypts the keystore in-process (you will be prompted for the
# password once). --sender must match the keystore address. --slow sends the
# 4 txs one at a time, waiting for each receipt.
forge script "${SCRIPT_TARGET}" \
    --rpc-url "${MAINNET_RPC_URL}" \
    --account "${KEYSTORE_ACCOUNT}" \
    --sender "${DEPLOYER_ADDRESS}" \
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
    yellow "No artifact at ${ARTIFACT} (the broadcast may have failed; check logs)."
fi

green "Done. NEXT: the multisig must call acceptOwnership() on BOTH contracts."
green "Then run: forge script scripts/mainnet/VerifyBridgeMainnet.s.sol --rpc-url \$MAINNET_RPC_URL -vvv"
