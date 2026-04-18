---
status: draft
owner: @yxia
layer: oracle
---

# Native Oracle Specification

## Overview

The Native Oracle module enables Gravity to receive and store **verified external data** from any source. It is a single
contract deployed on Gravity that provides:

1. **Consensus-validated data recording** from any external source
2. **Flexible callback routing** based on source type and source ID
3. **Replay protection** via strictly increasing nonces

**Supported data sources include (extensible via governance):**

- **Blockchains**: Ethereum, other EVM chains (events, state roots, etc.)
- **JWK Keys**: OAuth providers (Google, Apple, etc.) for signature verification
- **DNS Records**: TXT records, DKIM keys for zkEmail
- **Price Feeds**: Stock prices, crypto prices, forex rates
- **Any custom source**: Extensible via governance

---

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL SOURCES                               │
│                                                                             │
│   Blockchains (ETH, BSC, ...)  │  JWK Providers  │  DNS  │  Price Feeds   │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Validators monitor external sources
                                    │ Reach consensus on data validity
                                    ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                              GRAVITY CHAIN                                  │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                    SYSTEM_CALLER (Consensus)                         │  │
│   │                    Calls record / recordBatch                        │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                         NativeOracle                                 │  │
│   │                                                                      │  │
│   │  • Stores verified data keyed by (sourceType, sourceId, nonce)     │  │
│   │  • Tracks latest nonce per source (sourceType, sourceId)           │  │
│   │  • Invokes callbacks with CALLER-SPECIFIED gas limit               │  │
│   │  • Callback failures do NOT revert recording                        │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                         │                                                   │
│                         │ Callback: onOracleEvent()                        │
│                         ▼                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                   Application Handlers                               │  │
│   │                   (Implement IOracleCallback)                        │  │
│   │                                                                      │  │
│   │  Examples:                                                           │  │
│   │  • BlockchainEventHandler → Handles cross-chain events              │  │
│   │  • JWKManager → Handles JWK key updates                             │  │
│   │  • PriceFeedHandler → Handles price updates                         │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

### Contract Deployment

| Chain   | Contract                   | System Address                           |
| ------- | -------------------------- | ---------------------------------------- |
| Gravity | NativeOracle               | `0x0000000000000000000000000001625F4000` |
| Gravity | OracleTaskConfig           | `0x0000000000000000000000000001625F1009` |
| Gravity | OnDemandOracleTaskConfig   | `0x0000000000000000000000000001625F100A` |
| Gravity | OracleRequestQueue         | see [oracle_evm_bridge.spec.md](./oracle_evm_bridge.spec.md) |

---

## Data Structures

### Source Type

Source types are represented as `uint32` values for extensibility. New source types can be added by governance without
requiring contract upgrades.

```solidity
/// @notice Source type identifier (uint32)
/// @dev Well-known types by convention:
///      0 = BLOCKCHAIN (cross-chain events from EVM chains)
///      1 = JWK (JSON Web Keys from OAuth providers)
///      2 = DNS (DNS records for zkEmail, etc.)
///      3 = PRICE_FEED (price data from oracles)
///      New types can be added without contract upgrades
uint32 sourceType;
```

| Value | Name       | Description                         |
| ----- | ---------- | ----------------------------------- |
| 0     | BLOCKCHAIN | Cross-chain events (Ethereum, BSC)  |
| 1     | JWK        | JSON Web Keys (Google, Apple OAuth) |
| 2     | DNS        | DNS records (TXT, DKIM keys)        |
| 3     | PRICE_FEED | Price data (stocks, crypto, forex)  |
| 4+    | (Reserved) | New types added via governance      |

### Source ID

The `sourceId` is a flexible `uint256` that uniquely identifies a specific source within a source type. Its
interpretation depends on the source type:

```solidity
/// @notice Source identifier (uint256)
/// @dev Interpretation depends on sourceType:
///      - BLOCKCHAIN: Chain ID (1 = Ethereum, 56 = BSC, etc.)
///      - JWK: Provider ID (1 = Google, 2 = Apple, etc.)
///      - DNS: Record type ID
///      - PRICE_FEED: Asset pair ID
uint256 sourceId;
```

