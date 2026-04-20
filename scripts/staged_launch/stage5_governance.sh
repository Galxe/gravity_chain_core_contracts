#!/usr/bin/env bash
# Stage 5 — governance parameter drills.
# Usage:
#   stage5_governance.sh min-stake <wei>
#   stage5_governance.sh lockup <micros>
#   stage5_governance.sh unbonding <micros>
#   stage5_governance.sh whitelist-add <pool-addr>
#   stage5_governance.sh whitelist-remove <pool-addr>
#   stage5_governance.sh permissionless-on
#   stage5_governance.sh permissionless-off
#   stage5_governance.sh show-pending

set -euo pipefail

: "${RPC_URL:?RPC_URL must be set}"

STAKING_CONFIG="0x0000000000000000000000000001625F1001"
VALIDATOR_MANAGER="0x0000000000000000000000000001625F2001"

need_gov() {
    : "${GOVERNANCE_PK:?GOVERNANCE_PK must be set}"
}

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <op> [arg]   — see script header for ops" >&2
    exit 1
fi

OP="$1"
ARG="${2:-}"

case "$OP" in
    min-stake)
        need_gov; : "${ARG:?wei amount required}"
        cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
            "$STAKING_CONFIG" "setMinimumStakeForNextEpoch(uint256)" "$ARG"
        ;;
    lockup)
        need_gov; : "${ARG:?micros required}"
        cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
            "$STAKING_CONFIG" "setLockupDurationForNextEpoch(uint64)" "$ARG"
        ;;
    unbonding)
        need_gov; : "${ARG:?micros required}"
        cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
            "$STAKING_CONFIG" "setUnbondingDelayForNextEpoch(uint64)" "$ARG"
        ;;
    whitelist-add)
        need_gov; : "${ARG:?pool address required}"
        cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
            "$VALIDATOR_MANAGER" "setValidatorPoolAllowed(address,bool)" "$ARG" true
        ;;
    whitelist-remove)
        need_gov; : "${ARG:?pool address required}"
        cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
            "$VALIDATOR_MANAGER" "setValidatorPoolAllowed(address,bool)" "$ARG" false
        ;;
    permissionless-on)
        need_gov
        cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
            "$VALIDATOR_MANAGER" "setPermissionlessJoinEnabled(bool)" true
        ;;
    permissionless-off)
        need_gov
        cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
            "$VALIDATOR_MANAGER" "setPermissionlessJoinEnabled(bool)" false
        ;;
    show-pending)
        echo "--- StakingConfig pending ---"
        cast call --rpc-url "$RPC_URL" "$STAKING_CONFIG" "hasPendingConfig()(bool)"
        cast call --rpc-url "$RPC_URL" "$STAKING_CONFIG" \
            "getPendingConfig()(bool,(uint256,uint64,uint64,uint256))"
        echo "--- ValidatorManagement whitelist flags ---"
        cast call --rpc-url "$RPC_URL" "$VALIDATOR_MANAGER" "isPermissionlessJoinEnabled()(bool)"
        ;;
    *)
        echo "unknown op: $OP" >&2
        exit 2
        ;;
esac
