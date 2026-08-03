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
`sourceId`, and that value must equal `PricePayload.feedId`. NativeOracle tracks
delivery progress independently for every `(sourceType, sourceId)` pair.

## Price Payload ABI

```solidity
struct PricePayload {
    uint256 feedId;
    uint64 roundId;
    uint64 resolvedAt;
    uint8 decimals;
    int256 price;
}
```

For the Binance index-kline provider:

- `roundId = bucketStartMs / intervalMs`
- `resolvedAt = bucketEndMs`
- `price` is the decimal `close` field scaled to the configured decimals
- the NativeOracle delivery nonce is independent from `roundId` and remains
  sequential for the feed

The canonical payload is `abi.encode(PricePayload)`. Provider-specific URI
parsing and exact closed-bucket checks are specified with the reth provider.

## Contract Validation

The resolver accepts a payload only when:

- the caller is the NativeOracle system contract
- `sourceType == 3`
- `sourceId == feedId`
- `roundId` is nonzero and greater than the latest accepted round
- `resolvedAt` is nonzero and greater than the latest accepted timestamp
- decimals do not exceed 18
- price is positive

Malformed payloads revert during ABI decoding. Any callback failure reverts the
entire NativeOracle delivery, so source progress does not advance and the same
delivery nonce remains retryable.

## Storage And History

`latestPrice(feedId)` exposes one fixed-size latest record per feed. A successful
new round overwrites the preceding record. The resolver does not retain raw
payloads or historical round mappings; historical values remain available from
`PriceResolved` logs and the authoritative upstream source.

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

The suite covers latest-round storage, independent feeds, bounded storage,
source identity, caller authorization, round and timestamp replay protection,
price and decimal validation, malformed payloads, callback gas failure, and
atomic retry behavior.