| Source Type | Source ID | Example                     |
| ----------- | --------- | --------------------------- |
| BLOCKCHAIN  | `1`       | Ethereum mainnet (chain ID) |
| BLOCKCHAIN  | `56`      | BNB Smart Chain (chain ID)  |
| BLOCKCHAIN  | `42161`   | Arbitrum One (chain ID)     |
| JWK         | `1`       | Google OAuth                |
| JWK         | `2`       | Apple Sign-In               |
| DNS         | `1`       | TXT records                 |
| PRICE_FEED  | `1`       | ETH/USD                     |
| PRICE_FEED  | `2`       | BTC/USD                     |

### Nonce

The `nonce` is a `uint128` value that uniquely identifies a record within a (sourceType, sourceId) pair.

**Requirements:**

- **Must start from 1**: The first nonce for any source must be 1 (cannot be 0)
- **Sequential (no gaps)**: Each subsequent nonce must be exactly `previousNonce + 1` — strictly increasing is *not* sufficient. The contract reverts with `NonceNotSequential(sourceType, sourceId, expected, provided)` on any gap or duplicate.

```solidity
/// @notice Nonce (uint128)
/// @dev Must start from 1 and increment by exactly 1 per record per source
uint128 nonce;
```

| Source Type | Nonce Meaning   | Example                     |
| ----------- | --------------- | --------------------------- |
| Blockchain  | Monotonic seq   | `1`, `2`, `3`, ...          |
| JWK         | Monotonic seq   | `1`, `2`, `3`, ...          |
| DNS         | Monotonic seq   | `1`, `2`, `3`, ...          |
| Custom      | Monotonic seq   | `1`, `2`, `3`, ...          |

**Invariants:**

- `nonce == 1` for the first record per source
- For each (sourceType, sourceId) pair, consecutive records MUST satisfy `newNonce == latestNonce + 1`

### DataRecord

```solidity
struct DataRecord {
    uint64  recordedAt;   // EVM block.timestamp seconds when recorded (0 = not exists). NOTE: seconds, not Gravity microseconds.
    uint256 blockNumber;  // Source block number the record refers to (meaning depends on sourceType — e.g. the Ethereum block that emitted the event)
    bytes   data;         // Stored payload data
}
```

Record existence is determined by `recordedAt > 0`. `blockNumber` is carried independently of `nonce` so that a single source can mix sequence-based ordering with source-block provenance.

---

## Contract: NativeOracle

Stores verified data from external sources. Only writable by SYSTEM_CALLER via consensus.

### State Variables

```solidity
/// @notice Data records: sourceType -> sourceId -> nonce -> DataRecord
mapping(uint32 => mapping(uint256 => mapping(uint128 => DataRecord))) private _records;

/// @notice Latest nonce per source: sourceType -> sourceId -> nonce
mapping(uint32 => mapping(uint256 => uint128)) private _nonces;

/// @notice Default callback handlers: sourceType -> callback contract
/// @dev Fallback callback for all sources of a given type
mapping(uint32 => address) private _defaultCallbacks;

/// @notice Specialized callback handlers: sourceType -> sourceId -> callback contract
/// @dev Overrides default callback for specific (sourceType, sourceId) pairs
mapping(uint32 => mapping(uint256 => address)) private _callbacks;
```

### Interface

