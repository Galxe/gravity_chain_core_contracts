# PoC Pipeline — Recipe for dynamic A/B verification of gravity-audit issues

Use this when you want ground-truth animal-level evidence that (a) an issue's
exploit reproduces on the pre-fix commit and (b) the fix on `main` actually
closes it. One self-contained foundry project per issue, reusable fixtures.

## Directory layout

```
.audit-recheck/poc/
├── PIPELINE.md              # this file
└── <issue_number>/
    ├── foundry.toml         # per-issue foundry config (isolated cache/out)
    ├── remappings.txt
    ├── lib/                 # symlinks into gravity_core (created once)
    │   ├── gravity_src   -> ../../../../external/gravity_core/src
    │   └── node_modules  -> ../../../../external/gravity_core/node_modules
    ├── src/                 # attacker contracts etc (when needed)
    ├── test/                # POC_<issue_number>.t.sol
    └── results/
        ├── old_<commit>.txt
        ├── new_<commit>.txt
        └── verdict.md
```

Key design choices:
- **Symlinks into gravity_core** instead of out-of-tree imports, so foundry
  treats sources as project-local (foundry's default `allow_paths` blocks paths
  outside the project root).
- **Per-issue foundry project** so each PoC has its own cache/out and
  compilation is independent (also lets you tune optimizer/solc per issue).
- **Commits are switched inside `external/gravity_core`, not inside the PoC**.
  The symlinks transparently follow whatever `gravity_core` points to.

## Boilerplate files

### `foundry.toml`
```toml
[profile.default]
src = "src"
test = "test"
out = "out"
cache_path = "cache"
solc = "0.8.30"
optimizer = true
optimizer_runs = 200
via_ir = true
auto_detect_solc = false
verbosity = 3
evm_version = "cancun"
```

### `remappings.txt`
```
@openzeppelin/=lib/node_modules/@openzeppelin/contracts/
forge-std/=lib/node_modules/forge-std/src/
@gravity/=lib/gravity_src/
```

### Symlinks (create once per issue dir)
```bash
mkdir -p lib
ln -sfn ../../../../external/gravity_core/src          lib/gravity_src
ln -sfn ../../../../external/gravity_core/node_modules lib/node_modules
```

## Writing the PoC test

Convention for pass/fail semantics:
- `test_attackSucceedsIfVulnerable` — assert post-state consistent with successful
  exploit. PASS on vulnerable commit, FAIL on fixed commit.

Reasons for this polarity over `vm.expectRevert`:
- Works when pre-fix and post-fix use **different revert reasons** (or no
  revert at all in pre-fix).
- `forge test` exit status is a clean binary readout of "exploit reproduced".

### Skeleton

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Staking } from "@gravity/staking/Staking.sol";
// ... other @gravity imports

contract POC_XXX is Test {
    // ... declarations
    function setUp() public {
        // vm.etch each system contract at SystemAddresses.*
        // vm.prank(SystemAddresses.GENESIS) → initialize
        // vm.prank(SystemAddresses.BLOCK) → set timestamp
        // vm.deal attacker / test accounts
    }

    function test_attackSucceedsIfVulnerable() public {
        // create pool / set up preconditions
        // vm.prank(attacker) → trigger vulnerable path
        // assert post-state matches successful exploit
    }
}
```

## Handling API drift across commits

Signatures can differ between the pre-fix base commit and main (e.g. #273's
`StakingConfig.initialize` took 4 args at `27b22c3`, now takes 3 on `main`).

Use low-level `call` with signature fallback. `vm.prank` only applies to the
next external call, so each attempt needs its own prank:

```solidity
function _initStakingConfigEither() internal {
    vm.prank(SystemAddresses.GENESIS);
    (bool ok4,) = address(stakingConfig).call(
        abi.encodeWithSignature(
            "initialize(uint256,uint64,uint64,uint256)",
            MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_STAKE
        )
    );
    if (ok4) return;

    vm.prank(SystemAddresses.GENESIS);
    (bool ok3,) = address(stakingConfig).call(
        abi.encodeWithSignature(
            "initialize(uint256,uint64,uint64)",
            MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY
        )
    );
    require(ok3, "neither signature worked");
}
```

Rule of thumb: any call whose signature you aren't 100% sure is stable across
the two commits should go through this pattern.

## Running the A/B

Assume cwd = `.audit-recheck/poc/<issue>/` and initial state = `main`.

```bash
# 1. Baseline on main (fixed) — expect FAIL
forge clean && forge test -vv 2>&1 | tee results/new_<commit>.txt

# 2. Switch core to pre-fix commit
git -C ../../../external/gravity_core checkout <pre_fix_commit>
forge clean && forge test -vv 2>&1 | tee results/old_<commit>.txt

# 3. Restore main
git -C ../../../external/gravity_core checkout main
```

Always end by restoring `main` so subsequent static audits see the latest code.

## Base commit discovery

Which commit to use as the "pre-fix" baseline?

- Prefer `Base Commit` from the tracking issue body (e.g. #526 records the
  Coacker audit base commit as `27b22c37160460196b22a161ad935a9c947a28bc`).
- Fallback: the latest tag **before** the issue was filed (issue `createdAt`
  field + `git log --before=...`).

## One-time setup (gravity_core deps)

`node_modules` isn't vendored. Once per machine:

```bash
cd external/gravity_core && npm install
```

Takes ~40s, installs `@openzeppelin/contracts` 5.5.0 and `forge-std` v1.12.0.
Node_modules is `.gitignore`d in gravity_core, so this is non-destructive.

## Pitfalls seen

1. **`File outside of allowed directories`** — foundry sandboxes source paths
   to the project root by default. Solution: symlinks inside `lib/` (not
   `--allow-paths`, which muddies reproducibility).
2. **Signature drift** — see API-drift section above. Static imports will
   compile-fail on one of the two commits; use low-level `call`.
3. **Stale cache after commit switch** — always `forge clean` before the second
   run. Foundry's artifact cache can latch to the wrong source version.
4. **`yarn` vs `npm`** — project ships `yarn.lock` but many machines lack yarn.
   `npm install` works on this `package.json` (only devDependencies).
5. **`gravity_core` left on a detached HEAD** — after a spike, `git checkout
   main` inside gravity_core before moving on, otherwise later audits read
   stale source.

## Per-issue checklist

- [ ] Read the issue body: Data Flow section + Recommended Fix
- [ ] Confirm a pre-fix commit exists that exhibits the exploit
- [ ] Identify state invariant(s) broken by the exploit — the PoC's assert target
- [ ] Copy skeleton, adapt setUp, write single `test_attackSucceedsIfVulnerable`
- [ ] Run on main → confirm FAIL
- [ ] `git checkout <pre_fix>` → confirm PASS
- [ ] Restore main
- [ ] Write `results/verdict.md` summarizing A/B + verdict + residual concerns
