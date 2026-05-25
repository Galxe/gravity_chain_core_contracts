# Gravity Chain Event Monitoring Architecture

## Goals

The monitoring system should let Gravity chain operators detect and respond to:

- Consensus liveness issues before users notice chain degradation.
- Validator-set or voting-power changes that threaten safety.
- Governance actions that alter protocol behavior.
- Bridge and oracle failures, especially cross-chain lock/mint mismatches.
- Large native, ERC20, staking, and bridge value movement.
- Rare emergency paths, such as DKG session clearing or bridge emergency withdrawal.

This document proposes a practical architecture for event monitoring, alerting, and operational analytics.

## Recommended High-Level Design

Use two complementary systems:

1. `P0 Watchtower`: a small, independent, reorg-aware monitoring service that reads chain data directly and emits alerts quickly.
2. `Analytics Indexer`: a richer event indexer for historical queries, dashboards, investigations, and product-facing observability.

The Watchtower should be boring, deterministic, and easy to replay. The analytics indexer can be more flexible and query-oriented.

```
Gravity RPC / Archive RPC / External Chain RPC
        |
        v
  P0 Watchtower  -----> Prometheus metrics -----> Alertmanager -----> Pager / Slack
        |
        +-----------> PostgreSQL or ClickHouse raw event store
        |
        +-----------> Rule engine and cross-chain correlator

Analytics Indexer
        |
        +-----------> PostgreSQL / GraphQL / dashboards
        |
        +-----------> ad hoc investigations and reporting
```

## P0 Watchtower

### Responsibilities

- Subscribe to or poll new blocks.
- Pull logs for selected contract addresses and event topics.
- Pull transactions, receipts, and traces when needed for native value transfers.
- Decode governance calldata and bridge payloads.
- Maintain a checkpoint with block number, block hash, and finalized status.
- Handle short reorgs by rolling back derived state.
- Emit metrics and alerts with deterministic labels.
- Store raw logs and decoded events for incident review.

### Inputs

- Gravity JSON-RPC endpoint.
- Gravity archive RPC endpoint if historical backfill or traces are needed.
- Ethereum or source-chain RPC endpoints for `GravityPortal` and `GBridgeSender`.
- ABI files generated from this repository.
- System contract addresses from `src/foundation/SystemAddresses.sol`.
- External deployment addresses for Ethereum-side bridge contracts.
- Release manifests for expected governance proposals and config hashes.

### Why Keep It Separate From a General Indexer

The P0 Watchtower should not depend on a complex GraphQL layer, hosted indexing service, or product indexer backlog. It should be able to answer only the questions required for paging:

- Did blocks stop?
- Did an epoch transition get stuck?
- Did DKG get stuck or cleared?
- Did voting power drop?
- Did governance execute a dangerous call?
- Did bridge minting fail or mismatch?
- Did a large transfer happen?

## Analytics Indexer Options

Several indexer families are viable:

- Envio HyperIndex: good for event-driven EVM indexing, generated handlers, GraphQL APIs, multichain views, and local or hosted deployment.
- SQD/Subsquid: good when you want explicit control over logs, transactions, traces, state diffs, and high-throughput batch processing.
- The Graph / graph-node: mature GraphQL indexing stack backed by PostgreSQL, especially useful if the data model is subgraph-friendly.
- Custom indexer: best when Gravity-specific block prologue data, cross-chain finality, or client-integrated metrics require special handling.

For chain-operator monitoring, the recommended split is:

- Use Watchtower for paging and security-critical checks.
- Use Envio, SQD, The Graph, or a custom ETL for dashboards and historical analytics.

## Data Model

A minimal storage model should include:

### `raw_blocks`

- `chain_id`
- `block_number`
- `block_hash`
- `parent_hash`
- `timestamp`
- `finality_status`
- `ingested_at`

### `raw_logs`

- `chain_id`
- `block_number`
- `block_hash`
- `tx_hash`
- `log_index`
- `address`
- `topic0`
- `topics`
- `data`
- `removed`

### `decoded_events`

- `chain_id`
- `block_number`
- `tx_hash`
- `log_index`
- `contract_name`
- `event_name`
- `event_args_json`
- `severity_hint`