```solidity
interface INativeOracle {
    // ========== Recording (SYSTEM_CALLER Only) ==========

    /// @notice Record a single data entry
    /// @param sourceType The source type (uint32, e.g., 0 = BLOCKCHAIN, 1 = JWK)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param nonce The nonce - must equal `currentNonce + 1` for this (sourceType, sourceId)
    /// @param blockNumber The source block number (provenance, NOT used for ordering)
    /// @param payload The data payload to store
    /// @param callbackGasLimit Gas limit for callback execution (0 = invoke no callback, emit CallbackSkipped and store)
    function record(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        uint256 blockNumber,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external;

    /// @notice Batch record multiple data entries from the same source
    /// @dev Each record is validated individually with its own nonce/blockNumber/callbackGasLimit.
    ///      Callers typically pass strictly sequential nonces; the contract validates each as currentNonce+1.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonces Array of nonces (length N)
    /// @param blockNumbers Array of source block numbers (length N)
    /// @param payloads Array of payloads (length N)
    /// @param callbackGasLimits Array of per-record gas limits (length N)
    function recordBatch(
        uint32 sourceType,
        uint256 sourceId,
        uint128[] calldata nonces,
        uint256[] calldata blockNumbers,
        bytes[] calldata payloads,
        uint256[] calldata callbackGasLimits
    ) external;

    // ========== Callback Management (GOVERNANCE Only) ==========
    //
    // Callbacks use a 2-layer resolution system:
    //   1. Default callback per sourceType - applies to all sources of that type
    //   2. Specialized callback per (sourceType, sourceId) - overrides default
    //
    // When an oracle event is recorded, the system first checks for a specialized
    // callback. If none is set, it falls back to the default callback for that
    // source type.

    /// @notice Register default callback for a source type
    function setDefaultCallback(uint32 sourceType, address callback) external;

    /// @notice Get default callback for a source type
    function getDefaultCallback(uint32 sourceType) external view returns (address);

    /// @notice Register specialized callback for a specific source (overrides default)
    function setCallback(uint32 sourceType, uint256 sourceId, address callback) external;

    /// @notice Get effective callback for a source (2-layer resolution)
    /// @dev Returns specialized if set, otherwise default
    function getCallback(uint32 sourceType, uint256 sourceId) external view returns (address);

    // ========== Query Functions ==========

    /// @notice Get a record by its key tuple
    /// @dev Record exists if record.recordedAt > 0
    function getRecord(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (DataRecord memory record);

    /// @notice Get the latest nonce for a source
    function getLatestNonce(
        uint32 sourceType,
        uint256 sourceId
    ) external view returns (uint128 nonce);

    /// @notice Check if synced past a certain point
    function isSyncedPast(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce
    ) external view returns (bool);
}
```

### Callback Interface

```solidity
interface IOracleCallback {
    /// @notice Called when an oracle event is recorded
    /// @dev Callback failures are caught — do NOT revert oracle recording.
    ///      The returned `shouldStore` flag tells NativeOracle whether to persist the payload
    ///      into the `_records` mapping. Returning `false` lets callbacks that fully consume the
    ///      payload (e.g., apply it to their own state) avoid paying for redundant storage.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param payload The event payload (encoding depends on event type)
    /// @return shouldStore If true, NativeOracle writes the DataRecord; if false, storage is skipped
    ///                    (a `StorageSkipped` event is emitted instead).
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external returns (bool shouldStore);
}
```

**Storage semantics**:
- No callback registered → payload is always stored.
- Callback registered but `callbackGasLimit == 0` → `CallbackSkipped` event, payload is still stored.
- Callback succeeds and returns `true` → `CallbackSuccess` event, payload stored.
- Callback succeeds and returns `false` → `CallbackSuccess` + `StorageSkipped` events, payload NOT stored (the callback "consumed" the data).
- Callback reverts or runs out of gas → `CallbackFailed` event with revert bytes, payload stored anyway (fail-safe).

### Callback Resolution (2-Layer System)

The callback system uses a 2-layer resolution:

1. **Default callback per sourceType**: Applies to all sources of that type (e.g., all blockchain events)
2. **Specialized callback per (sourceType, sourceId)**: Overrides the default for specific sources (e.g., only Ethereum
   events)

```solidity
/// @notice Resolve callback using 2-layer lookup
function _resolveCallback(
    uint32 sourceType,
    uint256 sourceId
) internal view returns (address callback) {
    // First check for specialized callback
    address specialized = _callbacks[sourceType][sourceId];
    if (specialized != address(0)) {
        return specialized;
    }
    // Fall back to default callback for this source type
    return _defaultCallbacks[sourceType];
}

function _invokeCallback(
    uint32 sourceType,
    uint256 sourceId,
    uint128 nonce,
    bytes calldata payload,
    uint256 gasLimit
) internal returns (bool shouldStore) {
    address callback = _resolveCallback(sourceType, sourceId);
    if (callback == address(0)) return true;           // no callback → store
    if (gasLimit == 0) {
        emit CallbackSkipped(sourceType, sourceId, nonce, callback);
        return true;                                    // skip invocation, still store
    }

    try IOracleCallback(callback).onOracleEvent{gas: gasLimit}(
        sourceType, sourceId, nonce, payload
    ) returns (bool callbackShouldStore) {
        emit CallbackSuccess(sourceType, sourceId, nonce, callback);
        if (!callbackShouldStore) {
            emit StorageSkipped(sourceType, sourceId, nonce, callback);
        }
        return callbackShouldStore;
    } catch (bytes memory reason) {
        emit CallbackFailed(sourceType, sourceId, nonce, callback, reason);
        return true;                                    // on failure, store by default to preserve data
    }
}
```

