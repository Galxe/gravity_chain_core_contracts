---
title: Price Feed Resolver Specification
status: production candidate
---

# Price Feed Resolver

This specification defines the contract boundary for Gravity price feeds. The
supported validator adapter is Binance USD-M `indexPriceKlines`; aggregation and
round storage are implemented by `PriceFeedResolver`.

`MultiSourceOracleResolver` remains as a compatibility contract name and
inherits the complete `PriceFeedResolver` ABI. New integrations should use the
new name in documentation and deployment manifests.

## Scope

The production-candidate branch has two oracle products:

| Source type | Product | Upstream authority | Contract consumer |
| --- | --- | --- | --- |
| `3` | Price feed | Closed Binance index-price kline | `PriceFeedResolver` |
| `6` | Polymarket mirror | Finalized Polygon CTF `ConditionResolution` | `PolymarketSettlementResolver` |

Direct HTTP sports-score and news adapters are not part of this scope. Sports
markets are represented by mirrored Polymarket CTF conditions.

## Price Payload

```solidity
struct PriceObservation {
    bytes32 dataSourceId;
    uint64 observedAt;
    int256 price;
    uint256 weight;
}

struct PricePayload {
    uint256 feedId;
    uint64 roundId;
    uint64 resolvedAt;
    uint8 decimals;
    uint8 aggregationMode;
    uint256 minSourceCount;
    uint256 minTotalWeight;
    uint64 maxStaleness;
    PriceObservation[] observations;
}
```

For Binance index klines:

- `roundId = bucketStartMs / intervalMs`
- `resolvedAt = bucketEndMs`
- `observedAt = closeTime = bucketEndMs`
- `price` is the decimal `close` field scaled to the configured decimals
- the current Binance adapter uses one observation with weight `1`
- delivery nonce is independent from `roundId` and remains sequential in
  `NativeOracle`

## Validation

The resolver rejects a payload when any of the following is true:

- `sourceId != feedId`
- `roundId` is not greater than the latest stored round
- there are zero observations or more than 16 observations
- decimals exceed 18
- `minSourceCount` or `minTotalWeight` is zero
- an observation has a zero source id, non-positive price, or zero weight
- two observations use the same `dataSourceId`
- `observedAt > resolvedAt`
- an observation is older than `maxStaleness`
- total or weighted arithmetic exceeds signed 256-bit bounds
- aggregation mode is not weighted mean (`1`) or weighted median (`2`)

The validator adapter performs the same canonical checks before proposing bytes.
Contract validation remains authoritative because callback payloads must be safe
even if adapter code changes later.

## Aggregation

Weighted mean is:

```text
sum(price[i] * weight[i]) / sum(weight[i])
```

Weighted median is the first price whose cumulative weight reaches
`ceil(totalWeight / 2)`. Input order does not affect the result.

The current Binance adapter sends one observation, so both modes return the same price.
The multi-observation ABI is retained for a later provider set without requiring
a contract migration.

## Callback Failure Recovery

`NativeOracle` deliberately advances its nonce and stores raw payload bytes when
a callback fails. Without a replay path, a temporary callback gas or deployment
ordering problem would leave application state permanently behind.

`replayPrice(feedId, nonce)` reads the payload from `NativeOracle.getRecord` and
applies the normal validation and aggregation path. The function is permissionless
because callers cannot supply or alter the payload. A missing historical round
can be backfilled after newer rounds exist; replay never rewinds `latestPrice`.

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
  &continuous=true
  &decimals=8
  &aggregationMode=2
  &minSourceCount=1
  &minTotalWeight=1
  &maxStaleness=<milliseconds>
  &graceMs=<milliseconds>
```

The Binance base URL is validator-local relayer configuration. `baseUrl` in the
on-chain URI is rejected so endpoints, tenant paths, and credentials cannot be
published or become part of consensus identity.

## Tests

Contract coverage:

```bash
forge test --skip DeployBridgeHandoff --match-path 'test/unit/oracle/*.t.sol'
```

The focused `PriceFeedResolver` suite covers weighted mean, weighted median,
future observations, observation limits, raw-payload preservation, callback
replay, and the compatibility contract name.
