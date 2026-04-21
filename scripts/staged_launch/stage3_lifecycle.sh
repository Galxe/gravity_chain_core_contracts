#!/usr/bin/env bash
# Stage 3 — validator lifecycle drills.
# Usage:
#   stage3_lifecycle.sh <pool-idx> leave
#   stage3_lifecycle.sh <pool-idx> join
#   stage3_lifecycle.sh evict-underperformers

set -euo pipefail

: "${RPC_URL:?RPC_URL must be set}"

VALIDATOR_MANAGER="0x0000000000000000000000000001625F2001"

if [[ "${1:-}" == "evict-underperformers" ]]; then
    : "${GOVERNANCE_PK:?GOVERNANCE_PK must be set}"
    cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
        "$VALIDATOR_MANAGER" "evictUnderperformingValidators()"
    exit 0
fi

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <pool-idx 1..7> <leave|join>   |   $0 evict-underperformers" >&2
    exit 1
fi

IDX="$1"
OP="$2"

POOL_VAR="POOL_$IDX"
PK_VAR="OPERATOR_PK_$IDX"
POOL="${!POOL_VAR:?$POOL_VAR must be set}"
PK="${!PK_VAR:?$PK_VAR must be set}"

case "$OP" in
    leave)
        cast send --rpc-url "$RPC_URL" --private-key "$PK" \
            "$VALIDATOR_MANAGER" "leaveValidatorSet(address)" "$POOL"
        ;;
    join)
        cast send --rpc-url "$RPC_URL" --private-key "$PK" \
            "$VALIDATOR_MANAGER" "joinValidatorSet(address)" "$POOL"
        ;;
    *)
        echo "unknown op: $OP (expected leave|join)" >&2
        exit 2
        ;;
esac

echo "--- post state for pool $IDX ($POOL) ---"
cast call --rpc-url "$RPC_URL" "$VALIDATOR_MANAGER" \
    "getValidatorStatus(address)(uint8)" "$POOL"
cast call --rpc-url "$RPC_URL" "$VALIDATOR_MANAGER" \
    "getActiveValidatorCount()(uint256)"
