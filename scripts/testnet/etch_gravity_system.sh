#!/usr/bin/env bash
# =============================================================================
#  Etch Gravity system contracts onto a local anvil at their hard-coded
#  SystemAddresses. Used by run_full_test.sh to simulate a Gravity-chain
#  environment that the verify_deployment.sh script can be pointed at.
#
#  Args:  GRAVITY_RPC_URL must be exported and reachable (anvil endpoint).
#
#  Effects:
#    - For each (addr, artifact) pair, reads deployedBytecode.object from
#      out/<File>/<Contract>.json and calls anvil_setCode.
#    - Precompiles (NATIVE_MINT_PRECOMPILE, BLS_POP_VERIFY_PRECOMPILE) have
#      no Solidity source — we etch a single STOP opcode so they "have some
#      code" as the Gravity verifier only asserts presence for these.
#    - SYSTEM_CALLER is an EOA role in production; we leave it empty.
# =============================================================================
set -euo pipefail

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
die()    { red "ERROR: $*"; exit 1; }

: "${GRAVITY_RPC_URL:?GRAVITY_RPC_URL is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

command -v jq  >/dev/null 2>&1 || die "jq required"
command -v cast >/dev/null 2>&1 || die "cast required"

# (address, artifact_file)
# Artifact file path is relative to out/. Must match VerifyGravityChain.s.sol's _systemEntries().
# Addresses MUST be 20 bytes (40 hex chars after 0x). The Solidity constants
# in SystemAddresses.sol use a shorter literal that the compiler left-pads,
# but anvil's JSON-RPC validator does not, so we spell them out full-width.
ENTRIES=(
    # --- 0x1625F0xxx ---
    "0x00000000000000000000000000000001625F0001 Genesis.sol/Genesis.json"
    # --- 0x1625F1xxx ---
    "0x00000000000000000000000000000001625F1000 Timestamp.sol/Timestamp.json"
    "0x00000000000000000000000000000001625F1001 StakingConfig.sol/StakingConfig.json"
    "0x00000000000000000000000000000001625F1002 ValidatorConfig.sol/ValidatorConfig.json"
    "0x00000000000000000000000000000001625F1003 RandomnessConfig.sol/RandomnessConfig.json"
    "0x00000000000000000000000000000001625F1004 GovernanceConfig.sol/GovernanceConfig.json"
    "0x00000000000000000000000000000001625F1005 EpochConfig.sol/EpochConfig.json"
    "0x00000000000000000000000000000001625F1006 VersionConfig.sol/VersionConfig.json"
    "0x00000000000000000000000000000001625F1007 ConsensusConfig.sol/ConsensusConfig.json"
    "0x00000000000000000000000000000001625F1008 ExecutionConfig.sol/ExecutionConfig.json"
    "0x00000000000000000000000000000001625F1009 OracleTaskConfig.sol/OracleTaskConfig.json"
    "0x00000000000000000000000000000001625F100A OnDemandOracleTaskConfig.sol/OnDemandOracleTaskConfig.json"
    # --- 0x1625F2xxx ---
    "0x00000000000000000000000000000001625F2000 Staking.sol/Staking.json"
    "0x00000000000000000000000000000001625F2001 ValidatorManagement.sol/ValidatorManagement.json"
    "0x00000000000000000000000000000001625F2002 DKG.sol/DKG.json"
    "0x00000000000000000000000000000001625F2003 Reconfiguration.sol/Reconfiguration.json"
    "0x00000000000000000000000000000001625F2004 Blocker.sol/Blocker.json"
    "0x00000000000000000000000000000001625F2005 ValidatorPerformanceTracker.sol/ValidatorPerformanceTracker.json"
    # --- 0x1625F3xxx ---
    "0x00000000000000000000000000000001625F3000 Governance.sol/Governance.json"
    # --- 0x1625F4xxx ---
    "0x00000000000000000000000000000001625F4000 NativeOracle.sol/NativeOracle.json"
    "0x00000000000000000000000000000001625F4001 JWKManager.sol/JWKManager.json"
    "0x00000000000000000000000000000001625F4002 OracleRequestQueue.sol/OracleRequestQueue.json"
)

# Precompiles — no Solidity source. Etch a single STOP opcode (0x00) so
# they appear "present" to the verifier's precompile branch.
PRECOMPILES=(
    "0x00000000000000000000000000000001625F5000"
    "0x00000000000000000000000000000001625F5001"
)

# Ensure artifacts are built (and deployedBytecode is populated).
if [[ ! -d "${REPO_ROOT}/out" ]]; then
    yellow "out/ missing — running forge build"
    forge build >/dev/null
fi

green "Etching Gravity system contracts onto ${GRAVITY_RPC_URL}"

etch_one() {
    local addr="$1" artifact_path="$2"
    local full="${REPO_ROOT}/out/${artifact_path}"
    if [[ ! -f "${full}" ]]; then
        die "artifact not found: ${full} — run \`forge build\` first"
    fi
    local code
    code="$(jq -r '.deployedBytecode.object' "${full}")"
    if [[ -z "${code}" || "${code}" == "null" || "${code}" == "0x" ]]; then
        die "empty deployedBytecode in ${full}"
    fi
    cast rpc --rpc-url "${GRAVITY_RPC_URL}" anvil_setCode "${addr}" "${code}" >/dev/null
    printf "  [etch] %s  <- %s (%d bytes)\n" "${addr}" "${artifact_path}" $(( (${#code} - 2) / 2 ))
}

etch_stub() {
    local addr="$1"
    cast rpc --rpc-url "${GRAVITY_RPC_URL}" anvil_setCode "${addr}" "0x00" >/dev/null
    printf "  [stub] %s  <- STOP opcode (precompile placeholder)\n" "${addr}"
}

for entry in "${ENTRIES[@]}"; do
    addr="${entry%% *}"
    artifact="${entry#* }"
    etch_one "${addr}" "${artifact}"
done

for addr in "${PRECOMPILES[@]}"; do
    etch_stub "${addr}"
done

green "Etched ${#ENTRIES[@]} system contracts + ${#PRECOMPILES[@]} precompile stubs."