### `validator_epoch_snapshots`

- `epoch`
- `active_validator_count`
- `total_voting_power`
- `validator_set_hash`
- `validator_set_json`
- `transition_time`

### `bridge_messages`

- `source_chain_id`
- `source_block_number`
- `source_tx_hash`
- `portal_nonce`
- `sender`
- `recipient`
- `amount`
- `message_payload_hash`
- `gravity_oracle_nonce`
- `mint_tx_hash`
- `mint_status`
- `matched_at`

### `governance_actions`

- `proposal_id`
- `execution_hash`
- `proposer`
- `state`
- `targets_json`
- `selectors_json`
- `decoded_calls_json`
- `risk_class`
- `manifest_match`

### `alert_state`

- `alert_key`
- `first_seen_at`
- `last_seen_at`
- `status`
- `dedupe_hash`
- `severity`
- `labels_json`

## Rule Types

### Event Rules

Trigger when a specific event appears.

Examples:

- Any `DKGSessionCleared` is P0.
- Any `EmergencyWithdrawRequested` or `EmergencyWithdraw` is P0.
- Any `ExecutorAdded` is P0.
- Any `PermissionlessJoinEnabledUpdated(true)` is P0 if the chain is expected to remain permissioned.

### Sequence and SLA Rules

Trigger when event A is not followed by event B in time.

Examples:

- `EpochTransitionStarted` must be followed by `EpochTransitioned` within the DKG SLA.
- `DKGStartEvent` must be followed by `DKGCompleted` within the DKG SLA.
- `TokensLocked` must be followed by `NativeMinted` after source-chain finality plus oracle SLA.
- `RequestSubmitted` must be followed by `RequestFulfilled` before `expiresAt`, unless refunded.

### State-Diff Rules

Trigger based on derived state across events and RPC reads.

Examples:

- Active validator count drops below policy.
- Total voting power drops by more than N percent at epoch boundary.
- Validator effective stake approaches `minimumBond`.
- Portal or bridge sender owner changes to an unrecognized address.

### Rate and Anomaly Rules

Trigger based on rolling windows.

Examples:

- NIL block ratio exceeds threshold.
- `CallbackFailed` rate exceeds threshold.
- `RequestRefunded` rate exceeds threshold.
- Pool creation spikes.
- Large transfer volume exceeds baseline.

### Manifest Rules

Trigger when an event is expected but the payload does not match an approved manifest.

Examples:

- `ConsensusConfigUpdated(configHash)` not present in release manifest.
- `ExecutionConfigUpdated(configHash)` not present in release manifest.
- `ProposalExecuted` calldata does not match the expected proposal artifact.
- `VersionUpdated` increments to an unapproved version.

## Large Transfer Monitoring

Large transfer monitoring needs more than contract event indexing.

### Native G

Monitor native token movement from:

- Transaction `value`.
- Internal traces if supported by the client.
- Balance deltas for critical system addresses.
- Stake-related events: `StakeAdded`, `Unstaked`, `WithdrawalClaimed`, `RewardsWithdrawn`.
- Bridge mint events: `NativeMinted`.

### ERC20

Monitor:

- Standard `Transfer(address,address,uint256)` logs.
- Token-specific mint and burn events where applicable.
- Bridge-side ERC20 movement in `GBridgeSender`.
- `ERC20Recovered` on portal and bridge contracts.

### Staking and Bridge Value

Monitor:

- Large `StakeAdded`.
- Large `Unstaked`.
- Large `WithdrawalClaimed`.
- Large `RewardsWithdrawn`.
- Large `TokensLocked`.
- Large `NativeMinted`.
- Any bridge emergency withdrawal.

### Threshold Strategy

Use multiple thresholds:

- Absolute amount.
- Percentage of total supply.
- Percentage of total voting power.
- Percentage of a pool's active stake.
- Deviation from the address or pool's historical baseline.
- Special thresholds for known treasury, validator, bridge, and governance addresses.

## Governance Monitoring

Governance monitoring should decode both proposals and executions.

### On `ProposalCreated`

