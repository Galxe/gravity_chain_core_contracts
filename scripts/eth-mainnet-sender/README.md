# Gravity Bridge Sender — Ethereum Mainnet Deployment

Deploys `GravityPortal` + `GBridgeSender` to Ethereum mainnet in a single `forge script` broadcast, handing ownership of both contracts to a Safe multisig via `Ownable2Step.transferOwnership()`. The multisig must then call `acceptOwnership()` on each contract to finalize the handover.

This is the Ethereum-side counterpart to `GBridgeReceiver` on Gravity chain. The full operator runbook (multisig decisions, dry-run, handoff to Gravity mainnet launch §11.2) lives in **`mono-grav/docs/mainnet/ETH-BRIDGE-SENDER-DEPLOYMENT.md`**. This file is a minimal script-side reference.

## Constants baked into the script

| Name | Value | Source |
|------|-------|--------|
| G token (mainnet) | `0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649` | verified on-chain: `name="Gravity"`, `symbol="G"`, `decimals=18`, supports ERC20Permit |
| Chain id | `1` | hard guard, bypass with `ALLOW_NON_MAINNET=1` (fork only) |

## Required env vars

```bash
PRIVATE_KEY=0x...           # deployer EOA — temporary owner; only holds ownership for the duration of the script
MULTISIG_ADDRESS=0x...      # final owner (Safe); MUST differ from the deployer EOA
```

## Optional env vars

```bash
FEE_RECIPIENT_ADDRESS=0x... # default: MULTISIG_ADDRESS
INITIAL_BASE_FEE=10000000000000      # wei; default 0.00001 ether (revisit before real deploy)
INITIAL_FEE_PER_BYTE=100000000000    # wei; default 100 gwei (revisit before real deploy)
ALLOW_NON_MAINNET=1         # ONLY for fork tests; omit on real deploy
```

## Flow performed by the script

1. `new GravityPortal(deployer, baseFee, feePerByte, feeRecipient=MULTISIG)`
2. `portal.transferOwnership(MULTISIG)` — pendingOwner = multisig
3. `new GBridgeSender(gToken=G_TOKEN_MAINNET, portal=address(portal), deployer)`
4. `sender.transferOwnership(MULTISIG)` — pendingOwner = multisig
5. Post-broadcast asserts: `pendingOwner == multisig` on both, portal/gToken wiring is correct.

Deployer EOA is the active owner only between tx 1→2 and tx 3→4 — practically zero window.
`feeRecipient` is set to multisig in the constructor, so any `withdrawFees()` the deployer could theoretically call during that window still routes ETH to the multisig.

## Local fork dry-run (no broadcast, no mainnet cost)

```bash
export PRIVATE_KEY=0x<any-funded-test-key>   # anvil test key works on fork
export MULTISIG_ADDRESS=0x000000000000000000000000000000000000dEaD
export ALLOW_NON_MAINNET=1

forge script scripts/eth-mainnet-sender/DeployBridge.s.sol \
  --fork-url https://ethereum-rpc.publicnode.com \
  -vvvv
```

Expect: both contracts deploy, all post-deploy asserts pass, deployment JSON printed. No transactions are broadcast without `--broadcast`.

## Real mainnet deploy

1. Fund the deployer EOA with ~0.2 ETH.
2. Confirm `MULTISIG_ADDRESS`, `FEE_RECIPIENT_ADDRESS`, `INITIAL_BASE_FEE`, `INITIAL_FEE_PER_BYTE` are the finalized values.
3. Commit hash of the repo in this deploy is recorded in the deployment artifact.

```bash
export PRIVATE_KEY=0x...                    # hardware wallet / Foundry keystore recommended over raw env
export MULTISIG_ADDRESS=0x...
export ETHERSCAN_API_KEY=...

forge script scripts/eth-mainnet-sender/DeployBridge.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

Alternative using Foundry keystore / hardware wallet:

```bash
forge script scripts/eth-mainnet-sender/DeployBridge.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --ledger --sender 0x<ledger-address> \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

(If using `--ledger`, remove `PRIVATE_KEY` from env and adjust the script to read sender from `msg.sender` instead of `vm.addr(vm.envUint("PRIVATE_KEY"))`. Ping before switching this mode.)

## Post-deploy: multisig acceptOwnership

On the Safe, create two Contract Interaction transactions:

| Target | Method | Args |
|--------|--------|------|
| `GravityPortal` address | `acceptOwnership()` | none |
| `GBridgeSender` address | `acceptOwnership()` | none |

Verify afterwards:

```bash
cast call <portal>  "owner()(address)"   --rpc-url $MAINNET_RPC_URL   # == MULTISIG
cast call <sender>  "owner()(address)"   --rpc-url $MAINNET_RPC_URL   # == MULTISIG
cast call <portal>  "pendingOwner()(address)" --rpc-url $MAINNET_RPC_URL  # == 0x0
cast call <sender>  "pendingOwner()(address)" --rpc-url $MAINNET_RPC_URL  # == 0x0
```

**Do not announce the contract addresses or open the bridge frontend until the multisig has accepted ownership on both contracts.**

## Smoke test after acceptOwnership

1. `cast call <sender> "calculateBridgeFee(uint256,address)" 1000000000000000000 <recipient>` — sanity check fee
2. Approve 1 G to Sender, then call `bridgeToGravity(1e18, <recipientOnGravity>)` with `msg.value = fee`.
3. Confirm `TokensLocked` event on Ethereum and native G mint on Gravity chain.

## Emergency

No upgrade path. If a critical bug is found:
- Multisig can `emergencyWithdraw` / `recoverERC20` on GBridgeSender (drains locked G back to a safe address).
- Consensus engine side can stop processing `MessageSent` events from the deployed Portal.
- Fix requires re-deploy + frontend + consensus engine redirect.