**Example Usage:**

```
// Set a handler as default callback for all BLOCKCHAIN events
governance.setDefaultCallback(0, blockchainEventHandlerAddress);

// Now all blockchain events (Ethereum, Arbitrum, BSC, etc.) route to the handler

// Optionally, set a specialized callback for a specific chain (e.g., Optimism chain ID 10)
governance.setCallback(0, 10, optimismSpecialHandlerAddress);

// Now: Optimism events → optimismSpecialHandler, all other chains → blockchainEventHandler
```

### Events

```solidity
/// @notice Emitted when data is recorded
event DataRecorded(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 nonce,
    uint256 dataLength
);

/// @notice Emitted when a default callback is registered or updated
event DefaultCallbackSet(
    uint32 indexed sourceType,
    address indexed oldCallback,
    address newCallback
);

/// @notice Emitted when a specialized callback is registered or updated
event CallbackSet(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    address indexed oldCallback,
    address newCallback
);

/// @notice Emitted when a callback succeeds
event CallbackSuccess(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 nonce,
    address callback
);

/// @notice Emitted when a callback fails (tx continues, does NOT revert)
event CallbackFailed(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 nonce,
    address callback,
    bytes reason
);

/// @notice Emitted when a callback is registered but gasLimit == 0 was passed (callback not invoked; record still stored)
event CallbackSkipped(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 nonce,
    address callback
);

/// @notice Emitted when the callback returned shouldStore == false — the payload is NOT persisted
event StorageSkipped(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 nonce,
    address callback
);
```

### Errors

```solidity
/// @notice The provided nonce was not exactly currentNonce + 1
/// @param expectedNonce currentNonce + 1 (= 1 on first record)
/// @param providedNonce The nonce supplied in the call
error NonceNotSequential(
    uint32 sourceType,
    uint256 sourceId,
    uint128 expectedNonce,
    uint128 providedNonce
);

/// @notice recordBatch array-length mismatch
error OracleBatchArrayLengthMismatch(
    uint256 noncesLen,
    uint256 blockNumbersLen,
    uint256 payloadsLen,
    uint256 callbackGasLimitsLen
);
```

---

## Access Control Matrix

| Contract                 | Function                               | Allowed Callers        |
| ------------------------ | -------------------------------------- | ---------------------- |
| **NativeOracle**         |                                        |                        |
|                          | initialize()                           | GENESIS (once)         |
|                          | record()                               | SYSTEM_CALLER          |
|                          | recordBatch()                          | SYSTEM_CALLER          |
|                          | setDefaultCallback()                   | GOVERNANCE             |
|                          | setCallback()                          | GOVERNANCE             |
|                          | View functions                         | Anyone                 |
| **OracleTaskConfig**     |                                        |                        |
|                          | setTask()                              | GENESIS or GOVERNANCE  |
|                          | removeTask()                           | GOVERNANCE             |
|                          | View / enumeration functions           | Anyone                 |
| **OnDemandOracleTaskConfig** |                                    |                        |
|                          | setTask() / removeTask()               | GOVERNANCE             |
|                          | View / enumeration functions           | Anyone                 |

---

## Contract: OracleTaskConfig

Stores configuration for **continuous** oracle tasks that validators actively monitor off-chain. Tasks are keyed by `(sourceType, sourceId, taskName)`, allowing multiple tasks per source (e.g., an Ethereum chain can have a JWK-sync task, a block-header task, and a price-feed task simultaneously).

### System Address

| Constant | Address |
|----------|---------|
| `ORACLE_TASK_CONFIG` | `0x0000000000000000000000000001625F1009` |

### Types

```solidity
struct OracleTask {
    bytes config;       // Opaque task configuration (schema depends on sourceType)
    uint64 updatedAt;   // Block timestamp (seconds) of last update
}

struct FullTaskInfo {
    uint32 sourceType;
    uint256 sourceId;
    bytes32 taskName;
    bytes config;
    uint64 updatedAt;
}
```

