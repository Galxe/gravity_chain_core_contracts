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

| Chain   | Contract     | System Address                           |
| ------- | ------------ | ---------------------------------------- |
| Gravity | NativeOracle | `0x0000000000000000000000000001625F2023` |

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

- **Must start from 1**: The first nonce for any source must be >= 1 (cannot be 0)
- **Strictly increasing**: Each subsequent nonce must be greater than the previous

```solidity
/// @notice Nonce (uint128)
/// @dev Must start from 1 and strictly increase for each source
///      Interpretation depends on source type:
///      - BLOCKCHAIN: Block number or event index
///      - JWK: Unix timestamp or sequence
///      - DNS: Unix timestamp or sequence
///      - PRICE_FEED: Sequence number or timestamp
uint128 nonce;
```

| Source Type | Nonce Meaning   | Example                     |
| ----------- | --------------- | --------------------------- |
| Blockchain  | Block number    | `19000000` (Ethereum block) |
| JWK         | Unix timestamp  | `1704067200`                |
| DNS         | Unix timestamp  | `1704067200`                |
| Custom      | Sequence number | `1`, `2`, `3`, ...          |

**Invariants:**

- `nonce >= 1` for the first record
- `nonce` must be strictly increasing for each (sourceType, sourceId) pair

### DataRecord

```solidity
struct DataRecord {
    uint64 recordedAt;  // Timestamp when recorded (0 = not exists)
    bytes data;         // Stored payload data
}
```

Record existence is determined by `recordedAt > 0`.

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
    /// @param nonce The nonce - must start from 1 and strictly increase
    /// @param payload The data payload to store
    /// @param callbackGasLimit Gas limit for callback execution (0 = no callback)
    function record(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload,
        uint256 callbackGasLimit
    ) external;

    /// @notice Batch record multiple data entries from the same source
    /// @dev Each payload is recorded at sequential nonces starting from the provided nonce.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The starting nonce for the batch
    /// @param payloads Array of payloads to store
    /// @param callbackGasLimit Gas limit for callback execution per record (0 = no callback)
    function recordBatch(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes[] calldata payloads,
        uint256 callbackGasLimit
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
    /// @dev Callback failures are caught - do NOT revert oracle recording
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param nonce The nonce of the record
    /// @param payload The event payload (encoding depends on event type)
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external;
}
```

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
) internal {
    address callback = _resolveCallback(sourceType, sourceId);
    if (callback == address(0)) return;

    try IOracleCallback(callback).onOracleEvent{gas: gasLimit}(
        sourceType, sourceId, nonce, payload
    ) {
        emit CallbackSuccess(sourceType, sourceId, nonce, callback);
    } catch (bytes memory reason) {
        emit CallbackFailed(sourceType, sourceId, nonce, callback, reason);
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
```

### Errors

```solidity
/// @dev For first record, latestNonce is 0, so nonce must be >= 1
error NonceNotIncreasing(uint32 sourceType, uint256 sourceId, uint128 currentNonce, uint128 providedNonce);
```

---

## Access Control Matrix

| Contract         | Function             | Allowed Callers |
| ---------------- | -------------------- | --------------- |
| **NativeOracle** |                      |                 |
|                  | record()             | SYSTEM_CALLER   |
|                  | recordBatch()        | SYSTEM_CALLER   |
|                  | setDefaultCallback() | GOVERNANCE      |
|                  | setCallback()        | GOVERNANCE      |
|                  | View functions       | Anyone          |

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
