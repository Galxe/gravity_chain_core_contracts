#!/usr/bin/env bash
# Modular localhost harness for the validator-judged LLMBattle POC.
#
# Usage:
#   ./scripts/llm-battle/run_local_demo.sh all      # start + deploy + play (default)
#   ./scripts/llm-battle/run_local_demo.sh start
#   ./scripts/llm-battle/run_local_demo.sh deploy
#   ./scripts/llm-battle/run_local_demo.sh play
#   ./scripts/llm-battle/run_local_demo.sh stop
set -euo pipefail

red() { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
die() { red "ERROR: $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

ACTION="${1:-all}"
LLM_BATTLE_PORT="${LLM_BATTLE_PORT:-8547}"
LLM_BATTLE_CHAIN_ID="${LLM_BATTLE_CHAIN_ID:-31337}"
LLM_BATTLE_KEEP_ANVIL="${LLM_BATTLE_KEEP_ANVIL:-1}"
LLM_BATTLE_RPC_URL="http://127.0.0.1:${LLM_BATTLE_PORT}"
LLM_BATTLE_MNEMONIC="${LLM_BATTLE_MNEMONIC:-test test test test test test test test test test test junk}"

FOUNDRY_DIR="${LLM_BATTLE_FOUNDRY_DIR:-/home/jingyue/.foundry/bin}"
FORGE="${FORGE:-${FOUNDRY_DIR}/forge}"
CAST="${CAST:-${FOUNDRY_DIR}/cast}"
ANVIL="${ANVIL:-${FOUNDRY_DIR}/anvil}"

ARTIFACT_DIR="${REPO_ROOT}/deployments/llm-battle"
DEPLOYMENT_FILE="${ARTIFACT_DIR}/local-deployment.json"
BATTLE_FILE="${ARTIFACT_DIR}/local-battle.json"
RESULT_FILE="${ARTIFACT_DIR}/local-result.json"
PID_FILE="${ARTIFACT_DIR}/local-anvil.pid"
LOG_FILE="${ARTIFACT_DIR}/local-anvil.log"

mkdir -p "${ARTIFACT_DIR}"

[[ -x "${FORGE}" ]] || die "forge not found at ${FORGE}"
[[ -x "${CAST}" ]] || die "cast not found at ${CAST}"
[[ -x "${ANVIL}" ]] || die "anvil not found at ${ANVIL}"
command -v jq >/dev/null 2>&1 || die "jq is required"

derive_key() {
    "${CAST}" wallet private-key "${LLM_BATTLE_MNEMONIC}" "$1"
}

# Eleven distinct, funded Anvil actors: deployer, sponsor, five debaters, and four validator voters.
LLM_BATTLE_DEPLOYER_KEY="${LLM_BATTLE_DEPLOYER_KEY:-$(derive_key 0)}"
LLM_BATTLE_SPONSOR_KEY="${LLM_BATTLE_SPONSOR_KEY:-$(derive_key 1)}"
if [[ -z "${LLM_BATTLE_TEAM_A_KEYS:-}" ]]; then
    LLM_BATTLE_TEAM_A_KEYS="$(derive_key 2),$(derive_key 3)"
fi
if [[ -z "${LLM_BATTLE_TEAM_B_KEYS:-}" ]]; then
    LLM_BATTLE_TEAM_B_KEYS="$(derive_key 4),$(derive_key 5),$(derive_key 6)"
fi
if [[ -z "${LLM_BATTLE_VALIDATOR_KEYS:-}" ]]; then
    LLM_BATTLE_VALIDATOR_KEYS="$(derive_key 7),$(derive_key 8),$(derive_key 9),$(derive_key 10)"
fi

export LLM_BATTLE_DEPLOYER_KEY
export LLM_BATTLE_SPONSOR_KEY
export LLM_BATTLE_TEAM_A_KEYS
export LLM_BATTLE_TEAM_B_KEYS
export LLM_BATTLE_VALIDATOR_KEYS
export LLM_BATTLE_DEPLOYMENT_FILE="${DEPLOYMENT_FILE}"
export LLM_BATTLE_STATE_FILE="${BATTLE_FILE}"
export LLM_BATTLE_RESULT_FILE="${RESULT_FILE}"

STARTED_HERE=0

rpc_ready() {
    "${CAST}" chain-id --rpc-url "${LLM_BATTLE_RPC_URL}" >/dev/null 2>&1
}

read_pid() {
    [[ -f "${PID_FILE}" ]] || return 1
    local pid
    pid="$(<"${PID_FILE}")"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    kill -0 "${pid}" 2>/dev/null || return 1
    printf "%s" "${pid}"
}

is_managed_anvil() {
    local pid command_line
    pid="$(read_pid)" || return 1
    command_line="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
    [[ "${command_line}" == *"anvil"* && "${command_line}" == *"--port ${LLM_BATTLE_PORT}"* ]]
}

start_anvil() {
    if rpc_ready; then
        is_managed_anvil || die "${LLM_BATTLE_RPC_URL} is already in use by an unmanaged process"
        yellow "Reusing managed LLMBattle Anvil at ${LLM_BATTLE_RPC_URL}"
        return
    fi

    if [[ -f "${PID_FILE}" ]]; then
        rm -f "${PID_FILE}"
    fi

    green "Starting isolated Anvil at ${LLM_BATTLE_RPC_URL} (chain ${LLM_BATTLE_CHAIN_ID})"
    nohup "${ANVIL}" \
        --host 127.0.0.1 \
        --port "${LLM_BATTLE_PORT}" \
        --chain-id "${LLM_BATTLE_CHAIN_ID}" \
        --accounts 12 \
        --balance 10000 \
        --mnemonic "${LLM_BATTLE_MNEMONIC}" \
        >"${LOG_FILE}" 2>&1 &
    local pid=$!
    printf "%s\n" "${pid}" >"${PID_FILE}"
    STARTED_HERE=1

    local tries=50
    while (( tries-- > 0 )); do
        if rpc_ready; then
            local actual_chain_id
            actual_chain_id="$("${CAST}" chain-id --rpc-url "${LLM_BATTLE_RPC_URL}")"
            [[ "${actual_chain_id}" == "${LLM_BATTLE_CHAIN_ID}" ]] \
                || die "Anvil chain ID ${actual_chain_id}, expected ${LLM_BATTLE_CHAIN_ID}"
            green "Anvil is ready (pid ${pid})"
            return
        fi
        sleep 0.1
    done
    die "Anvil did not become ready; inspect ${LOG_FILE}"
}

stop_anvil() {
    if ! is_managed_anvil; then
        rm -f "${PID_FILE}"
        yellow "No managed LLMBattle Anvil is running"
        return
    fi

    local pid
    pid="$(read_pid)"
    green "Stopping managed LLMBattle Anvil (pid ${pid})"
    kill "${pid}"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill -9 "${pid}"
    fi
    rm -f "${PID_FILE}"
}

require_rpc() {
    rpc_ready || die "Anvil is not running; use '$0 start' first"
}

run_script() {
    local target="$1"
    "${FORGE}" script "${target}" \
        --rpc-url "${LLM_BATTLE_RPC_URL}" \
        --broadcast \
        -vv
}

deploy_demo() {
    require_rpc
    rm -f "${BATTLE_FILE}" "${RESULT_FILE}"

    green "Deploying modular local validator, staking, and LLMBattle contracts"
    run_script "script/debate/01_DeployLLMBattleLocal.s.sol:DeployLLMBattleLocal"

    [[ -f "${DEPLOYMENT_FILE}" ]] || die "deployment artifact was not written"
    local llm_battle code
    llm_battle="$(jq -r '.llmBattle' "${DEPLOYMENT_FILE}")"
    code="$("${CAST}" code "${llm_battle}" --rpc-url "${LLM_BATTLE_RPC_URL}")"
    [[ "${code}" != "0x" ]] || die "LLMBattle has no code at ${llm_battle}"
    green "LLMBattle deployed at ${llm_battle}"
}

play_battle() {
    require_rpc
    [[ -f "${DEPLOYMENT_FILE}" ]] || die "missing ${DEPLOYMENT_FILE}; run '$0 deploy' first"
    rm -f "${BATTLE_FILE}" "${RESULT_FILE}"

    green "Creating, funding, filling, and locking a team battle"
    run_script "script/debate/02_CreateLLMBattleLocal.s.sol:CreateLLMBattleLocal"

    green "Collecting hidden commitments from validator voters"
    run_script "script/debate/03_CommitLLMBattleVotes.s.sol:CommitLLMBattleVotes"

    local llm_battle commit_window
    llm_battle="$(jq -r '.llmBattle' "${DEPLOYMENT_FILE}")"
    commit_window="$("${CAST}" call "${llm_battle}" 'COMMIT_WINDOW()(uint64)' --rpc-url "${LLM_BATTLE_RPC_URL}")"
    # Newer cast versions append a human-readable suffix, e.g. `86400 [8.64e4]`.
    commit_window="${commit_window%% *}"
    [[ "${commit_window}" =~ ^[0-9]+$ ]] || die "invalid COMMIT_WINDOW value: ${commit_window}"
    green "Advancing local chain by $((commit_window + 2)) seconds into reveal phase"
    "${CAST}" rpc --rpc-url "${LLM_BATTLE_RPC_URL}" evm_increaseTime "$((commit_window + 2))" >/dev/null
    "${CAST}" rpc --rpc-url "${LLM_BATTLE_RPC_URL}" evm_mine >/dev/null

    green "Revealing votes, resolving the battle, and withdrawing payouts"
    run_script "script/debate/04_RevealResolveLLMBattle.s.sol:RevealResolveLLMBattle"

    [[ -f "${RESULT_FILE}" ]] || die "result artifact was not written"
    local balance
    balance="$(jq -r '.contractBalanceWei' "${RESULT_FILE}")"
    [[ "${balance}" == "0" ]] || die "battle escrow still holds ${balance} wei"

    local battle_id question outcome votes_a votes_b juror_reward
    battle_id="$(jq -r '.battleId' "${RESULT_FILE}")"
    question="$(jq -r '.question' "${BATTLE_FILE}")"
    outcome="$(jq -r '.outcome' "${RESULT_FILE}")"
    votes_a="$(jq -r '.votesA' "${RESULT_FILE}")"
    votes_b="$(jq -r '.votesB' "${RESULT_FILE}")"
    juror_reward="$(jq -r '.jurorRewardPerVoteWei' "${RESULT_FILE}")"
    local team_a_size team_b_size
    team_a_size="$(jq -r '.teamA | length' "${BATTLE_FILE}")"
    team_b_size="$(jq -r '.teamB | length' "${BATTLE_FILE}")"

    green "Local battle complete"
    printf "  Battle ID            : %s\n" "${battle_id}"
    printf "  Question             : %s\n" "${question}"
    printf "  Teams                : %sv%s debaters\n" "${team_a_size}" "${team_b_size}"
    printf "  Outcome              : %s (%s-%s)\n" "${outcome}" "${votes_a}" "${votes_b}"
    printf "  Juror reward / reveal: %s wei\n" "${juror_reward}"
    printf "  Escrow remaining     : 0 wei\n"
    printf "  Deployment artifact  : %s\n" "${DEPLOYMENT_FILE}"
    printf "  Battle artifact      : %s\n" "${BATTLE_FILE}"
    printf "  Result artifact      : %s\n" "${RESULT_FILE}"
}

cleanup_on_exit() {
    local exit_code=$?
    if (( exit_code != 0 )) && (( STARTED_HERE == 1 )); then
        stop_anvil || true
    elif [[ "${ACTION}" == "all" && "${LLM_BATTLE_KEEP_ANVIL}" == "0" && "${STARTED_HERE}" == "1" ]]; then
        stop_anvil
    fi
}
trap cleanup_on_exit EXIT

case "${ACTION}" in
    all)
        start_anvil
        deploy_demo
        play_battle
        if [[ "${LLM_BATTLE_KEEP_ANVIL}" == "1" ]]; then
            yellow "Anvil remains available at ${LLM_BATTLE_RPC_URL}"
            yellow "Play another topic with: $0 play"
            yellow "Stop it with: $0 stop"
        fi
        ;;
    start)
        start_anvil
        ;;
    deploy)
        deploy_demo
        ;;
    play)
        play_battle
        ;;
    stop)
        stop_anvil
        ;;
    *)
        die "unknown action '${ACTION}'; expected all, start, deploy, play, or stop"
        ;;
esac