### Interface

```solidity
interface IOracleTaskConfig {
    event TaskSet(uint32 indexed sourceType, uint256 indexed sourceId, bytes32 indexed taskName, bytes config);
    event TaskRemoved(uint32 indexed sourceType, uint256 indexed sourceId, bytes32 indexed taskName);

    // GOVERNANCE (+ GENESIS for setTask only)
    function setTask(uint32 sourceType, uint256 sourceId, bytes32 taskName, bytes calldata config) external;
    function removeTask(uint32 sourceType, uint256 sourceId, bytes32 taskName) external;

    // Queries
    function getTask(uint32 sourceType, uint256 sourceId, bytes32 taskName) external view returns (OracleTask memory);
    function hasTask(uint32 sourceType, uint256 sourceId, bytes32 taskName) external view returns (bool);
    function getTaskNames(uint32 sourceType, uint256 sourceId) external view returns (bytes32[] memory);
    function getTaskCount(uint32 sourceType, uint256 sourceId) external view returns (uint256);
    function getTaskNameAt(uint32 sourceType, uint256 sourceId, uint256 index) external view returns (bytes32);
    function getSourceTypes() external view returns (uint32[] memory);
    function getSourceIds(uint32 sourceType) external view returns (uint256[] memory);
    function getAllTasks() external view returns (FullTaskInfo[] memory);
}
```

### Behavior Notes

- `setTask()` reverts with `EmptyConfig` if `config.length == 0`.
- Setting `taskName` that already exists overwrites in place (same `updatedAt` refresh).
- `removeTask()` cleans up empty source-id and source-type registrations to keep the enumeration helpers bounded.

---

## Contract: OnDemandOracleTaskConfig

Parallel configuration contract for **on-demand** oracle tasks (pull-based requests fulfilled by the queue in `OracleRequestQueue`). Same `(sourceType, sourceId, taskName)` keying and the same interface shape as `OracleTaskConfig`; the two are kept separate so validators can distinguish continuous-monitoring tasks from request/response workflows.

### System Address

| Constant | Address |
|----------|---------|
| `ON_DEMAND_ORACLE_TASK_CONFIG` | `0x0000000000000000000000000001625F100A` |

See `src/oracle/ondemand/` for the full on-demand-specific flow (request queue, fulfillment, timeouts).

---

## Security Considerations

1. **Consensus Required**: All oracle data requires validator consensus via SYSTEM_CALLER
2. **Callback Gas Limits**: Caller-specified gas limit prevents excessive gas consumption
3. **Callback Failure Tolerance**: Failures do NOT revert oracle recording
4. **GOVERNANCE Control**: Callback registration requires governance approval
5. **Nonce Ordering**: Must start from 1 and strictly increase - prevents replay and ensures data freshness

---

## Invariants

1. **Nonce Monotonicity**: For each (sourceType, sourceId), `latestNonce` only increases
2. **Nonce Minimum**: First nonce for any source must be >= 1
3. **Record Existence**: If `recordedAt > 0`, record was written by SYSTEM_CALLER
4. **Callback Safety**: Callback failures never affect oracle state

---

## Testing Requirements

### Unit Tests

1. **NativeOracle**
   - Record data with sourceType, sourceId, nonce
   - Batch recording with sequential nonces
   - Nonce validation (must start from 1, must increase)
   - Callback invocation with specified gas limit
   - Callback failure handling (should not revert)
   - 2-layer callback resolution:
     - Default callback per sourceType
     - Specialized callback per (sourceType, sourceId)
     - Specialized overrides default
     - Fallback to default when no specialized set
   - GOVERNANCE callback registration (setDefaultCallback, setCallback)
   - Query functions (getRecord, getLatestNonce, isSyncedPast)

### Fuzz Tests

1. **Random payloads and amounts**
2. **Nonce ordering**
3. **Nonce boundaries (must be >= 1)**
4. **SourceType and SourceId combinations**
5. **Callback gas limit boundaries**

---

## Future Extensions

1. **Additional Source Types**: DNS verification, price feeds, etc.
2. **Batch Recording Optimization**: Gas-optimized batch operations
3. **Callback Prioritization**: Multiple callbacks per source with priority