- Compute and store `executionHash`.
- If `targets` and `datas` are available from the transaction input, decode them immediately.
- Classify the proposal:
  - `validator_policy`
  - `staking_policy`
  - `governance_policy`
  - `consensus_config`
  - `execution_config`
  - `version_upgrade`
  - `oracle_config`
  - `bridge_admin`
  - `executor_admin`
  - `unknown`
- Compare against an expected proposal manifest if one exists.

### On `ProposalExecuted`

- Decode every target and selector.
- Verify the target list and calldata match the proposal hash and approved manifest.
- Page on unknown targets, unknown selectors, or high-risk targets.
- Store a human-readable execution summary.

### High-Risk Targets

Treat calls to these areas as high risk:

- `Governance` executor management.
- `ValidatorConfig`, especially `allowValidatorSetChange`, `minimumBond`, `maximumBond`, auto-eviction, and max validator set size.
- `EpochConfig`.
- `VersionConfig`.
- `ConsensusConfig`.
- `ExecutionConfig`.
- `RandomnessConfig`.
- `NativeOracle` callback routing.
- `OracleTaskConfig` and `OnDemandOracleTaskConfig`.
- Ethereum-side bridge owner/admin functions.

## Bridge Correlation

The bridge path should be monitored as a lifecycle:

1. Source-chain `TokensLocked`.
2. Source-chain `MessageSent`.
3. Gravity `NativeOracle.DataRecorded`.
4. Gravity callback success or failure.
5. Gravity `NativeMinted`.

The correlator should use:

- Portal nonce.
- Source chain ID.
- Source block number.
- Source transaction hash.
- Encoded payload hash.
- Decoded amount and recipient.
- NativeOracle `(sourceType, sourceId, nonce)`.
- Mint event nonce.

Alert on:

- Lock without mint.
- Mint without lock.
- Amount mismatch.
- Recipient mismatch.
- Source sender mismatch.
- Source chain mismatch.
- Callback failure.
- Emergency withdrawal request or execution.
- Portal or bridge pause.
- Portal or bridge ownership change.

## Oracle Monitoring

Oracle monitoring should distinguish between source liveness, callback liveness, and task configuration.

### Source Liveness

- Track latest nonce per `(sourceType, sourceId)`.
- Track time since last `DataRecorded`.
- Track payload sizes.
- Track expected source block lag for blockchain sources.

### Callback Liveness

- Track `CallbackSuccess`, `CallbackFailed`, and `CallbackSkipped`.
- Page on repeated failures for bridge callbacks.
- Treat `StorageSkipped` as expected only for callbacks that own their storage, such as JWK handling.

### Task Configuration

- Alert on task additions, removals, and changes.
- Decode task config where possible.
- Compare task config against a signed task manifest.

## Consensus and Epoch Monitoring

The most important chain-health alerts should be independent of the EVM event indexer where possible. The consensus/client process should also export native metrics.

Recommended metrics:

- `gravity_block_height`
- `gravity_block_time_seconds`
- `gravity_nil_block_total`
- `gravity_current_epoch`
- `gravity_epoch_transition_in_progress`
- `gravity_epoch_transition_seconds`
- `gravity_dkg_in_progress`
- `gravity_dkg_duration_seconds`
- `gravity_active_validator_count`
- `gravity_total_voting_power`
- `gravity_validator_failed_proposals_total`
- `gravity_validator_successful_proposals_total`

Event-derived metrics should be used as a cross-check against client metrics.

## Reorg and Finality Handling

The monitoring stack should use two levels of confidence:

- `hot`: recent blocks that can be reorged.
- `finalized`: blocks past the configured finality confirmation depth.

Rules should choose the right level:

- P0 liveness alerts can use hot data.
- Bridge mint/lock accounting should wait for source-chain finality before declaring final mismatch.
- Governance execution and config updates should alert immediately, then reconcile after finality.
- Storage should keep block hash and parent hash for rollback.

When a reorg happens:

- Mark affected raw logs as removed or rollback derived rows.
- Re-run rule evaluation for replaced blocks.
- Deduplicate alerts by stable alert key, not by transaction hash alone.

## Prometheus and Alertmanager

