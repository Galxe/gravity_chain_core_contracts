#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/artifacts"
MODE="${1:-write}"

FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"

if [[ "${MODE}" != "write" && "${MODE}" != "--check" ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 1
fi

for command in "${FORGE_BIN}" "${CAST_BIN}" git jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done

generate_into() {
    local output_dir="$1"
    local source_tree native_bytecode task_config_bytecode
    local native_hash task_config_hash native_size task_config_size

    mkdir -p "${output_dir}"

    (
        cd "${REPO_ROOT}"
        "${FORGE_BIN}" build --quiet src/oracle/NativeOracle.sol src/oracle/OracleTaskConfig.sol
    )

    native_bytecode="$(cd "${REPO_ROOT}" && "${FORGE_BIN}" inspect NativeOracle deployedBytecode)"
    task_config_bytecode="$(cd "${REPO_ROOT}" && "${FORGE_BIN}" inspect OracleTaskConfig deployedBytecode)"

    for bytecode in "${native_bytecode}" "${task_config_bytecode}"; do
        if [[ ! "${bytecode}" =~ ^0x[0-9a-fA-F]+$ ]] || (( (${#bytecode} - 2) % 2 != 0 )); then
            echo "Foundry returned invalid deployed bytecode" >&2
            exit 1
        fi
    done

    native_hash="$("${CAST_BIN}" keccak "${native_bytecode}")"
    task_config_hash="$("${CAST_BIN}" keccak "${task_config_bytecode}")"
    native_size="$(((${#native_bytecode} - 2) / 2))"
    task_config_size="$(((${#task_config_bytecode} - 2) / 2))"
    source_tree="$(cd "${REPO_ROOT}" && git rev-parse HEAD:src)"

    printf '%s\n' "${native_bytecode}" > "${output_dir}/NativeOracle.hex"
    printf '%s\n' "${task_config_bytecode}" > "${output_dir}/OracleTaskConfig.hex"

    jq -n \
        --arg source_tree "${source_tree}" \
        --arg native_hash "${native_hash}" \
        --argjson native_size "${native_size}" \
        --arg task_config_hash "${task_config_hash}" \
        --argjson task_config_size "${task_config_size}" \
        '{
            schemaVersion: 1,
            hardfork: "Gamma",
            chainId: 7771625,
            contractsSourceTree: $source_tree,
            build: {
                solc: "0.8.30",
                optimizer: true,
                optimizerRuns: 200,
                viaIr: true,
                bytecodeHash: "none"
            },
            contracts: [
                {
                    name: "NativeOracle",
                    address: "0x00000000000000000000000000000001625F4000",
                    artifact: "src/oracle/NativeOracle.sol:NativeOracle",
                    runtimeFile: "NativeOracle.hex",
                    preForkCodeHash: "0x30dd3888ce26735c0d6c5a036b48a1de668dd5506efa7588ce450f976da28255",
                    postForkCodeHash: $native_hash,
                    runtimeSize: $native_size
                },
                {
                    name: "OracleTaskConfig",
                    address: "0x00000000000000000000000000000001625F1009",
                    artifact: "src/oracle/OracleTaskConfig.sol:OracleTaskConfig",
                    runtimeFile: "OracleTaskConfig.hex",
                    preForkCodeHash: "0x74127baf705119810746598b2695ff5fa38f94bd778f0edae46799ffd3606bda",
                    postForkCodeHash: $task_config_hash,
                    runtimeSize: $task_config_size
                }
            ]
        }' > "${output_dir}/manifest.json"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
generate_into "${tmp_dir}"

if [[ "${MODE}" == "--check" ]]; then
    diff --recursive --unified "${ARTIFACT_DIR}" "${tmp_dir}"
    echo "Gamma artifacts are reproducible."
else
    mkdir -p "${ARTIFACT_DIR}"
    cp "${tmp_dir}/NativeOracle.hex" "${ARTIFACT_DIR}/NativeOracle.hex"
    cp "${tmp_dir}/OracleTaskConfig.hex" "${ARTIFACT_DIR}/OracleTaskConfig.hex"
    cp "${tmp_dir}/manifest.json" "${ARTIFACT_DIR}/manifest.json"
    echo "Gamma artifacts written to scripts/hardfork/gamma/artifacts."
fi
