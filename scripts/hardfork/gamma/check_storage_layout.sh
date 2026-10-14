#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FORGE_BIN="${FORGE_BIN:-forge}"

for command in "${FORGE_BIN}" jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done

assert_slot() {
    local contract="$1"
    local layout="$2"
    local label="$3"
    local expected_slot="$4"
    local expected_offset="$5"
    local actual

    actual="$(jq -r --arg field_name "${label}" '.storage[] | select(.label == $field_name) | "\(.slot):\(.offset)"' <<< "${layout}")"
    if [[ "${actual}" != "${expected_slot}:${expected_offset}" ]]; then
        echo "${contract}.${label}: expected slot ${expected_slot} offset ${expected_offset}, got ${actual:-missing}" >&2
        exit 1
    fi
}

native_layout="$(cd "${REPO_ROOT}" && "${FORGE_BIN}" inspect NativeOracle storageLayout --json)"
assert_slot NativeOracle "${native_layout}" _records 0 0
assert_slot NativeOracle "${native_layout}" _nonces 1 0
assert_slot NativeOracle "${native_layout}" _defaultCallbacks 2 0
assert_slot NativeOracle "${native_layout}" _callbacks 3 0
assert_slot NativeOracle "${native_layout}" _initialized 4 0
assert_slot NativeOracle "${native_layout}" _sourceProgress 5 0

task_config_layout="$(cd "${REPO_ROOT}" && "${FORGE_BIN}" inspect OracleTaskConfig storageLayout --json)"
assert_slot OracleTaskConfig "${task_config_layout}" _taskNames 0 0
assert_slot OracleTaskConfig "${task_config_layout}" _tasks 1 0
assert_slot OracleTaskConfig "${task_config_layout}" _registeredSourceTypes 2 0
assert_slot OracleTaskConfig "${task_config_layout}" _registeredSourceIds 4 0
assert_slot OracleTaskConfig "${task_config_layout}" priceFeedConfigHash 5 0

echo "Gamma storage layout guard passed."
