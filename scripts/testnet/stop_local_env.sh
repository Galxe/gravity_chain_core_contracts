#!/usr/bin/env bash
# =============================================================================
#  Stop the local testnet anvils spawned by run_full_test.sh (CLEAN=0 case).
#
#  Prefers the pid files written by run_full_test.sh; falls back to
#  `lsof` on the known ports for stragglers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ETH_PORT="${ETH_PORT:-8545}"
GRAV_PORT="${GRAV_PORT:-8546}"
ETH_PID_FILE="${REPO_ROOT}/deployments/.anvil_eth.pid"
GRAV_PID_FILE="${REPO_ROOT}/deployments/.anvil_grav.pid"

kill_pid_file() {
    local pf="$1" name="$2"
    if [[ -f "${pf}" ]]; then
        local pid; pid="$(cat "${pf}")"
        if kill -0 "${pid}" 2>/dev/null; then
            echo "stopping ${name} (pid ${pid})"
            kill "${pid}" 2>/dev/null || true
            # give it a moment, then SIGKILL if still alive
            for _ in 1 2 3 4 5; do
                kill -0 "${pid}" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
        fi
        rm -f "${pf}"
    fi
}

kill_port() {
    local port="$1" name="$2"
    if command -v lsof >/dev/null 2>&1; then
        local pids; pids="$(lsof -ti ":${port}" -sTCP:LISTEN 2>/dev/null || true)"
        if [[ -n "${pids}" ]]; then
            echo "stopping stray listener on ${port} (${name}): ${pids}"
            # shellcheck disable=SC2086
            kill ${pids} 2>/dev/null || true
        fi
    fi
}

kill_pid_file "${ETH_PID_FILE}"  "ethereum-anvil"
kill_pid_file "${GRAV_PID_FILE}" "gravity-anvil"
kill_port "${ETH_PORT}"  "ethereum-anvil"
kill_port "${GRAV_PORT}" "gravity-anvil"

echo "local testnet env stopped."
