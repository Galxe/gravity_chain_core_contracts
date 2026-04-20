#!/usr/bin/env bash
# Stage 2 — addStake / unstake / withdrawAvailable drills.
# Usage:
#   stage2_stake_moves.sh <pool-idx> add <wei>
#   stage2_stake_moves.sh <pool-idx> unstake <wei>
#   stage2_stake_moves.sh <pool-idx> withdraw <wei>
#   stage2_stake_moves.sh <pool-idx> renew-lock <lockedUntilMicros>

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <pool-idx 1..7> <add|unstake|withdraw|renew-lock> [arg]" >&2
    exit 1
fi

IDX="$1"
OP="$2"
ARG="${3:-}"

: "${RPC_URL:?RPC_URL must be set}"

POOL_VAR="POOL_$IDX"
PK_VAR="OPERATOR_PK_$IDX"
POOL="${!POOL_VAR:?$POOL_VAR must be set}"
PK="${!PK_VAR:?$PK_VAR must be set}"

case "$OP" in
    add)
        : "${ARG:?addStake requires a wei amount}"
        cast send --rpc-url "$RPC_URL" --private-key "$PK" --value "$ARG" \
            "$POOL" "addStake()"
        ;;
    unstake)
        : "${ARG:?unstake requires a wei amount}"
        cast send --rpc-url "$RPC_URL" --private-key "$PK" \
            "$POOL" "unstake(uint256)" "$ARG"
        ;;
    withdraw)
        : "${ARG:?withdrawAvailable requires a wei amount}"
        cast send --rpc-url "$RPC_URL" --private-key "$PK" \
            "$POOL" "withdrawAvailable(uint256)" "$ARG"
        ;;
    renew-lock)
        : "${ARG:?renewLockUntil requires a uint64 microsecond timestamp}"
        cast send --rpc-url "$RPC_URL" --private-key "$PK" \
            "$POOL" "renewLockUntil(uint64)" "$ARG"
        ;;
    *)
        echo "unknown op: $OP" >&2
        exit 2
        ;;
esac

# Print post-state for quick eyeballing
echo "--- post state for pool $IDX ($POOL) ---"
cast call --rpc-url "$RPC_URL" "$POOL" "getVotingPowerNow()(uint256)"
cast call --rpc-url "$RPC_URL" "$POOL" "getTotalPending()(uint256)"
cast call --rpc-url "$RPC_URL" "$POOL" "getClaimableAmount()(uint256)"
cast call --rpc-url "$RPC_URL" "$POOL" "getLockedUntil()(uint64)"
