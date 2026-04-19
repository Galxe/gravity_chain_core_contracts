#!/usr/bin/env bash
# =============================================================================
#  Full local test harness for the mainnet bridge deployment.
#
#  What it does, end to end:
#    1. Starts two anvils:
#         Ethereum-side anvil  : 127.0.0.1:${ETH_PORT}   --chain-id 1     (mimics mainnet)
#         Gravity-side anvil   : 127.0.0.1:${GRAV_PORT}  --chain-id ${GRAV_CHAIN_ID}
#    2. Deploys MockGToken on the Ethereum anvil  (SetupEthereumTestnet.s.sol)
#    3. Etches every Gravity system contract onto the Gravity anvil
#       (etch_gravity_system.sh -> anvil_setCode)
#    4. Runs DeployBridgeMainnet.s.sol against the Ethereum anvil
#       with the just-deployed MockGToken as G_TOKEN_ADDRESS
#    5. Reads the resulting GBridgeSender address from deployments/mainnet.json
#       and deploys GBridgeReceiver on the Gravity anvil (SetupGravityTestnet.s.sol)
#    6. Runs scripts/mainnet/verify_deployment.sh against BOTH anvils
#
#  This exercises exactly the same deploy + verify code path the operator
#  will use against real mainnet — only the RPC URLs and G token differ.
#
#  Usage:
#    ./scripts/testnet/run_full_test.sh
#    CLEAN=0 ./scripts/testnet/run_full_test.sh      # leave anvils running for interactive poking
# =============================================================================
set -euo pipefail

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
die()    { red "ERROR: $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

ETH_PORT="${ETH_PORT:-8545}"
GRAV_PORT="${GRAV_PORT:-8546}"
GRAV_CHAIN_ID="${GRAV_CHAIN_ID:-127001}"

ETH_RPC="http://127.0.0.1:${ETH_PORT}"
GRAV_RPC="http://127.0.0.1:${GRAV_PORT}"

ETH_LOG="${REPO_ROOT}/deployments/.anvil_eth.log"
GRAV_LOG="${REPO_ROOT}/deployments/.anvil_grav.log"
ETH_PID_FILE="${REPO_ROOT}/deployments/.anvil_eth.pid"
GRAV_PID_FILE="${REPO_ROOT}/deployments/.anvil_grav.pid"

# Well-known default anvil account (index 0). Safe: local only.
ANVIL_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266"
ANVIL_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

mkdir -p "${REPO_ROOT}/deployments"

# -- cleanup on exit ----------------------------------------------------------
cleanup() {
    if [[ "${CLEAN:-1}" == "0" ]]; then
        yellow "CLEAN=0: leaving anvils running."
        yellow "  Ethereum anvil : ${ETH_RPC}   (log: ${ETH_LOG})"
        yellow "  Gravity  anvil : ${GRAV_RPC}  (log: ${GRAV_LOG})"
        yellow "  Stop with: ./scripts/testnet/stop_local_env.sh"
        return
    fi
    for pf in "${ETH_PID_FILE}" "${GRAV_PID_FILE}"; do
        if [[ -f "${pf}" ]]; then
            local pid; pid="$(cat "${pf}")"
            if kill -0 "${pid}" 2>/dev/null; then
                kill "${pid}" 2>/dev/null || true
                wait "${pid}" 2>/dev/null || true
            fi
            rm -f "${pf}"
        fi
    done
}
trap cleanup EXIT

# -- prerequisites ------------------------------------------------------------
command -v anvil >/dev/null 2>&1 || die "anvil not found in PATH"
command -v cast  >/dev/null 2>&1 || die "cast not found in PATH"
command -v forge >/dev/null 2>&1 || die "forge not found in PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found in PATH"

# Free the ports if stale anvil is still there.
for port in "${ETH_PORT}" "${GRAV_PORT}"; do
    if lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
        die "port ${port} already in use — run ./scripts/testnet/stop_local_env.sh first"
    fi
done

# -- step 1: launch anvils -----------------------------------------------------
green "[1/6] launching Ethereum anvil on ${ETH_RPC} (chain-id 1)"
anvil --chain-id 1 --port "${ETH_PORT}" --host 127.0.0.1 >"${ETH_LOG}" 2>&1 &
echo $! >"${ETH_PID_FILE}"

green "      launching Gravity anvil  on ${GRAV_RPC} (chain-id ${GRAV_CHAIN_ID})"
anvil --chain-id "${GRAV_CHAIN_ID}" --port "${GRAV_PORT}" --host 127.0.0.1 >"${GRAV_LOG}" 2>&1 &
echo $! >"${GRAV_PID_FILE}"

wait_ready() {
    local rpc="$1" tries=50
    while (( tries-- > 0 )); do
        if cast chain-id --rpc-url "${rpc}" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    return 1
}
wait_ready "${ETH_RPC}"  || die "Ethereum anvil did not come up; see ${ETH_LOG}"
wait_ready "${GRAV_RPC}" || die "Gravity  anvil did not come up; see ${GRAV_LOG}"

ETH_CID="$(cast chain-id --rpc-url "${ETH_RPC}")"
GRAV_CID="$(cast chain-id --rpc-url "${GRAV_RPC}")"
[[ "${ETH_CID}" == "1" ]] || die "Ethereum anvil reports chainId ${ETH_CID}, expected 1"
green "      Ethereum chainId=${ETH_CID}  Gravity chainId=${GRAV_CID}"

# -- step 2: deploy MockGToken on Ethereum anvil ------------------------------
green "[2/6] deploying MockGToken on Ethereum anvil"
DEPLOYER_PRIVATE_KEY="${ANVIL_PK}" \
    forge script scripts/testnet/SetupEthereumTestnet.s.sol:SetupEthereumTestnet \
        --rpc-url "${ETH_RPC}" \
        --private-key "${ANVIL_PK}" \
        --broadcast \
        --silent

G_TOKEN_ADDRESS="$(jq -r .gToken "${REPO_ROOT}/deployments/testnet_ethereum.json")"
[[ -n "${G_TOKEN_ADDRESS}" && "${G_TOKEN_ADDRESS}" != "null" ]] || die "could not read gToken from testnet_ethereum.json"
green "      MockGToken : ${G_TOKEN_ADDRESS}"

# -- step 3: etch Gravity system contracts ------------------------------------
green "[3/6] etching Gravity system contracts onto ${GRAV_RPC}"
GRAVITY_RPC_URL="${GRAV_RPC}" bash "${SCRIPT_DIR}/etch_gravity_system.sh"

# -- step 4: deploy GravityPortal + GBridgeSender on Ethereum anvil -----------
green "[4/6] deploying GravityPortal + GBridgeSender on Ethereum anvil"
GRAVITY_CORE_CONTRACT_EOA_OWNER="${ANVIL_ADDR}" \
GRAVITY_CORE_CONTRACT_EOA_OWNER_PRIVATE_KEY="${ANVIL_PK}" \
G_TOKEN_ADDRESS="${G_TOKEN_ADDRESS}" \
    forge script scripts/mainnet/DeployBridgeMainnet.s.sol:DeployBridgeMainnet \
        --rpc-url "${ETH_RPC}" \
        --private-key "${ANVIL_PK}" \
        --broadcast \
        -vv

GPORTAL="$(jq -r .gravityPortal "${REPO_ROOT}/deployments/mainnet.json")"
GSENDER="$(jq -r .gBridgeSender "${REPO_ROOT}/deployments/mainnet.json")"
[[ -n "${GSENDER}" && "${GSENDER}" != "null" ]] || die "deployments/mainnet.json missing gBridgeSender"
green "      GravityPortal : ${GPORTAL}"
green "      GBridgeSender : ${GSENDER}"

# -- step 5: deploy GBridgeReceiver on Gravity anvil --------------------------
green "[5/6] deploying GBridgeReceiver on Gravity anvil"
DEPLOYER_PRIVATE_KEY="${ANVIL_PK}" \
GBRIDGE_SENDER_ADDRESS="${GSENDER}" \
TRUSTED_SOURCE_CHAIN_ID=1 \
    forge script scripts/testnet/SetupGravityTestnet.s.sol:SetupGravityTestnet \
        --rpc-url "${GRAV_RPC}" \
        --private-key "${ANVIL_PK}" \
        --broadcast \
        -vv

GRECEIVER="$(jq -r .gBridgeReceiver "${REPO_ROOT}/deployments/testnet_gravity.json")"
[[ -n "${GRECEIVER}" && "${GRECEIVER}" != "null" ]] || die "deployments/testnet_gravity.json missing gBridgeReceiver"
green "      GBridgeReceiver : ${GRECEIVER}"

# -- step 6: run the real verifier against both chains ------------------------
green "[6/6] running scripts/mainnet/verify_deployment.sh against both anvils"
MAINNET_RPC_URL="${ETH_RPC}" \
GRAVITY_RPC_URL="${GRAV_RPC}" \
GRAVITY_CORE_CONTRACT_EOA_OWNER="${ANVIL_ADDR}" \
GRAVITY_PORTAL_ADDRESS="${GPORTAL}" \
GBRIDGE_SENDER_ADDRESS="${GSENDER}" \
GBRIDGE_RECEIVER_ADDRESS="${GRECEIVER}" \
G_TOKEN_ADDRESS="${G_TOKEN_ADDRESS}" \
TRUSTED_SOURCE_CHAIN_ID=1 \
    bash "${REPO_ROOT}/scripts/mainnet/verify_deployment.sh"

echo
green "=========================================================="
green "  LOCAL HARNESS: full deploy + verify completed"
green "=========================================================="
echo "  Ethereum anvil   : ${ETH_RPC}"
echo "  Gravity  anvil   : ${GRAV_RPC}"
echo "  MockGToken       : ${G_TOKEN_ADDRESS}"
echo "  GravityPortal    : ${GPORTAL}"
echo "  GBridgeSender    : ${GSENDER}"
echo "  GBridgeReceiver  : ${GRECEIVER}"
