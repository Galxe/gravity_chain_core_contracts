# Hardfork Testing Framework

A reusable, automated framework for testing Gravity Chain system contract upgrades (hardforks) using Foundry.

## Architecture

```
test/hardfork/
├── HardforkTestBase.sol              # Generic base (fixture loading, hardfork application, storage verify)
├── HardforkRegistry.sol              # Declarative hardfork definitions (which contracts, post-actions)
├── GammaHardforkBase.t.sol           # Gamma-specific test base (extends HardforkTestBase)
├── GammaHardforkMigration.t.sol      # Phase A1: true v1.0.0 → current migration tests
├── StakingConfigUpgrade.t.sol        # Per-contract upgrade test
├── StakePoolUpgrade.t.sol            # Per-contract upgrade test
├── NativeOracleUpgrade.t.sol         # Per-contract upgrade test
├── GovernanceUpgrade.t.sol           # Per-contract upgrade test
├── FullEpochAfterHardfork.t.sol      # Full epoch lifecycle + fuzz tests
└── fixtures/
    └── gravity-testnet-v1.0.0/       # v1.0.0 bytecodes & storage layouts
        ├── *.hex                     # Runtime bytecodes (19 contracts)
        └── *.storage.json            # Storage layouts (19 contracts)
```

## Quick Start

```bash
# Run all hardfork tests
make hardfork-test

# Run full test suite (including hardfork)
make test
```

## How It Works

The framework simulates hardforks using Foundry's `vm.etch` cheatcode to replace contract bytecodes at fixed system addresses — the same mechanism used by Reth's `apply_<hardfork>()` logic. Storage is preserved across bytecode replacement, mirroring production behavior.

### Key Components

| Component | Role |
|-----------|------|
| **HardforkTestBase** | Generic infrastructure: deploy from fixtures or current code, apply hardfork from registry, snapshot/verify storage |
| **HardforkRegistry** | Declarative definitions — which contracts to upgrade, what post-actions to apply (e.g., init ReentrancyGuard slots) |
| **Fixtures** | Pre-compiled runtime bytecodes + storage layouts from previous versions, extracted via `make extract-fixtures` |
| **Makefile** | Automated fixture extraction, storage layout diffing, test execution |

### Test Tiers

1. **Per-contract upgrade tests** — verify each contract's new features and storage compatibility after bytecode replacement
2. **Integration tests** — full epoch lifecycle (validator churn, staking, config updates, DKG) after hardfork
3. **Migration tests** — load actual old-version bytecodes from fixtures, build a running chain, apply hardfork, verify everything works

## Adding a New Hardfork

### 1. Extract Fixtures

```bash
# Extract bytecodes from the current production tag
make extract-fixtures TAG=<production-git-tag>

# Extract storage layouts for diff analysis
make extract-storage-layouts TAG=<production-git-tag>
```

### 2. Analyze Storage Changes

```bash
# Diff a specific contract
make storage-diff TAG=<production-git-tag> CONTRACT=StakingConfig

# Diff all contracts
make storage-diff-all TAG=<production-git-tag>
```

### 3. Add Registry Entry

In `HardforkRegistry.sol`:

```solidity
function delta() internal pure returns (HardforkDef memory def) {
    def.name = "delta";
    def.fromTag = "<production-git-tag>";
    def.upgrades = new ContractUpgrade[](N);
    def.upgrades[0] = ContractUpgrade(SystemAddresses.STAKE_CONFIG, "StakingConfig");
    // ... only the contracts that changed
    def.postActions = new PostAction[](0); // add if needed
}
```

### 4. Write Tests

```solidity
contract DeltaHardforkBase is HardforkTestBase {
    function setUp() public virtual {
        _deployFromCurrentBytecodes();
        _initializeAllConfigs();
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();
        _fundTestAccounts();
    }

    function _applyDeltaHardfork() internal {
        _applyHardfork(HardforkRegistry.delta());
    }
}
```

### 5. Add Migration Test

```solidity
contract DeltaMigrationTest is HardforkTestBase {
    function setUp() public {
        _fundTestAccounts();
        _deployFromFixtures("<production-git-tag>");
        _initializeAllConfigs();
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();
        // ... set up chain state, then apply hardfork in tests
    }
}
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make extract-fixtures TAG=<tag>` | Extract runtime bytecodes from a git tag |
| `make extract-storage-layouts TAG=<tag>` | Extract storage layout JSONs from a git tag |
| `make storage-diff TAG=<tag> CONTRACT=<name>` | Diff one contract's storage layout (tag vs HEAD) |
| `make storage-diff-all TAG=<tag>` | Diff all contracts' storage layouts |
| `make hardfork-test` | Run all hardfork tests |
| `make test` | Run full test suite |

## CI

The `.github/workflows/hardfork-test.yml` workflow runs automatically on PRs that touch `src/` or `test/hardfork/`, executing hardfork tests and generating a storage layout diff summary in the PR.
