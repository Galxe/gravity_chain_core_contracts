# Pilot A — Static Auditor calibration report

**Date**: 2026-04-20
**Scope**: 8 ground-truth + 1 PoC-verified live-bug (#476) = 9 issues
**Codebase**: `gravity_chain_core_contracts` @ `main` `a623eab`
**Method**: Single `general-purpose` Auditor agent per issue, blind to `status:` labels. Data-flow per-step trace with hard file:line citation rule.

## Headline result: **9/9 agree with ground truth**

| # | Label / ground truth | Agent verdict | Conf | Hint | Match |
|---|---|---|---|---|---|
| #273 | fixed-on-main (+ PoC A/B verified) | NOT_EXISTS | high | fixed | ✓ |
| #275 | fixed-on-main | NOT_EXISTS | high | fixed | ✓ |
| #290 | fixed-on-main | NOT_EXISTS | high | fixed | ✓ |
| #394 | fixed-on-main | NOT_EXISTS | high | fixed | ✓ |
| #395 | false-positive | NOT_EXISTS | high | — (behavioral FP) | ✓ (equivalent) |
| #396 | fixed-on-main | NOT_EXISTS | high | — | ✓ |
| #398 | fixed-on-main | NOT_EXISTS | high | fixed | ✓ |
| #401 | false-positive | NOT_EXISTS | high | **fixed** | see note |
| #476 | OPEN (PoC: live) | **EXISTS** | high | cannot_tell | ✓ |

### Note on #401 — the only label/hint divergence

Agent classified #401 as "fixed" rather than "fp". Reading the Auditor report: the issue's
`setMinimumStake` / `setLockupDurationMicros` / `setUnbondingDelayMicros` / `setMinimumProposalStake`
functions were *removed entirely* in commit `49dce4a` (PR #33) and replaced by a single `setForNextEpoch`.
From "does the vulnerability exist now" perspective the answer is unambiguously no — so NOT_EXISTS
is correct. The `fp` vs `fixed` hint distinction is philosophical: the finding was valid at the
time of writing but was eliminated structurally. I'd count this as `NOT_EXISTS` agreement with
a legitimate difference in after-the-fact categorization.

## Depth quality check (per-issue structural stats)

| # | trace steps | evidence | tests found | blocked_at |
|---|---|---|---|---|
| 273 | 6 | 3 | 7 | [2] |
| 275 | 5 | 4 | 0 | [4] |
| 290 | 4 | 5 | 0 | [2] |
| 394 | 4 | 3 | 1 | [3] |
| 395 | 6 | 4 | 1 | [5] |
| 396 | 7 | 3 | 0 | [2, 4, 5, 7] |
| 398 | 6 | 5 | varies | [1] |
| 401 | 4 | 5 | 1 | [2] |
| 476 | 5 | 4 | 0 | [] |

Total: 47 data-flow steps independently traced and cited. 36 concrete `key_evidence` code excerpts.

## Representative findings — agent going beyond surface pattern match

- **#396**: Agent identified the issue's claim ("inner recomputation loop O(n²)") as structurally false in current code — the loop was hoisted into a single O(activeLen) pre-pass, and `_isInPendingInactive` is now **dead code (0 callers)**. Agent noticed this without prompting.
- **#398**: Agent recognised that the exploit primitive — "mid-epoch immediate setter" — ceased to exist because the entire setter family was replaced by the pending-config pattern. Verified by NatSpec reference.
- **#401**: Agent located the exact fix commit hash (`49dce4a`) and PR (#33, 2026-02-27) — exceeds expected behavior.
- **#476**: Agent confirmed all 5 exploit steps intact, noted line-number drift from issue (_canTransition at 215-219 not 208-212), and correctly observed existing tests cover `== 0` but not `uint64.max`.

## Failure modes not observed

- No hallucinated file:line references (all evidence verified by jq / Grep spot-check).
- No vague verdicts — every `reasoning_chain` names a specific step + specific guard.
- No shallow agreement — counterargument field produced real adversarial alternatives in 9/9 cases.

## Cost

Per-agent: 28k-53k tokens, 93-1596 seconds. Parallel batch of 7: ~26 min wall clock (longest-pole bound).

## Implications for (C) — scaling to remaining 263 contracts issues

Static Auditor alone (no Reviewer, no PoC) is **highly reliable when ground truth is clear**. The 9/9
result in this pilot was achieved **without** the adversarial Reviewer step I had originally planned.
This suggests:

1. For the batch-triage pass of 263 issues, **single-Auditor is sufficient as primary classifier**.
2. Reviewer / Judge / dynamic PoC should be reserved for:
   - `UNCERTAIN` / `PARTIAL` verdicts
   - Cases where Auditor finds `EXISTS` in an OPEN critical/high issue (claim: "bug is live"
     — this is actionable; warrants a PoC if feasible)
   - Spot-check: ~5% random sample for QA drift detection
3. Expected throughput at 15 parallel agents: ~15 issues / 10 min wall clock ≈ **full 263 sweep in 3-4 hours**.
