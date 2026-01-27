# Gravity Core Contracts

On-chain infrastructure for the Gravity blockchain — a layered smart contract architecture for staking, governance, and
consensus coordination.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         EXTERNAL SYSTEMS                        │
│               (Consensus Engine, VM Runtime, Users)             │
└───────────────────────────────┬─────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│   Governance  │       │    Oracle     │       │    Blocker    │
│   (Layer 5)   │       │   (Layer 6)   │       │   (Layer 4)   │
└───────┬───────┘       └───────────────┘       └───────┬───────┘
        │                                               │
        └───────────────────────┬───────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│               Staking & Validator Management (L2-3)             │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Runtime (Layer 1)                        │
│           Timestamp · Configs · DKG · Epoch Management          │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Foundation (Layer 0)                       │
│          SystemAddresses · Types · Errors · AccessControl       │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Build
forge build

# Test
forge test

# Test with verbosity
forge test -vvv

# Generate genesis.json
./scripts/generate_genesis.sh
```

## Genesis Generation

The `genesis-tool` generates a complete genesis configuration for the Gravity Chain.

### Multi-Node (4 validators)

```bash
# Default settings (4 nodes, 2-hour epoch interval)
./scripts/generate_genesis.sh

# Custom epoch interval (e.g., 4 hours)
./scripts/generate_genesis.sh -i 4

# Help
./scripts/generate_genesis.sh --help
```

### Single-Node (1 validator)

```bash
# Single node genesis (for local testing)
./scripts/generate_genesis_single.sh

# Single node with custom epoch interval
./scripts/generate_genesis_single.sh -i 1
```

### Options

| Option | Description |
|--------|-------------|
| `-i, --interval HOURS` | Set epoch interval in hours (default: 2) |
| `-c, --config FILE` | Use custom config file |
| `-h, --help` | Show help message |

### Configuration Files

| File | Description |
|------|-------------|
| `genesis-tool/config/genesis_config.json` | 4-node configuration |
| `genesis-tool/config/genesis_config_single.json` | Single-node configuration |

**Generated files:**
- `genesis.json` — Main genesis file
- `output/genesis_accounts.json` — Account states
- `output/genesis_contracts.json` — Contract bytecodes

> [!IMPORTANT]
> **Re-generate genesis.json before each test run**
> 
> The `lockedUntil` value in StakePool is calculated as `block.timestamp * 1_000_000 + lockupDuration`, meaning the lockup period is relative to the actual block timestamp at genesis execution time. If you reuse an old `genesis.json`, the `lockedUntil` timestamp may already be in the past (or very close to expiring), causing test failures related to stake locking, voting power, or epoch transitions.
> 
> Always run `./scripts/generate_genesis.sh` (or `./scripts/generate_genesis_single.sh`) before starting a new test to ensure a fresh timestamp.

## Documentation

| Specification                                                | Description                                        |
| ------------------------------------------------------------ | -------------------------------------------------- |
| [Overview](spec_v2/overview.spec.md)                         | Architecture overview and design principles        |
| [Foundation](spec_v2/foundation.spec.md)                     | Layer 0: System addresses, types, errors           |
| [Runtime](spec_v2/runtime.spec.md)                           | Layer 1: Timestamp, configs, DKG                   |
| [Staking](spec_v2/staking.spec.md)                           | Layer 2: StakePool factory, bucket withdrawals     |
| [Validator Management](spec_v2/validator_management.spec.md) | Layer 3: Validator lifecycle, epoch transitions    |
| [Blocker](spec_v2/blocker.spec.md)                           | Layer 4: Epoch orchestration, block prologue       |
| [Governance](spec_v2/governance.spec.md)                     | Layer 5: Proposals, voting, execution              |
| [Oracle](spec_v2/oracle.spec.md)                             | Layer 6: Cross-chain data, consensus-gated updates |
| [Randomness](spec_v2/randomness.spec.md)                     | VRF configuration and DKG coordination             |

## Project Structure

```
src/
├── foundation/     # Layer 0: Core types and addresses
├── runtime/        # Layer 1: Timestamp, configs, DKG
├── staking/        # Layer 2: Staking and StakePool
├── blocker/        # Layer 4: Epoch and block management
├── governance/     # Layer 5: On-chain governance
└── oracle/         # Layer 6: External data oracle

genesis-tool/       # Genesis generation tool (Rust)
├── src/            # Rust source code
└── config/         # Genesis configuration files

scripts/
├── generate_genesis.sh  # Genesis generation script
└── helpers/             # Python helper scripts

test/
├── unit/           # Unit tests
├── fuzz/           # Fuzz tests
└── invariant/      # Invariant tests
```

## Design Principles

- **Layered Dependencies** — Higher layers depend only on lower layers
- **Microsecond Time** — All timestamps use `uint64` microseconds
- **Compile-time Addresses** — System addresses inlined for gas efficiency
- **Epoch-Boundary Updates** — Sensitive config changes apply at epoch transitions
- **Two-Role Separation** — Owner (admin) vs Staker (funds) in StakePools
- **Consensus-Gated** — Critical state changes require validator consensus

## License

See [LICENSE](LICENSE) for details.
