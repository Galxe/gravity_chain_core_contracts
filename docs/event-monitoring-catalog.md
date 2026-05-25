# Gravity Chain Event Monitoring Catalog

## Purpose

This document catalogs the Solidity events in `src/` that are worth monitoring from the perspective of a chain operator and protocol maintainer. It focuses on events that indicate:

- Large value movement.
- Consensus, epoch, validator-set, or DKG liveness issues.
- Governance or configuration changes.
- Oracle and bridge failures.
- Logic paths that should be rare or emergency-only.

Severity labels are intentionally operational:

- `P0`: wake someone up immediately.
- `P1`: alert during business hours or page if repeated.
- `P2`: trend, dashboard, or investigate during routine operations.

## Global Monitoring Notes

- Do not rely only on Solidity events for large transfers. Native G transfers are ordinary EVM transactions or traces and do not necessarily emit contract events. ERC20 transfers should be monitored through standard `Transfer(address,address,uint256)` logs.
- Inherited OpenZeppelin events should also be monitored even if they are not declared in this repository. This includes `OwnershipTransferStarted`, `OwnershipTransferred`, `Paused`, and `Unpaused` for contracts that inherit `Ownable2Step` or `Pausable`.
- Two declared events are currently not emitted anywhere in `src/`:
  - `PerformanceReset` in `src/blocker/IValidatorPerformanceTracker.sol`.
  - `ComponentUpdateFailed` in `src/blocker/Blocker.sol`.
  They should not be treated as usable monitoring signals unless the implementation is updated to emit them.

## Consensus, Block, Epoch, and DKG

| Event | Contract | Severity | Monitor For |
| --- | --- | --- | --- |
| `BlockStarted(uint256 blockHeight, uint64 epoch, address proposer, uint64 timestampMicros)` | `Blocker` | P0/P1 | Missing blocks, repeated NIL proposers, epoch mismatch, timestamp lag. |
| `GlobalTimeUpdated(address proposer, uint64 oldTimestamp, uint64 newTimestamp)` | `Timestamp` | P0/P1 | Timestamp not advancing, excessive jumps, drift against wall clock. |
| `PerformanceUpdated(uint64 proposerIndex, uint256 failedCount, bool skippedProposer, uint256 skippedFailedCount)` | `ValidatorPerformanceTracker` | P1 | `skippedProposer == true`, `skippedFailedCount > 0`, high failed proposal rate. |
| `EpochTransitionStarted(uint64 epoch)` | `Reconfiguration` | P0 | Transition starts but does not complete within the expected DKG SLA. |
| `EpochTransitioned(uint64 newEpoch, uint64 transitionTime)` | `Reconfiguration` | P0/P1 | Epoch delay, skipped expected transition, unexpected rapid transitions. |
| `NewEpochEvent(uint64 newEpoch, ValidatorConsensusInfo[] validatorSet, uint256 totalVotingPower, uint64 transitionTime)` | `Reconfiguration` | P0 | Validator count drop, total voting power drop, unexpected validator-set changes. |
| `DKGStartEvent(uint64 dealerEpoch, uint64 startTimeUs, DKGSessionMetadata metadata)` | `DKG` | P0 | DKG start without timely completion, dealer/target set mismatch. |
| `DKGCompleted(uint64 dealerEpoch, bytes32 transcriptHash)` | `DKG` | P0/P1 | Completion latency, transcript hash not matching expected off-chain record. |
| `DKGSessionCleared(uint64 dealerEpoch)` | `DKG` | P0 | Incomplete DKG was cleared. This should be rare and requires investigation. |
| `EpochProcessed(uint64 epoch, uint256 activeCount, uint256 totalVotingPower)` | `ValidatorManagement` | P0/P1 | Active validator count or voting power below minimum policy. |
| `PerformanceLengthMismatch(uint256 activeCount, uint256 perfCount)` | `ValidatorManagement` | P0 | Internal invariant mismatch between active validators and performance data. |

### Derived Alerts

- `NoBlocks`: no `BlockStarted` for more than the expected block interval plus tolerance.
- `NilBlockStorm`: `BlockStarted.proposer == SYSTEM_CALLER` ratio exceeds a configured threshold over a rolling window.
- `TimeDrift`: `GlobalTimeUpdated.newTimestamp` differs from wall clock by more than the configured drift budget.
- `EpochStuck`: `EpochTransitionStarted` observed but no matching `EpochTransitioned` or `NewEpochEvent`.
- `DKGStuck`: `DKGStartEvent` observed but no matching `DKGCompleted`.
- `UnexpectedDKGClear`: any `DKGSessionCleared`.
- `VotingPowerDrop`: `NewEpochEvent.totalVotingPower` or `EpochProcessed.totalVotingPower` drops by more than a configured percentage.
- `ValidatorSetBelowFloor`: active validator count below the chain's operational minimum.

