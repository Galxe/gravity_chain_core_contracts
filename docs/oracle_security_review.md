# Oracle Security Review

## Scope

This review covers the production-candidate Oracle files on this branch:

- `NativeOracle` callback and replay boundary
- `PriceFeedResolver`
- `PolymarketSettlementResolver`
- `PolymarketBinaryMarket`
- `PolymarketMatchMarket`
- the corresponding Binance and Polygon relayer adapters
- the SDK cached-resend and restart-reconciliation path

It is not a whole-protocol audit and is not approval for a real-money launch.

## Result

The contract-level finding that allowed betting after a mirrored settlement was
already available is fixed on this branch. This does not clear the cross-layer
Oracle path for production: two consensus-sensitive blockers remain outside the
market contracts.

| Cross-layer blocker | Status |
| --- | --- |
| JWK QC aggregate signature is not verified at the Gravity execution boundary | Known / open |
| New source routing and callback-gas semantics need coordinated activation | Open |

The PoC remains suitable for deterministic local testing, not a real-money
launch.

## Hardening Completed

Price feed:

- removed the Hype adapter and direct sports/news runtime paths
- made `provider` mandatory; inline observations require the explicit
  `inline_fixture_v1` test provider
- moved Binance endpoints to validator-local configuration and reject `baseUrl`
  in consensus task URIs
- bind each request to one exact closed bucket and verify returned open/close
  timestamps
- derive round id, resolved time, and source block from the bucket; URI
  overrides are rejected
- stream responses into a bounded buffer and cap request time, decimals, and
  observation count
- make a continuous feed origin immutable for one feed id
- reconcile nonce and bucket cursor so fixed tasks are idempotent after restart
  and reject buckets older than confirmed history
- align execution callback gas with a maximum-size resolver test

Polymarket mirror:

- require one exact condition id and Polygon chain id `137`
- use finalized blocks and a bounded exclusive block cursor
- cap scan range and payout slot count
- fail closed on malformed filtered logs or missing source identity without
  cursor advancement
- reject multiple distinct settlements for one condition and stop scanning
  after the immutable settlement
- keep mirror registration and accepted settlement immutable

Contracts and SDK:

- preserve raw `NativeOracle` records on callback failure and provide
  permissionless replay from those records; historical price replay cannot
  rewind the latest round
- validate deployed resolver/collateral code and reject non-exact collateral
  deposits and payouts
- use pull claims with `SafeERC20`, `ReentrancyGuard`, and effects before token
  transfers
- reject market creation and new bets after the configured resolver exposes a
  settlement for the condition
- use `Math.mulDiv` for proportional payouts
- reject unknown markets, duplicate source ids, split payouts, stale rounds,
  future observations, and arithmetic bounds violations
- cache fetched consensus bytes until the on-chain nonce catches up
- decode UnsupportedJWK wrappers with canonical ABI validation and return an
  explicit error for disabled RSA payloads instead of panicking
- redact endpoint credentials and local path components from relayer logs

## Residual Product Decisions

### Proportional payout dust

`Math.mulDiv` rounds each claim down. Some market/token combinations can leave a
small residual balance in the market contract. Before real-money deployment,
choose and test a policy such as assigning the final residual to the last
winning claimant or sweeping it after a claim deadline. The current behavior is
deterministic but does not expose a sweep path.

### Void liveness

Settlement eligibility is fixed by the consensus record time: only a valid
observation with `recordedAt < oracleDeadline` may settle. A timely payload that
is pending resolver replay blocks `voidMarket`; after replay it can settle using
the original record time. An observation at or after the deadline, no
observation, or an invalid stored payload permits governance to void once the
deadline is reached. `voidMarket` remains governance-only, so user refunds still
depend on governance liveness. Decide whether the final product keeps this
policy or permits anyone to trigger the same deterministic void rule.

### Challenge delay

A market can settle as soon as the finalized Polygon settlement reaches the
resolver. Decide whether the product needs an additional Gravity-side challenge
or cooling-off delay before claims, especially for large markets.

## Verification Gates

```bash
forge test --skip DeployBridgeHandoff --match-path 'test/unit/oracle/*.t.sol'
cargo test -p reth-pipe-exec-layer-relayer
cargo test -p reth-pipe-exec-layer-ext-v2 --lib jwk_oracle
./gravity_e2e/run_test.sh oracle_demo --force-init
```

Live Binance and Polygon probes are manual, approval-gated checks. They do not
replace the deterministic local suite.
