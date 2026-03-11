# implement_native_oracle_data_recording

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 58567ms
- **Steps**: 1

## Report

## NativeOracle Implementation Summary

### Files/Contracts Involved

| File | Description |
|------|-------------|
| `src/oracle/NativeOracle.sol` | Main implementation contract |
| `src/oracle/INativeOracle.sol` | Interface (`INativeOracle`) + callback interface (`IOracleCallback`) |
| `src/foundation/SystemAddresses.sol` | Compile-time address constants |
| `src/foundation/SystemAccessControl.sol` | `requireAllowed()` — reverts if `msg.sender != allowed` |
| `src/foundation/Errors.sol` | Custom error definitions |

---

### State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `_records` | `mapping(uint32 => mapping(uint256 => mapping(uint128 => DataRecord)))` | Stored data keyed by `(sourceType, sourceId, nonce)` |
| `_nonces` | `mapping(uint32 => mapping(uint256 => uint128))` | Latest nonce per `(sourceType, sourceId)` |
| `_defaultCallbacks` | `mapping(uint32 => address)` | Default callback per `sourceType` |
| `_callbacks` | `mapping(uint32 => mapping(uint256 => address))` | Specialized callback per `(sourceType, sourceId)` |
| `_initialized` | `bool` | One-time initialization flag |

---

### Key Functions

#### Initialization

**`initialize(uint32[] sourceTypes, address[] callbacks)`** — Access: `GENESIS` only
1. Reverts if `_initialized == true`
2. Validates array lengths match
3. Iterates, setting `_defaultCallbacks[sourceTypes[i]] = callbacks[i]` and emitting `DefaultCallbackSet`
4. Sets `_initialized = true`

#### Data Recording

**`record(uint32 sourceType, uint256 sourceId, uint128 nonce, uint256 blockNumber, bytes payload, uint256 callbackGasLimit)`** — Access: `SYSTEM_CALLER` only

Execution path:
1. Calls `_updateNonce(sourceType, sourceId, nonce)` — enforces sequential nonce
2. If `callbackGasLimit > 0`, calls `_invokeCallback(...)` which returns `shouldStore`; otherwise `shouldStore = true`
3. If `shouldStore`, writes `DataRecord{recordedAt: block.timestamp, blockNumber, data: payload}` into `_records` and emits `DataRecorded`

**`recordBatch(uint32 sourceType, uint256 sourceId, uint128[] nonces, uint256[] blockNumbers, bytes[] payloads, uint256[] callbackGasLimits)`** — Access: `SYSTEM_CALLER` only

1. Returns early if `nonces.length == 0`
2. Validates all 4 arrays have equal length, reverts with `OracleBatchArrayLengthMismatch` otherwise
3. Iterates calling `_recordSingle(...)` for each entry

**`_recordSingle(...)`** — `private`, same logic as `record()` (nonce update → callback → conditional store)

#### Sequential Nonce Enforcement

**`_updateNonce(uint32 sourceType, uint256 sourceId, uint128 nonce)`** — `internal`
1. Reads `currentNonce = _nonces[sourceType][sourceId]` (defaults to 0)
2. Reverts with `NonceNotSequential` if `nonce != currentNonce + 1`
3. Writes `_nonces[sourceType][sourceId] = nonce`

This means the first nonce must be `1`, and each subsequent nonce must increment by exactly 1.

#### 2-Layer Callback Resolution

**`_resolveCallback(uint32 sourceType, uint256 sourceId)`** — `internal view`
1. Checks `_callbacks[sourceType][sourceId]` (specialized)
2. If non-zero, returns it
3. Otherwise returns `_defaultCallbacks[sourceType]` (may be `address(0)`)

#### Callback Invocation with Gas Limit (DOS Protection)

**`_invokeCallback(uint32 sourceType, uint256 sourceId, uint128 nonce, bytes payload, uint256 gasLimit)`** — `internal`, returns `bool shouldStore`
1. Resolves callback via `_resolveCallback`
2. If `address(0)`, returns `true` (store by default)
3. Calls `IOracleCallback(callback).onOracleEvent{gas: gasLimit}(sourceType, sourceId, nonce, payload)` inside a `try/catch`
   - **Success path**: Emits `CallbackSuccess`. If callback returned `shouldStore = false`, emits `StorageSkipped`. Returns the callback's `shouldStore` value.
   - **Failure path**: Emits `CallbackFailed` with the revert `reason`. Returns `true` (store by default to preserve data).

The `{gas: gasLimit}` syntax caps the gas forwarded to the callback, preventing a malicious/buggy callback from consuming all gas. The `try/catch` ensures callback failures never revert the oracle recording.

#### Governance-Controlled Callback Management

**`setDefaultCallback(uint32 sourceType, address callback)`** — Access: `GOVERNANCE` only
- Overwrites `_defaultCallbacks[sourceType]`, emits `DefaultCallbackSet` with old and new values

**`setCallback(uint32 sourceType, uint256 sourceId, address callback)`** — Access: `GOVERNANCE` only
- Overwrites `_callbacks[sourceType][sourceId]`, emits `CallbackSet` with old and new values

Both accept `address(0)` to unregister a callback.

#### Query Functions

| Function | Returns |
|----------|---------|
| `getRecord(sourceType, sourceId, nonce)` | `DataRecord` (existence check: `recordedAt > 0`) |
| `getLatestNonce(sourceType, sourceId)` | `uint128` latest nonce (`0` if no records) |
| `isSyncedPast(sourceType, sourceId, nonce)` | `bool` — `true` if `latestNonce > 0 && latestNonce >= nonce` |
| `getDefaultCallback(sourceType)` | Raw `_defaultCallbacks[sourceType]` |
| `getCallback(sourceType, sourceId)` | 2-layer resolved: specialized first, then default |

---

### State Changes Summary

| Operation | Storage Modified |
|-----------|-----------------|
| `initialize` | `_defaultCallbacks[sourceType]` for each entry; `_initialized → true` |
| `record` / `recordBatch` | `_nonces[sourceType][sourceId]` incremented; `_records[sourceType][sourceId][nonce]` written (conditional on `shouldStore`) |
| `setDefaultCallback` | `_defaultCallbacks[sourceType]` |
| `setCallback` | `_callbacks[sourceType][sourceId]` |

### External Dependencies

| Dependency | Usage |
|------------|-------|
| `IOracleCallback.onOracleEvent(...)` | External call to callback contracts via `try/catch` with gas limit |
| `SystemAddresses.SYSTEM_CALLER` | `0x1625F0000` — access control for recording |
| `SystemAddresses.GOVERNANCE` | `0x1625F3000` — access control for callback management |
| `SystemAddresses.GENESIS` | `0x1625F0001` — access control for initialization |
| `requireAllowed(address)` | Free function from `SystemAccessControl.sol` — reverts with `NotAllowed` if `msg.sender != allowed` |

### Access Control Map

| Function | Caller |
|----------|--------|
| `initialize` | `GENESIS` (`0x1625F0001`) |
| `record`, `recordBatch` | `SYSTEM_CALLER` (`0x1625F0000`) |
| `setDefaultCallback`, `setCallback` | `GOVERNANCE` (`0x1625F3000`) |
| `getRecord`, `getLatestNonce`, `isSyncedPast`, `getDefaultCallback`, `getCallback` | Anyone (view) |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | ## NativeOracle Implementation Summary

### Files/Contracts  | 58567ms |
