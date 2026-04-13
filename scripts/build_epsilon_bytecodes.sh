#!/usr/bin/env bash
# build_epsilon_bytecodes.sh — Extract Epsilon hardfork bytecodes for gravity-reth.
#
# Reads the 4 contracts changed in Epsilon (ValidatorManagement, Reconfiguration,
# ValidatorConfig, GBridgeReceiver) from `forge build` artifacts, patches the
# GBridgeReceiver immutables (trustedBridge, trustedSourceId) with environment-
# specific values, and writes raw .bin files into the gravity-reth bytecodes/
# directory so they can be `include_bytes!`'d by epsilon.rs.
#
# Usage:
#   bash scripts/build_epsilon_bytecodes.sh \
#       [--reth-root /path/to/gravity-reth] \
#       [--trusted-bridge 0x...] \
#       [--trusted-source-id N]
#
# Environment overrides:
#   RETH_ROOT          — gravity-reth checkout (default: ~/projects/gravity-reth)
#   TRUSTED_BRIDGE     — testnet GBridgeSender address (no default — must be set)
#   TRUSTED_SOURCE_ID  — Ethereum source chain id (no default — must be set)
#
# Defaults match the gravity testnet at the time of writing:
#   TRUSTED_BRIDGE    = 0x79226649b3A20231e6b468a9E1AbBD23d3DFbbC6
#   TRUSTED_SOURCE_ID = 11155111  (Sepolia)
#
# These were obtained from on-chain reads against the live testnet:
#   cast call $GBRIDGE_RECEIVER 'trustedBridge()(address)'   --rpc-url $RPC
#   cast call $NATIVE_ORACLE   'getLatestNonce(uint32,uint256)(uint128)' 0 11155111 --rpc-url $RPC

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────
RETH_ROOT="${RETH_ROOT:-${HOME}/projects/gravity-reth}"
TRUSTED_BRIDGE="${TRUSTED_BRIDGE:-0x79226649b3A20231e6b468a9E1AbBD23d3DFbbC6}"
TRUSTED_SOURCE_ID="${TRUSTED_SOURCE_ID:-11155111}"

while [ $# -gt 0 ]; do
    case "$1" in
        --reth-root)       RETH_ROOT="$2"; shift 2 ;;
        --trusted-bridge)  TRUSTED_BRIDGE="$2"; shift 2 ;;
        --trusted-source-id) TRUSTED_SOURCE_ID="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$RETH_ROOT/crates/ethereum/evm/src/hardfork/bytecodes/epsilon"

if [ ! -d "$RETH_ROOT" ]; then
    echo "❌ gravity-reth root not found: $RETH_ROOT" >&2
    exit 1
fi

echo "=== Building Epsilon bytecodes ==="
echo "  repo:        $REPO_ROOT"
echo "  dest:        $DEST_DIR"
echo "  testnet trustedBridge:    $TRUSTED_BRIDGE"
echo "  testnet trustedSourceId:  $TRUSTED_SOURCE_ID"
echo ""

# ── Step 1: forge build (in a clean state) ──────────────────────────
echo "→ forge build"
(cd "$REPO_ROOT" && forge build --skip test 2>&1 | tail -3)
echo ""

mkdir -p "$DEST_DIR"

# ── Step 2: extract raw deployed bytecode for the 3 plain contracts ─
extract_plain() {
    local name="$1"
    local artifact="$REPO_ROOT/out/${name}.sol/${name}.json"
    if [ ! -f "$artifact" ]; then
        echo "❌ Artifact missing: $artifact" >&2
        return 1
    fi
    python3 -c "
import json
d = json.load(open('$artifact'))
b = d['deployedBytecode']['object']
if b.startswith('0x'): b = b[2:]
import sys
sys.stdout.buffer.write(bytes.fromhex(b))
" > "$DEST_DIR/${name}.bin"
    local size
    size=$(wc -c < "$DEST_DIR/${name}.bin")
    echo "  ✅ ${name}.bin (${size} bytes)"
}

echo "→ extracting plain contracts"
extract_plain ValidatorManagement
extract_plain Reconfiguration
extract_plain ValidatorConfig
echo ""

# ── Step 3: extract + patch GBridgeReceiver immutables ──────────────
echo "→ extracting and patching GBridgeReceiver immutables"
python3 - <<PY
import json, sys

artifact = json.load(open("$REPO_ROOT/out/GBridgeReceiver.sol/GBridgeReceiver.json"))
deployed = artifact["deployedBytecode"]
bytecode_hex = deployed["object"]
if bytecode_hex.startswith("0x"):
    bytecode_hex = bytecode_hex[2:]
code = bytearray(bytes.fromhex(bytecode_hex))

imm_refs = deployed.get("immutableReferences", {})
if not imm_refs:
    print("❌ No immutableReferences in GBridgeReceiver artifact", file=sys.stderr)
    sys.exit(1)

# AST ids are assigned in declaration order. In src/oracle/evm/native_token_bridge/
# GBridgeReceiver.sol the order is:
#   uint256/address public immutable trustedBridge;
#   uint256        public immutable trustedSourceId;
# So the lower ast id = trustedBridge, higher = trustedSourceId.
ast_ids_sorted = sorted(imm_refs.keys(), key=int)
if len(ast_ids_sorted) != 2:
    print(f"❌ Expected 2 immutables, got {len(ast_ids_sorted)}: {ast_ids_sorted}", file=sys.stderr)
    sys.exit(1)

trusted_bridge_hex = "$TRUSTED_BRIDGE".lower().removeprefix("0x")
if len(trusted_bridge_hex) != 40:
    print(f"❌ Bad trustedBridge: $TRUSTED_BRIDGE", file=sys.stderr)
    sys.exit(1)
trusted_bridge_word = ("0" * (64 - 40)) + trusted_bridge_hex  # left-padded 32-byte word

trusted_source_id_int = int("$TRUSTED_SOURCE_ID")
trusted_source_id_word = trusted_source_id_int.to_bytes(32, "big").hex()

patch_values = {
    ast_ids_sorted[0]: bytes.fromhex(trusted_bridge_word),     # trustedBridge
    ast_ids_sorted[1]: bytes.fromhex(trusted_source_id_word),  # trustedSourceId
}

for ast_id in ast_ids_sorted:
    val = patch_values[ast_id]
    refs = imm_refs[ast_id]
    print(f"  ast={ast_id} value={val.hex()} sites={[(r['start'], r['length']) for r in refs]}")
    for ref in refs:
        start = ref["start"]
        length = ref["length"]
        if length != 32:
            print(f"❌ Unexpected immutable length {length} at offset {start}", file=sys.stderr)
            sys.exit(1)
        # All current bytes at this site should be zero (placeholder)
        if any(code[start:start+32]):
            existing = code[start:start+32].hex()
            print(f"⚠️  Slot at offset {start} is non-zero before patch: {existing}", file=sys.stderr)
        code[start:start+32] = val

with open("$DEST_DIR/GBridgeReceiver.bin", "wb") as f:
    f.write(bytes(code))
print(f"  ✅ GBridgeReceiver.bin ({len(code)} bytes, patched)")
PY
echo ""

ls -la "$DEST_DIR"
echo ""
echo "=== Done. Bytecodes ready at $DEST_DIR ==="
