---
title: Polymarket Settlement Resolver Specification
status: production candidate
---

# Polymarket Settlement Resolver

This specification defines the contract boundary for mirroring one finalized
Polygon Conditional Tokens Framework (CTF) condition into Gravity. Validators
independently scan Polygon, agree on canonical event bytes through JWK consensus,
and deliver one terminal settlement through `NativeOracle`.

Polygon RPC access, finalized-block selection, event ordering, and cursor
persistence belong to the `gravity-reth` provider. The resolver performs no RPC
requests and does not independently prove Polygon finality.

## Source And Mirror Identity

Polymarket settlements use source type `6`. Governance registers one immutable
mirror identity:

```text
(mirrorId, polygonChainId=137, ctf, conditionId, outcomeSlotCount)
```

`mirrorId` is the NativeOracle `sourceId` and must fit the `uint64` identity used
by relayer task URIs. Every accepted payload must match all registered fields.
The resolver also recomputes the CTF condition identity:

```solidity
conditionId = keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
```

This binds event provenance to the reviewed condition rather than trusting
independent metadata fields.

## Canonical Payload ABI

```solidity
struct PolymarketSettlementPayload {
    uint256 mirrorId;
    uint256 polygonChainId;
    address ctf;
    address oracle;
    bytes32 conditionId;
    bytes32 questionId;
    uint256 outcomeSlotCount;
    uint256[] payoutNumerators;
    bytes32 txHash;
    uint256 logIndex;
    uint8 settlementKind;
}
```

`settlementKind=1` identifies a CTF `ConditionResolution` event. The canonical
resolver payload is exactly `abi.encode(PolymarketSettlementPayload)`. Its byte
length must match the registered outcome count, and decode/re-encode hashes must
match. Trailing bytes, alternate dynamic offsets, malformed narrow values, and
other non-canonical encodings are rejected.

## Terminal Classification

The payout vector must contain exactly `outcomeSlotCount` elements and at least
one positive value:

- exactly one positive slot becomes `ResolvedWinner` with that `winningSlot`
- multiple positive slots become `ResolvedVoidable`
- an all-zero or malformed vector reverts delivery and creates no terminal state

`ResolvedVoidable` is a source-derived terminal result, not a Gravity timeout.
There is no local settlement deadline. A canonical Polygon resolution remains
valid regardless of how much Gravity wall-clock time has elapsed.

## Atomic Delivery

`NativeOracle` invokes the resolver atomically. Invalid identity, malformed ABI,
insufficient callback gas, or a duplicate terminal settlement reverts the whole
delivery. Source nonce and source position therefore do not advance, and the
same delivery remains retryable.

New NativeOracle deliveries do not retain raw payload history. Consequently the
resolver has no replay API or pending-raw-record state. Its observable states are
only `None`, `ResolvedWinner`, and `ResolvedVoidable`.

## Storage And Provenance

Each mirror stores at most one fixed-size terminal settlement, including the
classification, winning slot, delivery nonce, Gravity observation timestamp,
Polygon oracle and question ID, transaction hash, and log index. Registered
chain, CTF, condition, and outcome count remain in the immutable mirror
configuration. The full payout vector is emitted with the resolution event but
is not duplicated in permanent contract storage.

`recordedAt` is audit metadata only. It must never invalidate or change a
canonical Polygon terminal result. The finalized Polygon block is the
NativeOracle source position and is available through `getSourceProgress(6,
mirrorId)`.

The resolver supports up to 32 outcomes within the standard 500,000 callback
gas limit. Callback cost remains bounded because outcome values are classified
in memory and are not copied into a dynamic storage array.

## Focused Tests

```bash
forge test --match-path 'test/unit/oracle/PolymarketSettlementResolver.t.sol'
```

The suite covers governance registration, relayer identity width, caller and
source authorization, canonical ABI enforcement, every registered identity
field, derived CTF condition identity, payout classification, independent
mirrors, provenance, duplicate settlement rejection, callback gas failure, and
atomic source-progress rollback.
