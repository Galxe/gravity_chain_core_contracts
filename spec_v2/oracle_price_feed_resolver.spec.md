---
title: Price Feed Resolver Specification
status: production candidate
---

# Price Feed Resolver

This specification defines the contract boundary for Gravity's deterministic
price feed. Validators observe the same finalized upstream round, reach
consensus on its canonical payload, and `PriceFeedResolver` stores the latest
accepted value for on-chain consumers.

The first provider implementation uses a closed Binance USD-M index-price kline.
Provider fetching and response validation live in `gravity-reth`; this contract
does not perform HTTP requests or aggregate validator observations.

## Source Identity

Price feeds use source type `3`. Each configured instrument has a stable
`sourceId`, and that value must equal the packed `feedId`. NativeOracle tracks
delivery progress independently for every `(sourceType, sourceId)` pair.

`OracleTaskConfig` permanently binds each price-feed `sourceId` to the hash of
its first task config. Re-submitting identical bytes is allowed, but changing
or reordering any config bytes requires a new feed ID, including after task
removal. This deliberately fail-closed rule prevents a historical feed from
being silently rebound to another instrument. Other source types remain
reconfigurable.

## Packed V1 Payload

The callback body is exactly one big-endian 32-byte word:

```text
bits 255..248 : version       uint8   (must be 1)
bits 247..184 : feedId        uint64
bits 183..152 : roundId       uint32
bits 151..104 : resolvedAtMs  uint48
bits 103..8   : price         uint96  (fixed 8 decimals)
bits 7..0     : flags         uint8   (must be 0)
```

For the Binance index-kline provider:

- `roundId = bucketStartMs / intervalMs`
- `resolvedAtMs = bucketEndMs`
- `price` is the positive decimal `close` field scaled to 8 decimals
- the NativeOracle delivery nonce is independent from `roundId` and remains
  sequential for the feed

The inner callback body is 32 bytes. The unchanged relayer uses Alloy's
canonical dynamic-tuple encoding for `(deliveryNonce, sourcePosition,
callbackBody)`, including its leading tuple offset. The complete wrapper is 192
bytes for a 32-byte callback body. Provider-specific URI parsing, decimal
truncation, and exact closed-bucket checks are specified with the reth provider.

## Contract Validation

The resolver accepts a payload only when:

- the caller is the NativeOracle system contract
- `sourceType == 3`
- payload length is exactly 32 bytes
- `version == 1` and `flags == 0`
- `sourceId` fits `uint64` and equals `feedId`
- `roundId` is nonzero and greater than the latest accepted round
- `resolvedAtMs` is nonzero and greater than the latest accepted timestamp
- price is positive

Legacy 160-byte callback bodies, trailing bytes, unknown versions, and nonzero
flags are rejected. Any callback failure reverts the entire NativeOracle
delivery, so source progress does not advance and the same delivery nonce
remains retryable.

## Storage And History

`latestPrice(feedId)` exposes one single-slot record per feed:

```solidity
struct PriceRound {
    uint32 roundId;
    uint48 resolvedAtMs;
    uint96 price;
}
```

`roundId != 0` indicates existence and `PRICE_DECIMALS` is the constant `8`.
A successful new round overwrites the preceding record. The resolver does not
retain raw payloads or historical round mappings; historical values remain
available from `PriceResolved` logs and the authoritative upstream source.

NativeOracle never retains new raw `DataRecord` payloads; the callback return
value is a deprecated compatibility field and does not control storage. This
keeps chain-state growth bounded while preserving the latest query-ready price
and source progress.

## Aggregation Boundary

Validator observations are reduced by JWK consensus before contract execution.
The payload therefore contains one consensus-approved price, not an array of
provider observations. Weighted mean, weighted median, source thresholds, and
multi-provider normalization are outside this ABI and require a separately
versioned source type and payload if introduced later.

## Focused Tests

```bash
forge test --match-path 'test/unit/oracle/PriceFeedResolver.t.sol'
```

The suite covers the cross-language golden vector, exact payload length,
version and flags, maximum field widths, one-slot storage, source identity,
caller authorization, round and timestamp replay protection, zero price,
legacy payload rejection, callback gas failure, and atomic retry behavior.