Expose Watchtower metrics to Prometheus and route alerts through Alertmanager.

Recommended labels:

- `chain`
- `environment`
- `severity`
- `component`
- `contract`
- `event`
- `validator`
- `source_chain`
- `source_type`
- `source_id`

Recommended alert routing:

- P0: pager plus incident channel.
- P1: Slack channel plus optional pager if repeated.
- P2: dashboard and daily report.

Recommended HA setup:

- Run at least two Watchtower instances against independent RPC paths.
- Run Alertmanager in HA mode.
- Configure Prometheus to send alerts to all Alertmanager instances.
- Alert on Watchtower ingestion lag and RPC disagreement.

## Deployment Topology

### Minimal Production Setup

- Two Watchtower instances.
- One PostgreSQL instance with backups.
- Prometheus.
- Two or three Alertmanager instances.
- Grafana dashboard.
- Optional analytics indexer.

### Stronger Production Setup

- Three Watchtower instances across separate hosts.
- Independent RPC providers plus self-hosted node.
- PostgreSQL primary plus replica, or ClickHouse for high-volume event analytics.
- Dedicated queue for decoded event processing.
- Separate analytics indexer for dashboards.
- Signed release manifests for governance/config verification.

## Implementation Phases

### Phase 1: P0 Watchtower

- Decode core consensus, epoch, DKG, governance, validator, oracle, and bridge events.
- Implement liveness checks.
- Implement DKG and epoch SLA checks.
- Implement bridge lock/mint correlation.
- Implement large staking and bridge value alerts.
- Export Prometheus metrics.

### Phase 2: Governance and Config Intelligence

- Decode proposal calldata.
- Build risk classifier for governance targets.
- Add release manifest matching.
- Add config diffing for all runtime config contracts.
- Add ownership and pause monitoring for inherited OpenZeppelin events.

### Phase 3: Analytics Indexer

- Backfill all historical events.
- Build dashboards for validator performance, governance activity, oracle health, and bridge volume.
- Add long-window anomaly detection.
- Add operational reports per epoch.

### Phase 4: Client-Integrated Metrics

- Export native consensus/client metrics.
- Cross-check client state against contract events.
- Add RPC disagreement checks between independent nodes.

## Recommended Dashboards

- Chain liveness: block height, block interval, NIL block ratio, timestamp drift.
- Epoch health: current epoch, transition duration, DKG duration, validator-set changes.
- Validator health: proposal success rate, evictions, voting power, join/leave queue.
- Governance: active proposals, vote concentration, pending config changes, executed proposals.
- Staking flows: stake additions, unstakes, withdrawals, role changes.
- Oracle health: records per source, callback success/failure, request fulfillment and refund rate.
- Bridge health: source locks, portal messages, oracle records, native mints, unmatched messages, emergency actions.
- Large transfers: native value, ERC20 value, bridge and staking value.

## Operational Runbooks

Create runbooks for at least:

- Blocks stopped.
- NIL block storm.
- Epoch transition stuck.
- DKG stuck or cleared.
- Validator voting power drop.
- Validator auto-eviction.
- Governance high-risk proposal created.
- Governance proposal executed.
- Bridge lock without mint.
- Bridge mint without lock.
- NativeOracle callback failure.
- Emergency bridge withdrawal requested.
- Large unstake or withdrawal.

Each runbook should include:

- Alert meaning.
- Immediate checks.
- Safe remediation steps.
- Escalation owner.
- Links to dashboards and queries.
- Expected resolution signal.

## Contract Observability Improvements

To make monitoring simpler and less stateful, consider these contract changes:

- Emit `PerformanceReset` in `ValidatorPerformanceTracker.onNewEpoch()`.
- Remove or implement `ComponentUpdateFailed`.
- Add full parameter or config-hash events for `ValidatorConfig`, `StakingConfig`, and `GovernanceConfig`.
- Add source context to `NativeMinted`.
- Emit an explicit `ConsensusKeyApplied` event at epoch boundary.
- Consider emitting a structured `ProposalCallDecoded`-style event only if calldata decoding is standardized; otherwise keep decoding off-chain.
