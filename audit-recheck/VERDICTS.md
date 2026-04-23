# VERDICTS — Full 64-issue Table

64 issues reviewed, grouped by severity then verdict. PoC-confirmed issues marked ✅.

## Summary by severity × verdict

| Severity | EXISTS | PARTIAL | NOT_EXISTS | Total |
|---|---:|---:|---:|---:|
| Critical | 5 | 0 | 2 | 7 |
| High | 14 | 3 | 17 | 34 |
| Medium | 6 | 3 | 12 | 21 |
| Low | 0 | 0 | 2 | 2 |
| **Total** | **25** | **6** | **33** | **64** |

## Full table

| # | Sev | Verdict | Conf | Hint | PoC | Title |
|---|---|---|---|---|---|---|
| #452 | critical | EXISTS | high | cannot_tell | ✅476 | [Critical] EpochConfig.setForNextEpoch missing upper bound → uint64  |
| #472 | critical | EXISTS | high | cannot_tell | ✅476 | [Critical] EpochConfig.setForNextEpoch no upper bound → epochInterva |
| #476 | critical | EXISTS | high | cannot_tell | ✅476 | [Critical] EpochConfig.setForNextEpoch no upper bound — epochInterva |
| #559 | critical | EXISTS | high | cannot_tell | ✅567 | [Critical] Governance predeploy constructor skipped — _owner=0 and n |
| #567 | critical | EXISTS | high | cannot_tell | ✅567 | [Critical] Governance._owner is zero at genesis — addExecutor is per |
| #273 | critical | NOT_EXISTS | high | fixed | ✅273 A/B | [Critical] renewLockUntil has no upper-bound cap — compromised stake |
| #403 | critical | NOT_EXISTS | high | fixed |  | [Critical] Unbounded lockupDurationMicros governance parameter causes  |
| #301 | high | EXISTS | high | cannot_tell |  | [High] bridgeToGravityWithPermit permit front-running causes persisten |
| #339 | high | EXISTS | high | cannot_tell | ✅339 | [High] Double governanceReconfigure() in governance batch causes mass  |
| #357 | high | EXISTS | high | cannot_tell | ✅339 | [High] governanceReconfigure() lacks time guard, enabling rapid epoch  |
| #367 | high | EXISTS | high | cannot_tell |  | [High] Genesis validator initialization bypasses consensus pubkey PoP  |
| #397 | high | EXISTS | high | cannot_tell | ✅476 | [High] Governance-settable epochIntervalMicros lacks upper bound, enab |
| #420 | high | EXISTS | high | cannot_tell |  | [High] removeExecutor() has no min-count guard — executor set deplet |
| #439 | high | EXISTS | high | cannot_tell | ✅476 | [High] Unbounded epochIntervalMicros → uint64 overflow in _canTransi |
| #444 | high | EXISTS | high | cannot_tell | ✅494 | [High] O(N²) SSTORE cost in _insertSortedIssuer permanently freezes J |
| #462 | high | EXISTS | high | cannot_tell | ✅339 | [High] governanceReconfigure() triggers second epoch with zeroed perfo |
| #473 | high | EXISTS | high | cannot_tell | ✅339 | [High] governanceReconfigure() bypasses _canTransition() epoch-interva |
| #494 | high | EXISTS | high | cannot_tell | ✅494 | [High] JWKManager._regeneratePatchedJWKs() O(n²) storage complexity p |
| #532 | high | EXISTS | high | cannot_tell |  | [High] Malformed opaque BCS payload at epoch boundary halts off-chain  |
| #554 | high | EXISTS | high | cannot_tell | ✅554 | [High] Voting power is live-read, not snapshotted — mid-vote addStak |
| #555 | high | EXISTS | medium | cannot_tell |  | [High] Absolute minVotingThreshold can permanently deadlock governance |
| #290 | high | NOT_EXISTS | high | fixed |  | [High] TOCTOU in DKG target set — validator set recomputed after DKG |
| #298 | high | NOT_EXISTS | high | fixed |  | [High] GovernanceConfig insufficient validation allows permanent gover |
| #362 | high | NOT_EXISTS | high | fixed |  | [High] forceLeaveValidatorSet missing last-validator guard allows gove |
| #392 | high | NOT_EXISTS | high | fixed |  | [High] leaveValidatorSet last-validator guard uses array length instea |
| #404 | high | NOT_EXISTS | high | fixed |  | [High] No upper bound on renewLockUntil() allows staker to set lockedU |
| #410 | high | NOT_EXISTS | high | fixed |  | [High] Zero-duration expiration default enables same-transaction fee r |
| #414 | high | NOT_EXISTS | high | fixed |  | [High] Unbounded oracle nonce gaps permanently silence GBridgeReceiver |
| #431 | high | NOT_EXISTS | high | fixed |  | [High] GovernanceConfig._validateConfig missing lower bounds — minVo |
| #432 | high | NOT_EXISTS | high | fixed |  | [High] votingDurationMicros has no upper bound — setting it near typ |
| #435 | high | NOT_EXISTS | high | fixed |  | [High] autoEvictThreshold has no upper-bound validation — governance |
| #485 | high | NOT_EXISTS | high | fixed |  | [High] autoEvictThreshold has no upper bound — governance can mass-e |
| #491 | high | NOT_EXISTS | high | fp |  | [High] Partial initialization deadlock — Genesis._isInitialized set  |
| #507 | high | NOT_EXISTS | high | fp |  | [High] GOVERNANCE RemoveAll patch permanently disables all JWK-based k |
| #527 | high | NOT_EXISTS | high | fixed |  | [High] Unbounded autoEvictThreshold allows mass eviction of active val |
| #542 | high | NOT_EXISTS | high | fixed |  | [High] Stale pendingFeeRecipient applied when a deactivated validator  |
| #561 | high | NOT_EXISTS | high | fixed |  | [High] Genesis hard-coded 1798761600 lockup anchor becomes a time-bomb |
| #575 | high | NOT_EXISTS | high | fixed |  | [High] Governance-settable lockupDurationMicros lacks upper bound —  |
| #297 | high | PARTIAL | high | fixed |  | [High] execute() bypasses resolve() atomicity guard — flash loan pro |
| #421 | high | PARTIAL | high | cannot_tell |  | [High] removeExecutor() has no minimum-count guard — executor set ca |
| #503 | high | PARTIAL | high | cannot_tell |  | [High] EpochConfig.setForNextEpoch() missing lower and upper bounds � |
| #396 | low | NOT_EXISTS | high | fixed |  | [Low] O(n²) gas complexity in eviction and epoch processing may cause |
| #401 | low | NOT_EXISTS | high | fixed |  | [Low] StakingConfig setters missing _requireInitialized() guard presen |
| #560 | medium | EXISTS | high | cannot_tell |  | [Medium] Genesis ValidatorManagement.initialize skips IStaking.isPool  |
| #562 | medium | EXISTS | high | cannot_tell |  | [Medium] Reconfiguration.initialize records lastReconfigurationTime=0  |
| #563 | medium | EXISTS | high | cannot_tell |  | [Medium] NativeOracle and JWKManager accept state-mutating calls while |
| #569 | medium | EXISTS | high | cannot_tell |  | [Medium] OracleRequestQueue address reserved in SystemAddresses but ab |
| #579 | medium | EXISTS | medium | cannot_tell | ✅494 | [Medium] Unbounded setPatches + O(I²+P·I) regeneration per rotation  |
| #580 | medium | EXISTS | high | cannot_tell |  | [Medium] Consensus pubkey squatting — PoP is not bound to operator/s |
| #275 | medium | NOT_EXISTS | high | fixed |  | [Medium] No reentrancy guard on _withdrawAvailable ETH transfer — cr |
| #394 | medium | NOT_EXISTS | high | fixed |  | [Medium] Performance array length mismatch silently skips eviction for |
| #395 | medium | NOT_EXISTS | high | fp |  | [Medium] PRECISION_FACTOR is a no-op — voting power limit has no sub |
| #398 | medium | NOT_EXISTS | high | fixed |  | [Medium] StakingConfig immediate setters bypass epoch boundary — mid |
| #558 | medium | NOT_EXISTS | high | fixed |  | [Medium] renewLockUntil has no upper cap — staker can push lockedUnt |
| #565 | medium | NOT_EXISTS | high | fixed |  | [Medium] StakingConfig GOVERNANCE setters lack _requireInitialized, di |
| #566 | medium | NOT_EXISTS | high | fixed |  | [Medium] setTaskType without setExpiration enables immediate-refund Do |
| #568 | medium | NOT_EXISTS | high | fixed |  | [Medium] Governance.nextProposalId default initializer  skipped in BSC |
| #570 | medium | NOT_EXISTS | high | fixed |  | [Medium] execute() bypasses resolve() via expired-unresolved SUCCEEDED |
| #573 | medium | NOT_EXISTS | high | fp |  | [Medium] requiredProposerStake is a one-shot creation check — propos |
| #576 | medium | NOT_EXISTS | high | fixed |  | [Medium] StakingConfig setters take effect immediately with no pending |
| #578 | medium | NOT_EXISTS | high | fixed |  | [Medium] Governance-settable unbondingDelayMicros lacks upper bound � |
| #572 | medium | PARTIAL | high | fixed |  | [Medium] Voter rotation via StakePool.setVoter during active proposal  |
| #574 | medium | PARTIAL | medium | cannot_tell |  | [Medium] No grace period for newly-activated validators — first-epoc |
| #577 | medium | PARTIAL | high | cannot_tell |  | [Medium] Governance-settable minimumStake lacks upper bound — value  |