## Validator Lifecycle and Validator Safety

| Event | Contract | Severity | Monitor For |
| --- | --- | --- | --- |
| `ValidatorRegistered(address stakePool, string moniker)` | `ValidatorManagement` | P1/P2 | New validator registrations, spam, unrecognized monikers. |
| `ValidatorJoinRequested(address stakePool)` | `ValidatorManagement` | P1/P2 | Join queue growth, unexpected non-whitelisted joins. |
| `ValidatorActivated(address stakePool, uint64 validatorIndex, uint256 votingPower)` | `ValidatorManagement` | P1 | Activation of unknown validators, large voting power additions. |
| `ValidatorLeaveRequested(address stakePool)` | `ValidatorManagement` | P1 | Multiple validators leaving in one epoch, critical validators leaving. |
| `ValidatorForceLeaveRequested(address stakePool)` | `ValidatorManagement` | P0 | Governance forced a validator out. Emergency path. |
| `ValidatorDeactivated(address stakePool)` | `ValidatorManagement` | P0/P1 | Unexpected deactivation, validator count loss. |
| `ValidatorAutoEvicted(address stakePool, uint256 successfulProposals)` | `ValidatorManagement` | P0 | Performance eviction. May indicate validator outage or network issue. |
| `ValidatorUnderbondedEvicted(address stakePool, uint256 votingPower, uint256 minimumBond)` | `ValidatorManagement` | P0 | Validator fell below minimum bond. |
| `ValidatorRevertedInactive(address stakePool)` | `ValidatorManagement` | P1 | Pending validator failed activation requirements. |
| `ConsensusKeyRotated(address stakePool, bytes newPubkey)` | `ValidatorManagement` | P0/P1 | Consensus key changes, especially for active validators. |
| `FeeRecipientUpdated(address stakePool, address newRecipient)` | `ValidatorManagement` | P1 | Pending fee-recipient change. |
| `FeeRecipientApplied(address stakePool, address oldRecipient, address newRecipient)` | `ValidatorManagement` | P1 | Fee-recipient change took effect at epoch boundary. |
| `ValidatorPoolAllowed(address stakePool, bool allowed)` | `ValidatorManagement` | P0/P1 | Whitelist changes. P0 when removing active validators or adding unknown pools. |
| `PermissionlessJoinEnabledUpdated(bool enabled)` | `ValidatorManagement` | P0 | Validator admission policy changed. |
| `ValidatorManagementInitialized(uint256 validatorCount, uint256 totalVotingPower)` | `ValidatorManagement` | P2 | Genesis or hardfork initialization audit trail. |

### Derived Alerts

- `ValidatorChurnHigh`: more than N join, leave, activation, or deactivation events in one epoch.
- `CriticalValidatorChangedKey`: active validator rotates consensus key outside an expected maintenance window.
- `WhaleValidatorActivated`: newly activated validator voting power exceeds a configured percentage of total voting power.
- `PermissionlessJoinEnabled`: page if the chain is expected to be permissioned.
- `ValidatorWhitelistChanged`: alert when governance changes whitelist entries.

## Staking, Pool Roles, and Value Movement

| Event | Contract | Severity | Monitor For |
| --- | --- | --- | --- |
| `PoolCreated(address creator, address pool, address owner, address staker, uint256 poolIndex)` | `Staking` | P2 | Pool creation rate, suspicious owner/staker patterns. |
| `StakeAdded(address pool, uint256 amount)` | `StakePool` | P1/P2 | Large stake additions, stake concentration. |
| `Unstaked(address pool, uint256 amount, uint64 lockedUntil)` | `StakePool` | P0/P1 | Large unstake, active validator unstake, effective stake near minimum bond. |
| `WithdrawalClaimed(address pool, uint256 amount, address recipient)` | `StakePool` | P0/P1 | Large withdrawals, unexpected recipients. |
| `RewardsWithdrawn(address pool, uint256 amount, address recipient)` | `StakePool` | P1 | Large reward withdrawals or unexpected recipients. |
| `LockupRenewed(address pool, uint64 oldLockedUntil, uint64 newLockedUntil)` | `StakePool` | P2 | Lockup extension health and active validator auto-renewal. |
| `RoleChangeProposed(address pool, Role role, address newAddress, uint64 effectiveAt)` | `StakePool` | P0/P1 | Staker/operator/voter change proposals. |
| `RoleChangeCancelled(address pool, Role role)` | `StakePool` | P2 | Operational audit trail; alert if repeated. |
| `OperatorChanged(address pool, address oldOperator, address newOperator)` | `StakePool` | P0/P1 | Active validator operator changed. |
| `VoterChanged(address pool, address oldVoter, address newVoter)` | `StakePool` | P1 | Governance voting authority changed. |
| `StakerChanged(address pool, address oldStaker, address newStaker)` | `StakePool` | P0/P1 | Fund manager changed. |
| `RoleChangeDelayUpdated(address pool, Role role, uint64 oldDelay, uint64 newDelay)` | `StakePool` | P1 | Timelock delay changed, especially shortened or changed on important pools. |

