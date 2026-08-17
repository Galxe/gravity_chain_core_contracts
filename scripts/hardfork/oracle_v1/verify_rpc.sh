#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/artifacts/manifest.json"
RPC_URL="${1:-}"
PHASE="${2:-post}"
CAST_BIN="${CAST_BIN:-cast}"

if [[ -z "${RPC_URL}" || ( "${PHASE}" != "pre" && "${PHASE}" != "post" ) ]]; then
    echo "Usage: $0 <rpc-url> [pre|post]" >&2
    exit 1
fi

for command in "${CAST_BIN}" jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done

expected_chain_id="$(jq -r '.chainId' "${MANIFEST}")"
actual_chain_id="$("${CAST_BIN}" chain-id --rpc-url "${RPC_URL}")"
if [[ "${actual_chain_id}" != "${expected_chain_id}" ]]; then
    echo "Unexpected chain id: expected ${expected_chain_id}, got ${actual_chain_id}" >&2
    exit 1
fi

hash_field="preForkCodeHash"
if [[ "${PHASE}" == "post" ]]; then
    hash_field="postForkCodeHash"
fi

while IFS=$'\t' read -r name address expected_hash; do
    actual_hash="$("${CAST_BIN}" codehash "${address}" --rpc-url "${RPC_URL}")"
    if [[ "${actual_hash,,}" != "${expected_hash,,}" ]]; then
        echo "${name}: expected ${expected_hash}, got ${actual_hash}" >&2
        exit 1
    fi
    echo "${name}: ${actual_hash}"
done < <(jq -r --arg field "${hash_field}" '.contracts[] | [.name, .address, .[$field]] | @tsv' "${MANIFEST}")

echo "OracleV1 ${PHASE}-fork RPC verification passed."
