# attack_governance_voting_execution

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 80836ms
- **Steps**: 1

## Report

Now I have enough context. Here is my attack findings report:

---

# Governance Contract — Red Team Attack Findings

## Finding 1: Voting Power Inflation via Mid-Proposal Stake Addition (High)

**Severity: High**

**Location:** `Governance.sol:403` (`getRemainingVotingPower`) + `StakePool.sol:283` (`addStake`)

**Description:** Voting power is queried dynamically via `_staking().getPoolVotingPower(stakePool, p.expirationTime)` every time a vote is cast. It is **not snapshotted at proposal creation**. A voter can:

1. Create a proposal with a pool that has `X` stake (meeting `requiredProposerStake`)
2. Vote with `X` power
3. Add more stake to the pool via `addStake()` (which increases `activeStake`)
4. Vote again — `getRemainingVotingPower` now returns the newly added stake as remaining power
5. Repeat until the vote count is arbitrarily inflated

The `usedVotingPower` tracking only prevents double-spending of power *at the time of each read*, but if the underlying pool power grows between votes, new power becomes available. This allows a single pool to multiply its vote influence during the voting period.

**Impact:** A well-funded attacker can incrementally inflate voting power to pass any proposal, bypassing the intended quorum mechanism. The economic cost is only the staking itself (no tokens lost), making this essentially free vote amplification.

---

## Finding 2: Voter Delegation Swap — Vote With Stolen/Orphaned Power (Medium)

**Severity: Medium**

**Location:** `Governance.sol:102-108` (`_requireVoter`) + `StakePool.sol:257` (`setVoter`)

**Description:** The pool owner can call `setVoter(newVoter)` at any time. The governance contract checks `msg.sender == pool.getVoter()` at the time of each vote — there is no binding between a proposal and the voter who created it.

**Attack scenario:**
1. Voter A creates a proposal using Pool P
2. Pool owner changes voter from A to B via `setVoter(B)`
3. Voter A can no longer vote on their own proposal with Pool P
4. Voter B inherits all **unused** voting power on Pool P for the existing proposal

This is a griefing vector: the pool owner can deny the proposer from voting on their own proposal by swapping the voter mid-vote. More critically, if the voter role is traded/sold, the new voter inherits all previously-unused voting power across all active proposals.

---

## Finding 3: No Expiration on Succeeded Proposals — Indefinite Execution Window (Medium)

**Severity: Medium**

**Location:** `Governance.sol:472-521` (`execute`)

**Description:** Once a proposal reaches `SUCCEEDED` state (after resolution), there is **no time limit** on when it can be executed. A proposal that was valid at creation time could be executed months or years later, when the system context has completely changed.

**Attack scenario:**
1. A proposal to set parameter X to value Y passes governance
2. The executor intentionally delays execution
3. Months later, value Y is now harmful to the protocol (e.g., a fee parameter that was safe then but destructive now)
4. The executor calls `execute()` — all checks pass since the proposal is still `SUCCEEDED`

The `executed` flag prevents replay, but the lack of an execution deadline creates a time-bomb risk.

---

## Finding 4: `execute()` Discards Return Data — Silent Partial Failure Masking (Medium)

**Severity: Medium**

**Location:** `Governance.sol:514`

```solidity
(bool success,) = targets[i].call(datas[i]);
```

**Description:** The return data from each call is completely discarded. While `success == false` causes a revert, this pattern has two issues:

1. **No revert reason propagation**: When a call fails, `ExecutionFailed(proposalId)` is emitted with no inner error context, making debugging impossible
2. **Calls that return `success = true` but do not actually succeed**: Some contracts return `true` from `call()` even when the operation fails logically (e.g., ERC20 `transfer` returning `false` on failure rather than reverting). These would be treated as successful.

If any target in the batch is an EOA (no code), `call()` returns `success = true` with empty return data — the governance system would consider this a successful execution of a no-op.

---

## Finding 5: Proposal State Inconsistency — `getProposalState` Diverges Before and After `resolve()` (Medium)

**Severity: Medium**

**Location:** `Governance.sol:135-168` (`getProposalState`)

**Description:** The `getProposalState` function computes the state identically whether `isResolved` is true or false (lines 151 and 164 use the same condition). This means the state is **computable before resolution**, but `execute()` requires `SUCCEEDED` which is available before `resolve()` is called.

However, `execute()` calls `getProposalState()` which at line 144 checks `executed[proposalId]` first, then at 149 checks `p.isResolved`. If the proposal is not yet resolved but voting has ended, the code falls through to lines 163-167 and returns `SUCCEEDED` or `FAILED` anyway.

**This means `resolve()` is not actually required before `execute()`** — an executor can execute a proposal that has never been formally resolved, as long as voting has ended and the vote counts satisfy the threshold. The `resolve()` function becomes ceremonial.

While not directly exploitable, this contradicts the documented lifecycle (`PENDING → resolve → SUCCEEDED → execute → EXECUTED`) and could cause off-chain systems that wait for `ProposalResolved` events to be blindsided by executions.

---

## Finding 6: `nextProposalId` Overflow Wraps to Sentinel (Low, Defence-in-Depth Present)

**Severity: Low** (mitigated by line 307)

**Location:** `Governance.sol:310`

**Description:** `nextProposalId` is `uint64`. After `2^64 - 1` proposals, the post-increment wraps to 0. The defence-in-depth check at line 307 catches this (`if (nextProposalId == 0) revert`), but the check happens **before** the increment. The last valid proposal would be ID `2^64 - 1`, and the next call would have `nextProposalId == 0` which reverts — correct behavior. This is properly handled.

---

## Summary

| # | Finding | Severity | Exploitable? |
|---|---------|----------|-------------|
| 1 | Voting power inflation via mid-proposal stake addition | **High** | Yes — add stake between votes to inflate power |
| 2 | Voter delegation swap orphans proposal/inherits power | **Medium** | Yes — pool owner can grief proposer |
| 3 | No execution deadline on succeeded proposals | **Medium** | Yes — stale proposals can be time-bombed |
| 4 | Return data discarded in execute — silent no-ops on EOAs | **Medium** | Yes — proposals targeting EOAs silently succeed |
| 5 | `resolve()` is not required before `execute()` | **Medium** | No direct exploit, but breaks event-driven integrations |
| 6 | `nextProposalId` overflow | **Low** | No — properly guarded |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | Now I have enough context. Here is my attack findings report | 80836ms |
