# Verdict — gravity-audit #567 (also covers #559)

**Issue**: [Critical] `Governance._owner` is zero at genesis — `addExecutor` is permanently un-callable, bricking all proposal execution.

**Labeled status**: `OPEN`, severity `critical`. Static auditor verdict: `EXISTS` (high confidence).

## What this PoC tests

This is a **live-bug verification** (not A/B) because the root cause is the *absence* of a genesis seeding step rather than a code change — there is no "pre-fix commit" to contrast against. The PoC mimics the production predeploy pathway:

1. Uses `vm.etch(SystemAddresses.GOVERNANCE, Governance.runtimeCode)` — equivalent to `genesis-tool`'s `deploy_bsc_style` which writes only runtime bytecode at the canonical address (constructor bypassed).
2. Does **not** copy slot 0 / slot 1 from a temp deployment. The project's own unit-test harness (`test/unit/governance/Governance.t.sol:110-121`) *does* copy them via `vm.load`+`vm.store`; that workaround exists precisely because production genesis leaves them zero.
3. Asserts the bricked state end-to-end.

## Dynamic test on main (`a623eab`)

`forge test -vv` result: **PASS** — all four assertions hold:

| # | Assertion | Observed |
|---|---|---|
| 1 | `governance.owner() == address(0)` | confirmed |
| 1b | sanity: a normally-constructed `new Governance(intendedOwner)` *does* have `owner()==intendedOwner` | confirmed (bytecode is fine; flaw is seeding) |
| 2 | `addExecutor(x)` reverts for `anyCaller` AND for `intendedOwner` | both revert |
| 3 | Recovery paths blocked: `transferOwnership` reverts (onlyOwner), `acceptOwnership` reverts (pendingOwner==0), `renounceOwnership` reverts (explicitly disabled) | all three revert |
| 4 | `execute(...)` reverts (no executors in set, so `onlyExecutor` fails before reaching any proposal lookup) | confirmed |

Test polarity follows pipeline convention: `test_attackSucceedsIfVulnerable` PASSES on vulnerable code, would FAIL on a fix that seeds `_owner` at genesis.

Output: [`results/main_a623eab.txt`](./main_a623eab.txt).

## Implication for the static EXISTS verdict

**PoC confirms the static EXISTS verdict.** Every step 1-7 in `auditor_567.json`'s data-flow trace is directly observable at the Solidity level:

- Step 1 (constructor never runs at predeploy) is demonstrated by `vm.etch` producing `owner()==0`.
- Step 5 (`addExecutor` reverts `OwnableUnauthorizedAccount`) is demonstrated by the low-level calls returning `success==false`.
- Step 6 (`execute` fails onlyExecutor) is demonstrated directly.
- Step 7 (recovery impossible) is demonstrated via `transferOwnership` / `acceptOwnership` / `renounceOwnership` all failing.

**Dynamic confidence: HIGH** on the Solidity layer. The impact claimed by the static auditor (all proposal execution permanently bricked) is reproduced directly.

## Residual concerns / open questions

The one concern the PoC **cannot** close is **out-of-band node-side seeding**. The static report's own counterargument notes this:

> The strongest argument against EXISTS would be: perhaps the gravity-reth node applies a hardcoded state override at chain start that seeds slot 0 of GOVERNANCE_ADDR.

This repository only contains the Solidity contracts and the Rust `genesis-tool` (which demonstrably does not seed slot 0). A live gravity-reth node in the `gravity-reth` repo *could*, in principle, apply an out-of-repo state override at chain start. The static auditor judged this unlikely because:

- There is no config field, hook, or marker in the Solidity/Rust sources telling the node which address should own Governance.
- The unit-test harness's explicit `vm.store` workaround is a strong tell: if the node seeded slot 0, the test could have followed the same pattern (e.g. reading from a config artifact).

The PoC is consistent with that reasoning — on the code that is in-repo, the exploit path is complete end-to-end. To **fully** close the loop, one would need to either inspect the gravity-reth node's genesis-loading code or run the node against a freshly-generated genesis and query `Governance.owner()` on-chain.

## Covers issue #559

#559 reports the same root cause (Governance predeploy lacking owner initialization). The PoC's findings apply verbatim — fixing the genesis-tool + Genesis.sol to call `addExecutor`/`transferOwnership` on Governance (or to seed slot 0 directly) closes both issues.

## Recommended mitigation

Two independent options (pick one; ideally defense-in-depth with both):

1. **Genesis.sol-side**: add an explicit `Governance(SystemAddresses.GOVERNANCE)` initializer call inside `Genesis.initialize()` — e.g. a new `initialize(address owner, address[] executors)` entrypoint guarded by `onlyGenesis`. This keeps the owner-seed on-chain, auditable from Solidity alone, and makes the predeploy self-sufficient.
2. **genesis-tool-side**: add an explicit storage-seeding step in `deploy_bsc_style` that, for Governance, writes slot 0 (`_owner`) and optionally slot 1 (`_pendingOwner`) from a new `governanceOwner` config field in `GenesisConfig`. Mirrors what the Solidity unit-test harness already does via `vm.store`.

## Files

- `test/POC_567.t.sol` — self-contained PoC, 4 assertion clusters, ~120 lines
- `results/main_a623eab.txt` — `forge test -vv` log on current `main` (PASS, 1 test)