### Large-Value Thresholds

Use multiple thresholds rather than one global number:

- Absolute amount, for example `amount >= X G`.
- Share of total stake, for example `amount >= 1% of totalVotingPower`.
- Share of pool active stake, for example `amount >= 20% of pool.activeStake`.
- Validator safety threshold, for example post-unstake effective stake within 110% of `minimumBond`.
- Address baseline, for example value is above 5x the actor's 30-day median flow.

## Governance and Protocol Configuration

| Event | Contract | Severity | Monitor For |
| --- | --- | --- | --- |
| `ProposalCreated(uint64 proposalId, address proposer, address stakePool, bytes32 executionHash, string metadataUri)` | `Governance` | P0/P1 | Proposals touching system contracts, bridge, oracle, config, or validator management. |
| `VoteCast(uint64 proposalId, address voter, address stakePool, uint128 votingPower, bool support)` | `Governance` | P1/P2 | Whale voting, sudden quorum, vote concentration, last-minute vote swings. |
| `ProposalResolved(uint64 proposalId, ProposalState state)` | `Governance` | P1 | Passed proposals that require execution, failed critical proposals. |
| `ProposalExecuted(uint64 proposalId, address executor, address[] targets, bytes[] datas)` | `Governance` | P0 | Any execution. Decode and verify targets and calldata against approved intent. |
| `ExecutorAdded(address executor)` | `Governance` | P0 | New execution authority. |
| `ExecutorRemoved(address executor)` | `Governance` | P1 | Executor set changed; ensure enough executors remain. |
| `PendingValidatorConfigSet()` | `ValidatorConfig` | P0/P1 | Pending validator-policy changes. Read `getPendingConfig()` and diff. |
| `ValidatorConfigUpdated()` | `ValidatorConfig` | P0/P1 | Validator-policy changes applied at epoch boundary. |
| `PendingStakingConfigSet()` | `StakingConfig` | P1 | Pending staking economic changes. Read and diff pending config. |
| `StakingConfigUpdated()` | `StakingConfig` | P1 | Staking config applied. |
| `PendingGovernanceConfigSet()` | `GovernanceConfig` | P0/P1 | Pending governance parameter changes. |
| `GovernanceConfigUpdated()` | `GovernanceConfig` | P0/P1 | Governance config applied. |
| `PendingEpochIntervalSet(uint64 pendingInterval)` | `EpochConfig` | P0/P1 | Epoch duration change. Page if outside expected policy. |
| `EpochIntervalUpdated(uint64 oldValue, uint64 newValue)` | `EpochConfig` | P0/P1 | Epoch duration applied. |
| `PendingVersionSet(uint64 pendingVersion)` | `VersionConfig` | P0 | Protocol version upgrade scheduled. |
| `VersionUpdated(uint64 oldVersion, uint64 newVersion)` | `VersionConfig` | P0 | Protocol version upgrade applied. |
| `PendingConsensusConfigSet(bytes32 configHash)` | `ConsensusConfig` | P0 | Consensus config pending. Verify hash against release manifest. |
| `ConsensusConfigUpdated(bytes32 configHash)` | `ConsensusConfig` | P0 | Consensus config applied. |
| `PendingExecutionConfigSet(bytes32 configHash)` | `ExecutionConfig` | P0 | VM/execution config pending. Verify hash against release manifest. |
| `ExecutionConfigUpdated(bytes32 configHash)` | `ExecutionConfig` | P0 | VM/execution config applied. |
| `PendingRandomnessConfigSet(ConfigVariant variant)` | `RandomnessConfig` | P0/P1 | Randomness/DKG mode pending. |
| `RandomnessConfigUpdated(ConfigVariant oldVariant, ConfigVariant newVariant)` | `RandomnessConfig` | P0/P1 | DKG/randomness mode changed. |

### Governance Decoding Rules

For every `ProposalCreated` and `ProposalExecuted`:

