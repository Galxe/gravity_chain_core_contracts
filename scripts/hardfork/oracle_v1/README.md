# OracleV1 hardfork artifacts

This directory freezes the two runtime bytecodes installed by the OracleV1
testnet hardfork:

| Contract | System address | Upgrade behavior |
| --- | --- | --- |
| `NativeOracle` | `0x00000000000000000000000000000001625F4000` | Replace runtime code; preserve account and storage |
| `OracleTaskConfig` | `0x00000000000000000000000000000001625F1009` | Replace runtime code; preserve account and storage |

`PriceFeedResolver` is not a genesis system contract. Deploy it after the
hardfork and configure callbacks/tasks through governance. Polymarket
`sourceType=6` remains disabled for the first OracleV1 activation.

## Reproduce artifacts

The compiler and bytecode metadata settings are pinned in `foundry.toml`.
Generate or verify the committed runtime bytecodes with:

```bash
PATH="$HOME/.foundry/bin:$PATH" \
  bash scripts/hardfork/oracle_v1/generate_artifacts.sh

PATH="$HOME/.foundry/bin:$PATH" \
  bash scripts/hardfork/oracle_v1/generate_artifacts.sh --check
```

The manifest records source-tree identity, system addresses, pre-fork testnet
codehashes, post-fork codehashes, and runtime sizes. It intentionally contains
no machine-local paths or generation timestamp.

## Storage compatibility gate

OracleV1 performs code-only account updates. Existing balances, nonces, and
storage must survive the activation block. Check the append-only layouts with:

```bash
PATH="$HOME/.foundry/bin:$PATH" \
  bash scripts/hardfork/oracle_v1/check_storage_layout.sh
```

The required layouts are:

- `NativeOracle`: legacy slots `0..4` unchanged; `_sourceProgress` appended at slot `5`.
- `OracleTaskConfig`: legacy slots `0..4` unchanged; `priceFeedConfigHash` appended at slot `5`.

## Testnet verification

Before scheduling the hardfork, verify that the chain is still on the exact
expected baseline:

```bash
bash scripts/hardfork/oracle_v1/verify_rpc.sh "$RPC_URL" pre
```

After the activation block is finalized, verify the installed bytecodes:

```bash
bash scripts/hardfork/oracle_v1/verify_rpc.sh "$RPC_URL" post
```

An unexpected pre-fork codehash is a release blocker. Do not replace the
manifest value to make the check pass until the difference is understood and
the reth migration guard is updated and reviewed.

## Activation order

1. Build and publish the new validator binary containing these exact runtime bytecodes.
2. Upgrade every validator before the configured `oracleV1Block`.
3. Re-run the pre-fork RPC and storage-layout checks.
4. Allow block `oracleV1Block` to install both runtime bytecodes atomically.
5. Confirm the post-fork codehashes and bridge/sourceType `0` continuity.
6. Deploy `PriceFeedResolver`, configure its callbacks and sourceType `3` tasks, then activate them at an epoch boundary.

After the activation block, rollback requires coordinated chain-state rollback;
restarting validators with the old binary is not a valid rollback procedure.
