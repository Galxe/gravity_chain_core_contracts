# Verdict — gravity-audit #554

**Issue**: [High] Voting power is live-read, not snapshotted — mid-vote `addStake` inflates remaining power on subsequent `vote` calls.

**Target**: current `main` (`external/gravity_core` @ `a623eab`).

## Dynamic test on main (`a623eab`)

`forge test -vv` — **PASS** (one test, `test_attackSucceedsIfVulnerable`).

Full log: `results/main_a623eab.txt`.

### Observed exploit chain

| Step | Action | Observed |
|---|---|---|
| 0 | `Staking.createPool{value: 10 ETH}` with delegated `voter` | pool created, `activeStake == 10 ETH (P1)`, `lockedUntil = now + 14 days` |
| 1 | `voter → Governance.createProposal(pool, …)` | proposalId=1, `expirationTime = now + 1 day`, snapshot-era power P1 = 10 ETH |
| 2 | `voter → vote(pool, id, V1=1 ETH, yes)` | `usedVotingPower = 1 ETH`, `remaining = 9 ETH` |
| 3 | time advances 1 µs; `attackerStaker → StakePool.addStake{value: 90 ETH}` | `activeStake = 100 ETH`, `lockedUntil` auto-extends to `now + 14 days` (covers `expirationTime`) |
| 4 | `getPoolVotingPower(pool, expirationTime)` (live read) | returns **100 ETH** — inflated |
| 5 | `getRemainingVotingPower(pool, id)` | returns **99 ETH** ( = (P1 + X) − V1 ) |
| 6 | `voter → vote(pool, id, type(uint128).max, yes)` | voting power capped at `remaining`; `yesVotes` now **100 ETH** |

### Final assertions (all hold)

- `usedVotingPower > snapshotPower` → **100 ETH > 10 ETH** ✓
- `usedVotingPower == P1 + X` → **100 ETH == 10 + 90 ETH** ✓
- `proposal.yesVotes == P1 + X` → **100 ETH** ✓

## Verdict

- **Issue is a live true positive on `main`** — `agrees_with_static_exists = true`.
- The pool's total cast voting weight (`100 ETH`) exceeds the snapshot-era voting power (`10 ETH`) by exactly the mid-vote addStake amount (`90 ETH`). This is precisely the EC4 / C10 violation the reporter described.
- `getRemainingVotingPower` (Governance.sol:178-197) performs a live read of `_staking().getPoolVotingPower(pool, p.expirationTime)` on every `vote` call. No snapshot of pool power is stored at proposal creation. Under typical config (`lockupDuration >= votingDuration`, here 14d vs 1d), `addStake` auto-extends `lockedUntil` to cover `expirationTime`, so the freshly added stake counts as effective at `atTime` in `_getEffectiveStakeAt` (StakePool.sol:675-708).

## Recommended mitigation

The fix requires persisting voting power at proposal creation and reading from the snapshot in subsequent `getRemainingVotingPower` / `vote` calls. Two canonical options:

1. **Persist `poolPowerAtCreation[proposalId]`** in the Proposal struct (or a sibling mapping) and use it in `getRemainingVotingPower` instead of the live read. Low overhead: one `uint256` per proposal.
2. **Snapshot-on-first-vote**: at each pool's first vote on a proposal, cache `pool.getVotingPower(expirationTime)` in `mapping(pool => proposalId => uint256) votingPowerSnapshot`; subsequent votes from that pool read the cached value. Slightly more state but avoids recomputation across many pools for proposals where most pools never vote.

Either approach closes the attack. A defence-in-depth complement — freezing `addStake` while any active proposal exists — is NOT recommended because it conflates governance and staking lifecycles and would break legitimate flows.

## Notes on the PoC setup

- `StakingConfig.initialize` signature: only the 3-arg form (`uint256,uint64,uint64`) exists on `main` (a623eab) — the `minimumProposalStake` 4th arg has been dropped. The PoC tries 3-arg first, falls back to 4-arg, covering both.
- `Governance` was deployed directly (not `vm.etch`ed at `SystemAddresses.GOVERNANCE`) because `nextProposalId` is a state-var initialiser (`= 1`) that relies on the constructor — etching would zero it, tripping the `InvalidProposalId()` guard. Nothing in the exploit path reads `SystemAddresses.GOVERNANCE` (Governance is the caller, not a callee), so canonical-address binding isn't needed for this PoC.
- `ValidatorManagement` and `Reconfiguration` are minimal mocks (`isValidator → false`, `isTransitionInProgress → false`) — enough to satisfy `Staking.createPool` and `StakePool.whenNotReconfiguring`. We never exercise the unstake or validator-bond paths, so richer mocks aren't needed.
- The time advance between V1 and addStake (`+1 µs`) is not load-bearing for the bug (addStake works at any `now < expirationTime`); it's there to mirror the cross-block nature of the real attack described in the issue body.

## Files

- `test/POC_554.t.sol` — self-contained PoC.
- `results/main_a623eab.txt` — forge test run log (PASS).
