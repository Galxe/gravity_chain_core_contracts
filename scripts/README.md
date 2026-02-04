# Oracle Bridge Test Scripts

This directory contains scripts for testing the Oracle EVM Bridge.

## Script Description

| Script | Description |
|--------|-------------|
| `start_anvil.sh` | Start Anvil local testnet (port 8546, block-time 1s) and deploy contracts |
| `bridge_test.sh` | Call the bridge contract and display MessageSent event details |
| `stop_anvil.sh` | Stop the Anvil testnet |

## Usage

```bash
# 1. Start Anvil and deploy contracts
./scripts/start_anvil.sh

# 2. Test bridge interaction (can be run multiple times)
./scripts/bridge_test.sh

# 3. Stop Anvil when done
./scripts/stop_anvil.sh
```

## Deployed Contracts

Since Anvil's default account and nonce are used, contract addresses are fixed:

| Contract | Address | Nonce |
|----------|---------|-------|
| MockGToken | `0x5FbDB2315678afecb367f032d93F642f64180aa3` | 0 |
| GravityPortal | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` | 1 |
| GBridgeSender | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` | 2 |

## Rust Unit Tests

There are corresponding unit tests in `gravity-reth` that can read and parse these events:

```bash
# 1. First start Anvil and deploy contracts
cd gravity_chain_core_contracts
./scripts/start_anvil.sh
./scripts/bridge_test.sh

# 2. Run Rust tests
cd gravity-reth
cargo test --package reth-pipe-exec-layer-relayer test_poll_anvil_events -- --ignored --nocapture
```

The test will output the parsed event content, including fields such as sender, nonce, amount, recipient, etc.

## Event Format

The `GravityPortal` contract emits a `MessageSent` event:

```solidity
event MessageSent(uint128 indexed nonce, uint256 indexed block_number, bytes payload);
```

The payload uses `PortalMessage` format:
```
sender (20 bytes) || nonce (16 bytes) || message (variable)
```
