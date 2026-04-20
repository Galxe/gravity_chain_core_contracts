# Staged Launch Drill Scripts

Companion scripts to `spec_v2/staged_launch_runbook.md`. All scripts are thin
wrappers around `cast`. Fill in the env vars once, then run each stage in
order.

## Required env

```bash
export RPC_URL="https://rpc.gravity.example"     # or http://127.0.0.1:8545 for dev
export CHAIN_ID=127001                           # Gravity L1 mainnet/testnet
export OPERATOR_PK_1=0x...   # validator-1 operator key
export OPERATOR_PK_2=0x...   # validator-2 operator key
# ... up to OPERATOR_PK_7
export POOL_1=0x...          # validator-1 stake-pool address
export POOL_2=0x...
# ... up to POOL_7
export GOVERNANCE_PK=0x...   # key authorized to call the GOVERNANCE system address
```

System contract addresses are constants (see `src/foundation/SystemAddresses.sol`):

| Contract | Address |
|---|---|
| `Staking` | `0x0000000000000000000000000001625F2000` |
| `ValidatorManager` | `0x0000000000000000000000000001625F2001` |
| `StakingConfig` | `0x0000000000000000000000000001625F1001` |
| `ValidatorConfig` | `0x0000000000000000000000000001625F1002` |
| `Reconfiguration` | `0x0000000000000000000000000001625F2003` |

## Stage 1 — cold-start sanity

Run directly (no script needed):

```bash
# Active validator count should be 7
cast call --rpc-url "$RPC_URL" 0x0000000000000000000000000001625F2001 \
    "getActiveValidatorCount()(uint256)"

# Permissionless flag must be false
cast call --rpc-url "$RPC_URL" 0x0000000000000000000000000001625F2001 \
    "isPermissionlessJoinEnabled()(bool)"

# Each genesis pool must be whitelisted
for i in 1 2 3 4 5 6 7; do
  POOL_VAR="POOL_$i"
  cast call --rpc-url "$RPC_URL" 0x0000000000000000000000000001625F2001 \
      "isValidatorPoolAllowed(address)(bool)" "${!POOL_VAR}"
done
```

## Stage 2 — stake movement drills

`./stage2_stake_moves.sh <pool-index> <delta-wei>` runs addStake and unstake on
the indexed validator's pool. Positive delta adds, negative delta unstakes.
Withdraw after `lockedUntil + unbondingDelay` by passing `--withdraw <amount>`.

## Stage 3 — lifecycle drills

`./stage3_lifecycle.sh <pool-index> (leave|join)` — flips the named validator.
Use `evict-underperformers` (no index) to trigger Phase-2 auto-evict.

## Stage 4 — DKG observation (no writes)

```bash
# Tail TranscriptEvents during epoch transitions
cast logs --rpc-url "$RPC_URL" --from-block latest \
    "TranscriptEvent(uint64,bytes)" \
    --address 0x0000000000000000000000000001625F2003
```

Verify: each epoch logs one `TranscriptEvent` before the `NewEpoch` event, and
`isTransitionInProgress()` returns to `false` within the reconfiguration window.

## Stage 5 — governance parameter drills

`./stage5_governance.sh <op> <value>` where `<op>` is one of
`min-stake | lockup | unbonding | min-bond | toggle-auto-evict`. Submits the
proposal from `GOVERNANCE_PK`. Applies at the next epoch boundary.

## Stage 6 — permissionless flip

One-shot:

```bash
cast send --rpc-url "$RPC_URL" --private-key "$GOVERNANCE_PK" \
    0x0000000000000000000000000001625F2001 \
    "setPermissionlessJoinEnabled(bool)" true
```

Then confirm `isPermissionlessJoinEnabled()(bool)` returns `true` and any
non-whitelisted address can successfully `registerValidator`.