- Decode each `target` and `data` selector.
- Classify whether it touches system addresses, bridge contracts, oracle callbacks, validator set, DKG/randomness, governance executors, or version/config contracts.
- Compare `executionHash` with an off-chain signed proposal manifest.
- Alert if a proposal target is unknown or the calldata cannot be decoded.
- Alert if execution happens without a previously observed successful proposal lifecycle.

## Oracle, JWK, and On-Demand Oracle

| Event | Contract | Severity | Monitor For |
| --- | --- | --- | --- |
| `DataRecorded(uint32 sourceType, uint256 sourceId, uint128 nonce, uint256 dataLength)` | `NativeOracle` | P1 | Oracle liveness, nonce gaps, abnormal payload size. |
| `DefaultCallbackSet(uint32 sourceType, address oldCallback, address newCallback)` | `NativeOracle` | P0/P1 | Callback routing changed. |
| `CallbackSet(uint32 sourceType, uint256 sourceId, address oldCallback, address newCallback)` | `NativeOracle` | P0/P1 | Specialized callback changed. |
| `CallbackSuccess(uint32 sourceType, uint256 sourceId, uint128 nonce, address callback)` | `NativeOracle` | P2 | Callback health ratio. |
| `CallbackFailed(uint32 sourceType, uint256 sourceId, uint128 nonce, address callback, bytes reason)` | `NativeOracle` | P0/P1 | Callback failed while oracle recording continued. |
| `CallbackSkipped(uint32 sourceType, uint256 sourceId, uint128 nonce, address callback)` | `NativeOracle` | P1 | Callback gas limit was zero. |
| `StorageSkipped(uint32 sourceType, uint256 sourceId, uint128 nonce, address callback)` | `NativeOracle` | P1/P2 | Expected for callback-owned storage such as JWK; suspicious elsewhere. |
| `TaskSet(uint32 sourceType, uint256 sourceId, bytes32 taskName, bytes config)` | `OracleTaskConfig` | P0/P1 | Continuous oracle task added or changed. |
| `TaskRemoved(uint32 sourceType, uint256 sourceId, bytes32 taskName)` | `OracleTaskConfig` | P0/P1 | Continuous oracle task removed. |
| `TaskTypeSet(uint32 sourceType, uint256 sourceId, bytes config)` | `OnDemandOracleTaskConfig` | P1 | On-demand task type added or changed. |
| `TaskTypeRemoved(uint32 sourceType, uint256 sourceId)` | `OnDemandOracleTaskConfig` | P1 | On-demand task type removed. |
| `RequestSubmitted(uint256 requestId, uint32 sourceType, uint256 sourceId, address requester, bytes requestData, uint256 fee, uint64 expiresAt)` | `OracleRequestQueue` | P2 | Request volume, spam, large request data. |
| `RequestFulfilled(uint256 requestId)` | `OracleRequestQueue` | P1/P2 | Fulfillment latency and success rate. |
| `RequestRefunded(uint256 requestId, address requester, uint256 amount)` | `OracleRequestQueue` | P1 | High refund rate means oracle service degradation. |
| `FeeUpdated(uint32 sourceType, uint256 oldFee, uint256 newFee)` | `OracleRequestQueue` | P1 | Fee changes for request types. |
| `ExpirationUpdated(uint32 sourceType, uint64 oldDuration, uint64 newDuration)` | `OracleRequestQueue` | P1 | Expiration policy changes. |
| `TreasuryUpdated(address oldTreasury, address newTreasury)` | `OracleRequestQueue` | P0/P1 | Treasury changed. |
| `ObservedJWKsUpdated(bytes issuer, uint64 version, uint256 jwkCount)` | `JWKManager` | P1 | Issuer keyset changes, stale versions, abnormal key count. |
| `PatchesUpdated(uint256 patchCount)` | `JWKManager` | P0/P1 | Governance override of observed JWKs. |
| `PatchedJWKsRegenerated(uint256 providerCount)` | `JWKManager` | P1/P2 | Provider count changes after patches. |

### Derived Alerts

- `OracleNonceGap`: latest nonce for a `(sourceType, sourceId)` does not advance sequentially.
- `CallbackFailureRateHigh`: repeated `CallbackFailed` for the same callback.
- `UnexpectedStorageSkipped`: `StorageSkipped` for callbacks that are expected to store payloads in `NativeOracle`.
- `OracleTaskChanged`: any task config change outside a governance release window.
- `OnDemandRefundRateHigh`: refund rate above target over a rolling window.
- `JWKProviderMissing`: provider count drops or an issuer disappears after patch regeneration.

## Bridge and Cross-Chain Flow

