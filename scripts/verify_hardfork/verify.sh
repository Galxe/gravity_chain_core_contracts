#!/usr/bin/env bash
# verify.sh — Generic hardfork verification entry point.
#
# Verifies contract upgrades on a live chain by:
#   Phase 1: Comparing on-chain codehashes against expected values
#   Phase 2: Running functional smoke tests for the hardfork
#
# Usage:
#   bash scripts/verify_hardfork/verify.sh <hardfork_name> <RPC_URL>
#
# Examples:
#   bash scripts/verify_hardfork/verify.sh gamma http://localhost:8545
#   bash scripts/verify_hardfork/verify.sh delta https://testnet-rpc.example.com
#
# Prerequisites:
#   1. Generate expected hashes first:
#      bash scripts/verify_hardfork/generate_hashes.sh <hardfork_name>
#   2. Foundry (cast) must be installed
#
# Exit code: 0 = all pass, 1 = any fail

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

if [ $# -lt 2 ]; then
    echo "Usage: $0 <hardfork_name> <RPC_URL>"
    echo ""
    echo "Available hardforks:"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for hf in "${SCRIPT_DIR}"/hardforks/*.sh; do
        [ -f "$hf" ] && echo "  - $(basename "$hf" .sh)"
    done
    echo ""
    echo "Example: $0 gamma http://localhost:8545"
    exit 1
fi

HARDFORK_NAME="$1"
RPC_URL="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/addresses.sh"
source "${SCRIPT_DIR}/lib/helpers.sh"

# Source hardfork-specific configuration
HARDFORK_CONFIG="${SCRIPT_DIR}/hardforks/${HARDFORK_NAME}.sh"
if [ ! -f "$HARDFORK_CONFIG" ]; then
    echo "❌ Unknown hardfork: ${HARDFORK_NAME}"
    echo "   No config found at: ${HARDFORK_CONFIG}"
    exit 1
fi
source "$HARDFORK_CONFIG"

# Source expected hashes
EXPECTED_HASHES="${SCRIPT_DIR}/generated/${HARDFORK_NAME}_expected_hashes.sh"
if [ ! -f "$EXPECTED_HASHES" ]; then
    echo "❌ Expected hashes not found: ${EXPECTED_HASHES}"
    echo "   Run: bash scripts/verify_hardfork/generate_hashes.sh ${HARDFORK_NAME}"
    exit 1
fi
source "$EXPECTED_HASHES"

DISPLAY_NAME="${HARDFORK_DISPLAY_NAME:-${HARDFORK_NAME} Hardfork}"

# ============================================================================
# Phase 1: Bytecode Hash Verification
# ============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        ${DISPLAY_NAME} Verification — Phase 1               "
echo "║        Bytecode Hash Comparison                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "RPC: ${RPC_URL}"
echo ""

verify_system_contracts

if [ "${VERIFY_STAKEPOOL:-false}" = true ]; then
    verify_stakepool_instances "$STAKING"
fi

# ============================================================================
# Phase 2: Functional Smoke Tests
# ============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        ${DISPLAY_NAME} Verification — Phase 2               "
echo "║        Functional Smoke Tests                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if declare -f run_smoke_tests > /dev/null 2>&1; then
    run_smoke_tests
else
    echo "  (no smoke tests defined for ${HARDFORK_NAME})"
    echo ""
fi

# ============================================================================
# Summary
# ============================================================================

print_summary "$DISPLAY_NAME"
