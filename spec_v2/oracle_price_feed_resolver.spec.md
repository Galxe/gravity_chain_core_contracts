---
title: Binance Price Feed Resolver Specification
status: production candidate
---

# Binance Price Feed Resolver

This specification defines the contract boundary for Gravity's Binance USD-M
index-price feed. Validators fetch one exact closed `indexPriceKlines` bucket,
reach consensus on its canonical payload, and `PriceFeedResolver` stores the
close price for on-chain consumers.

## Scope

The production-candidate branch has two oracle products:

| Source type | Product | Upstream authority | Contract consumer |
| --- | --- | --- | --- |
| `3` | Price feed | Closed Binance index-price kline | `PriceFeedResolver` |
| `6` | Polymarket mirror | Finalized Polygon CTF `ConditionResolution` | `PolymarketSettlementResolver` |

Source type `3` deliberately supports one provider and one observation per
round. Multi-provider weighting, thresholds, and aggregation modes are outside
this ABI.

## Price Payload

```solidity
struct PricePayload {
    uint256 feedId;
    uint64 roundId;
    uint64 resolvedAt;
    uint8 decimals;
    int256 price;
}
```

For Binance index klines:

- `roundId = bucketStartMs / intervalMs`
- `resolvedAt = bucketEndMs`
- `price` is the decimal `close` field scaled to the configured decimals
- delivery nonce is independent from `roundId` and remains sequential in
  `NativeOracle`

The task URI binds a `feedId` to one Binance pair and immutable bucket origin.
The validator adapter verifies that Binance returns the exact requested open
and close timestamps before it proposes bytes.

## Validation

The resolver rejects a payload when any of the following is true:

- `sourceId != feedId`
- `roundId` is zero or not greater than the latest stored round
- `resolvedAt` is not greater than the latest stored resolution time
- the same `(feedId, roundId)` was already resolved
- decimals exceed 18
- price is zero or negative

The validator adapter also validates the upstream response, scaling, and exact
bucket timestamps. Contract validation remains authoritative for the payload
shape and state-transition invariants.

## Storage

`latestPrice(feedId)` exposes the newest accepted Binance close.
`priceRounds(feedId, roundId)` retains historical rounds. No weighted mean,
weighted median, source count, or total weight is computed or stored.

## Callback Failure Recovery

`NativeOracle` deliberately advances its nonce and stores raw payload bytes when
a callback fails. `replayPrice(feedId, nonce)` reads those consensus-approved
bytes from `NativeOracle.getRecord` and applies the normal validation path.

The function is permissionless because callers cannot supply or alter the
payload. A missing historical round can be backfilled after newer rounds exist;
replay never rewinds `latestPrice`.

Operators should alert on `CallbackFailed` and call replay only after confirming
the callback contract and configuration are healthy.

## Configuration Boundary

The on-chain URI identifies deterministic work:

```text
gravity://3/<feedId>/price_feed
  ?provider=binance_index_kline_v1
  &pair=<PAIR>
  &interval=1m
  &bucketStartMs=<aligned start>
  &decimals=8
  &graceMs=<milliseconds>
```

The Binance base URL is validator-local relayer configuration. `baseUrl` in the
on-chain URI is rejected so endpoints, tenant paths, and credentials cannot be
published or become part of consensus identity.

The relayer rejects legacy multi-source parameters, including
`aggregationMode`, `weight`, `minSourceCount`, `minTotalWeight`,
`maxStaleness`, and `observations`.

## Tests

Contract coverage:

```bash
forge test --skip DeployBridgeHandoff --match-path 'test/unit/oracle/*.t.sol'
```

The focused `PriceFeedResolver` suite covers direct Binance-close storage,
round and timestamp monotonicity, price and decimal validation, source-id
binding, raw-payload preservation, and callback replay.