| Event | Contract | Severity | Monitor For |
| --- | --- | --- | --- |
| `MessageSent(uint128 nonce, uint256 block_number, bytes payload)` | `GravityPortal` | P0/P1 | Bridge message stream, nonce gaps, payload decode failures. |
| `FeeConfigUpdated(uint256 baseFee, uint256 feePerByte)` | `GravityPortal` | P1 | Portal fee changes, zero or excessive fee. |
| `FeeRecipientUpdated(address oldRecipient, address newRecipient)` | `GravityPortal` | P0/P1 | Portal fee recipient changed. |
| `FeesWithdrawn(address recipient, uint256 amount)` | `GravityPortal` | P1 | Large fee withdrawals, unexpected recipient. |
| `ERC20Recovered(address token, address recipient, uint256 amount)` | `GravityPortal` | P0/P1 | Asset recovery from portal. |
| `TokensLocked(address from, address recipient, uint256 amount, uint128 nonce)` | `GBridgeSender` | P0/P1 | Large bridge deposits, nonce correlation. |
| `EmergencyWithdrawRequested(address recipient, uint256 amount, uint256 executableAt)` | `GBridgeSender` | P0 | Emergency withdrawal timelock started. |
| `EmergencyWithdrawCancelled()` | `GBridgeSender` | P1 | Emergency withdrawal cancelled. |
| `EmergencyWithdraw(address recipient, uint256 amount)` | `GBridgeSender` | P0 | Timelocked withdrawal executed. |
| `ERC20Recovered(address token, address recipient, uint256 amount)` | `GBridgeSender` | P1 | Non-G token recovery from bridge sender. |
| `NativeMinted(address recipient, uint256 amount, uint128 nonce)` | `GBridgeReceiver` | P0/P1 | Mint on Gravity side. Must match source-chain lock event. |
| `Paused(address account)` | `GravityPortal`, `GBridgeSender` | P0 | Bridge deposit path paused. Inherited OpenZeppelin event. |
| `Unpaused(address account)` | `GravityPortal`, `GBridgeSender` | P1 | Bridge deposit path resumed. Inherited OpenZeppelin event. |
| `OwnershipTransferStarted(address previousOwner, address newOwner)` | `GravityPortal`, `GBridgeSender`, `Governance`, `StakePool` | P0/P1 | Ownership transfer proposed. Inherited OpenZeppelin event. |
| `OwnershipTransferred(address previousOwner, address newOwner)` | `GravityPortal`, `GBridgeSender`, `Governance`, `StakePool` | P0/P1 | Ownership transfer accepted. Inherited OpenZeppelin event. |

### Bridge Correlation Alerts

- `BridgeLockWithoutMint`: `TokensLocked` or `MessageSent` observed, but no corresponding `NativeMinted` after the expected finality plus oracle SLA.
- `BridgeMintWithoutLock`: `NativeMinted` observed without a matching source-chain lock/message.
- `BridgeAmountMismatch`: `NativeMinted.amount != TokensLocked.amount`.
- `BridgeNonceGap`: source `MessageSent.nonce` or receiver `NativeMinted.nonce` skips unexpectedly.
- `BridgeEmergencyWithdrawal`: any emergency withdrawal request or execution.
- `PortalCallbackFailure`: `NativeOracle.CallbackFailed` for the bridge receiver callback.

## Genesis and Initialization

| Event | Contract | Severity | Monitor For |
| --- | --- | --- | --- |
| `GenesisCompleted(uint256 validatorCount, uint64 timestamp)` | `Genesis` | P2 | Initialization audit trail. Any post-genesis occurrence is suspicious. |
| `ValidatorManagementInitialized(uint256 validatorCount, uint256 totalVotingPower)` | `ValidatorManagement` | P2 | Genesis validator set baseline. |
| Initial `*ConfigUpdated` events | Runtime config contracts | P2 | Genesis config baseline. |

## Recommended Event Gaps to Close

- Emit `PerformanceReset` in `ValidatorPerformanceTracker.onNewEpoch()` with the new epoch and validator count, or remove it from the interface.
- Either remove `ComponentUpdateFailed` or implement guarded component update calls in `Blocker` that emit it on non-fatal failures.
- Add richer config events for `ValidatorConfig`, `StakingConfig`, and `GovernanceConfig`. The current `Updated()` and `Pending*Set()` events do not carry enough data for stateless monitoring. Either emit full parameters or a config hash.
- Add `sourceId`, `oracleNonce`, and source sender context to `NativeMinted` to make bridge correlation easier without decoding the `NativeOracle` record.
- Consider emitting explicit applied consensus-key events at epoch boundary, not only the pending `ConsensusKeyRotated` event.
