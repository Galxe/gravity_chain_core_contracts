---
name: hardfork-testing
description: "Develop and run hardfork contract upgrade tests for Gravity Chain system contracts. Use this skill whenever the user needs to: (1) test a new hardfork upgrade, (2) extract bytecode fixtures from a previous version, (3) compare storage layouts across versions, (4) add new contract upgrade tests, (5) create migration tests from old to new bytecodes, (6) understand the hardfork testing framework, or (7) debug hardfork-related test failures. Triggers on: hardfork, bytecode upgrade, vm.etch, storage layout diff, epoch transition testing, system contract upgrade, migration test, fixture extraction, or any mention of HardforkTestBase, HardforkRegistry, or GammaHardforkBase."
---

# Hardfork Testing Framework

Gravity Chain uses bytecode replacement at fixed system addresses for hardfork upgrades. This skill documents the automated testing framework built on Foundry to verify contract upgrades are safe and correct.

## When to Use This Skill

- Creating tests for a new hardfork (e.g., Delta, Epsilon)
- Extracting bytecode fixtures from a previous production version
- Analyzing storage layout changes between versions
- Debugging hardfork test failures
- Understanding the testing framework architecture
- Adding new system contracts to the hardfork pipeline

## Framework Overview

Read `test/hardfork/README.md` for the complete framework documentation. The key files are:

| File | Purpose |
|------|---------|
| `test/hardfork/HardforkTestBase.sol` | Generic base contract with fixture loading, hardfork application, storage verification |
| `test/hardfork/HardforkRegistry.sol` | Declarative hardfork definitions (contracts to upgrade + post-actions) |
| `Makefile` | Automated fixture extraction, storage diffing, test execution |
| `.github/workflows/hardfork-test.yml` | CI pipeline for hardfork tests |

## Step-by-Step: Adding a New Hardfork

### Step 1: Extract Fixtures

Use the Makefile to extract bytecodes and storage layouts from the current production tag:

```bash
make extract-fixtures TAG=<production-git-tag>
make extract-storage-layouts TAG=<production-git-tag>
```

This creates `test/hardfork/fixtures/<tag>/` with `.hex` (runtime bytecode) and `.storage.json` (storage layout) files for all 19 system contracts.

### Step 2: Analyze Storage Changes

Before writing any tests, review storage layout changes:

```bash
make storage-diff-all TAG=<production-git-tag>
```

This shows which contracts have new, removed, or changed storage slots. Pay special attention to:

- **New fields added at end** → safe, storage compatible
- **New fields inserted in middle** → DANGEROUS, storage collision
- **Type changes on existing fields** → DANGEROUS, data misinterpretation
- **New storage struct via ERC-7201** → safe (isolated slot)

### Step 3: Add Registry Entry

In `test/hardfork/HardforkRegistry.sol`, add a new function returning a `HardforkDef`:

```solidity
function delta() internal pure returns (HardforkDef memory def) {
    def.name = "delta";
    def.fromTag = "<production-git-tag>";

    // Only include contracts that have changed
    def.upgrades = new ContractUpgrade[](N);
    def.upgrades[0] = ContractUpgrade(SystemAddresses.STAKE_CONFIG, "StakingConfig");
    // ...

    // Post-actions for storage patches needed after bytecode replacement
    def.postActions = new PostAction[](0);
}
```

**Key decision: which contracts to include?** Run `git diff <old-tag>..HEAD -- src/` to see which source files changed. Only include changed contracts in the upgrade list.

### Step 4: Create Test Base

Create a hardfork-specific base contract extending `HardforkTestBase`:

```solidity
// test/hardfork/DeltaHardforkBase.t.sol
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

### Step 5: Write Per-Contract Upgrade Tests

For each changed contract, create a test file verifying:

1. **Storage preservation** — critical slot values survive bytecode replacement
2. **New features** — new functions work correctly after upgrade
3. **Removed features** — old functions revert or behave as expected
4. **Access control** — permissions unchanged
5. **Edge cases** — zero addresses, overflow, reentrancy

Use `_snapshotStorage()` and `_verifyStoragePreserved()` from the base:

```solidity
function test_storagePreserved() public {
    bytes32[] memory slots = new bytes32[](3);
    slots[0] = bytes32(uint256(0)); // first state variable
    slots[1] = bytes32(uint256(1)); // second state variable
    slots[2] = bytes32(uint256(2)); // third state variable
    _snapshotStorage(contractAddress, slots);

    _applyDeltaHardfork();

    _verifyStoragePreserved(); // asserts all snapshotted values unchanged
}
```

### Step 6: Write Migration Test

Create a true pre→post migration test using fixture bytecodes:

```solidity
contract DeltaMigrationTest is HardforkTestBase {
    function setUp() public {
        _fundTestAccounts();
        _deployFromFixtures("<production-git-tag>");
        _initializeAllConfigs();
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();
        // Create validators, run epochs on old code...
    }

    function test_migration_epochTransition() public {
        _applyHardfork(HardforkRegistry.delta());
        _completeEpochTransition();
        assertEq(validatorManager.getActiveValidatorCount(), 2);
    }
}
```

### Step 7: Integration Tests

Write full epoch lifecycle tests covering:

- Multiple epoch transitions after hardfork
- Validator join/leave/churn after hardfork
- Staking operations (addStake, unstake, withdrawRewards)
- Configuration updates (pending config pattern)
- DKG session completion
- Fuzz testing across multiple epochs

### Step 8: Verify

```bash
# Run hardfork tests only
make hardfork-test

# Run full suite (regression check)
make test
```

## Common Patterns

### StakePool Bytecode Extraction

`StakePool` has a complex constructor that calls system contracts. To extract its runtime bytecode for `vm.etch`, use the factory:

```solidity
vm.prank(someUser);
address refPool = staking.createPool{value: MIN_STAKE}(owner, owner, owner, owner, lockedUntil);
bytes memory newPoolCode = refPool.code;
vm.etch(targetPool, newPoolCode);
```

### ReentrancyGuard Slot Initialization

When upgrading to code that uses `ReentrancyGuard`, the ERC-7201 namespaced storage slot must be initialized:

```solidity
bytes32 RG_SLOT = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
vm.store(poolAddress, RG_SLOT, bytes32(uint256(1))); // NOT_ENTERED
```

This is handled automatically by `PostAction` entries in the registry with `isDynamic: true`.

### Governance Constructor Workaround

`Governance` inherits `Ownable`, which rejects `address(0)` in the constructor. Since only the bytecode is etched (storage preserved), use `address(1)`:

```solidity
vm.etch(SystemAddresses.GOVERNANCE, address(new Governance(address(1))).code);
```

### vm.prank Consumption

`vm.prank` is consumed by the NEXT external call, including view calls. If you need to read a value and then call a function, cache the value first:

```solidity
// BAD: vm.prank consumed by view call
vm.prank(caller);
uint256 val = contract.viewFunction(); // prank consumed here!
contract.stateChangingFunction();      // NOT pranked

// GOOD: cache before prank
uint256 val = contract.viewFunction();
vm.prank(caller);
contract.stateChangingFunction();
```

## Foundry Cheatcodes Reference

| Cheatcode | Use in Hardfork Testing |
|-----------|------------------------|
| `vm.etch(addr, code)` | Replace contract bytecode at address |
| `vm.store(addr, slot, val)` | Write storage slot (e.g., init ReentrancyGuard) |
| `vm.load(addr, slot)` | Read storage slot for verification |
| `vm.readFile(path)` | Load fixture hex files |
| `vm.parseBytes(hexStr)` | Convert hex string to bytes |
| `vm.prank(addr)` | Impersonate address for next call |
| `vm.expectRevert(selector)` | Assert next call reverts |
| `vm.deal(addr, val)` | Set ETH balance |

## Troubleshooting

### "vm.readFile: failed to open file"

Ensure `fs_permissions` is set in `foundry.toml`:

```toml
fs_permissions = [{ access = "read", path = "test/hardfork/fixtures" }]
```

### "TimestampMustEqual" error in setUp

`Blocker.initialize()` calls `updateGlobalTime(SYSTEM_CALLER, 0)` which requires timestamp == 0. Call `_initializeReconfigAndBlocker()` BEFORE `_setInitialTimestamp()`.

### "OwnableInvalidOwner" when etching Governance

Use `address(1)` as the constructor argument, not `address(0)`. See the Governance Constructor Workaround above.

### Voting Power Increase Limit

When adding validators, the total voting power can only increase by `VOTING_POWER_INCREASE_LIMIT` percent per epoch. Use multiple epoch transitions or ensure initial validators have large enough stakes to accommodate new joins.
