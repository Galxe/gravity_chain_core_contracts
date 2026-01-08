---
status: draft
owner: @yxia
layer: oracle
---

# Native Oracle Specification

## Overview

The Native Oracle module enables Gravity to receive and store **verified external data** from any source. It consists of multiple contracts deployed across chains, providing:

1. **Message bridging** from external blockchains via fee-based portals
2. **Consensus-validated data recording** on Gravity
3. **Flexible callback routing** based on event type and sender
4. **Native token bridging** (G token: ERC20 on Ethereum ↔ native on Gravity)

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
│                              ETHEREUM                                       │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                        GravityPortal                                 │  │
│   │                                                                      │  │
│   │  • Fee-based message bridge (baseFee + feePerByte)                  │  │
│   │  • Two modes: sendMessage (hash) / sendMessageWithData (full)       │  │
│   │  • Encodes: abi.encode(msg.sender, nonce, message)                  │  │
│   │  • Emits MessageSent / MessageSentWithData events                   │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                     ▲                                       │
│                                     │ Calls sendMessage()                  │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                          GTokenBridge                                │  │
│   │                                                                      │  │
│   │  • Locks G tokens (ERC20) in escrow                                 │  │
│   │  • Calls GravityPortal with bridge message                          │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ Consensus engine monitors events
                                     │ Validators reach consensus
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                              GRAVITY CHAIN                                  │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                    SYSTEM_CALLER (Consensus)                         │  │
│   │                    Calls recordHash / recordData                     │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                         NativeOracle                                 │  │
│   │                                                                      │  │
│   │  • Stores verified hashes and data                                  │  │
│   │  • Tracks sync status per source (sourceType + sourceId)            │  │
│   │  • Invokes callbacks with LIMITED GAS (500,000)                     │  │
│   │  • Callback failures do NOT revert recording                        │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                         │                                                   │
│                         │ Callback: onOracleEvent()                        │
│                         ▼                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                   BlockchainEventRouter                              │  │
│   │                   (Callback for BLOCKCHAIN events)                   │  │
│   │                                                                      │  │
│   │  • Decodes sender from payload                                      │  │
│   │  • Routes to handlers based on sender address                       │  │
│   │  • Handler registration controlled by GOVERNANCE                    │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                         │                                                   │
│                         │ handleMessage() by sender                        │
│                         ▼                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                      NativeTokenMinter                               │  │
│   │                      (Handler for GTokenBridge)                      │  │
│   │                                                                      │  │
│   │  • Verifies sender is trusted GTokenBridge                          │  │
│   │  • Mints native G tokens via system precompile                      │  │
│   │  • Tracks processed nonces for replay protection                    │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

### Contract Deployment

| Chain    | Contract              | System Address                           |
| -------- | --------------------- | ---------------------------------------- |
| Ethereum | GravityPortal         | Regular deployment                       |
| Ethereum | GTokenBridge          | Regular deployment                       |
| Gravity  | NativeOracle          | `0x0000000000000000000000000001625F2023` |
| Gravity  | BlockchainEventRouter | `0x0000000000000000000000000001625F202B` |
| Gravity  | NativeTokenMinter     | `0x0000000000000000000000000001625F202C` |

---

## Storage Modes

The oracle supports two storage modes to balance efficiency and accessibility:

### 1. Hash Storage Mode (Storage-Efficient)

Stores only the hash of verified data. Users provide the original data (pre-image) as transaction calldata for
verification.

**Use cases:**

- Cross-chain event verification (deposits, withdrawals)
- Large data where calldata is cheaper than storage
- Cost-sensitive applications

**Verification flow:**

```
User transaction calldata: original_data
Contract execution: keccak256(original_data) == stored_hash
```

**Verification helper functions:**

The oracle provides helper functions for verifying data:

- `verifyHash(bytes32 dataHash)` - Check if a hash exists and get its record
- `verifyPreImage(bytes calldata preImage)` - Verify original data matches a stored hash
- `getData(bytes32 dataHash)` - Get stored data directly (for data mode records)

### 2. Data Storage Mode (Direct Access)

Stores the full data on-chain for direct contract access.

**Use cases:**

- JWK keys (for signature verification)
- DNS records (for zkEmail and similar use cases)
- Any data contracts need to read directly on-chain

---

## Data Structures

### Source Type

Source types are represented as `uint32` values for extensibility. New source types can be added by governance without requiring contract upgrades.

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

| Value | Name       | Description                           |
| ----- | ---------- | ------------------------------------- |
| 0     | BLOCKCHAIN | Cross-chain events (Ethereum, BSC)    |
| 1     | JWK        | JSON Web Keys (Google, Apple OAuth)   |
| 2     | DNS        | DNS records (TXT, DKIM keys)          |
| 3     | PRICE_FEED | Price data (stocks, crypto, forex)    |
| 4+    | (Reserved) | New types added via governance        |

### Source ID

The `sourceId` is a flexible `uint256` that uniquely identifies a specific source within a source type. Its interpretation depends on the source type:

```solidity
/// @notice Source identifier (uint256)
/// @dev Interpretation depends on sourceType:
///      - BLOCKCHAIN: Chain ID (1 = Ethereum, 56 = BSC, etc.)
///      - JWK: Provider ID (1 = Google, 2 = Apple, etc.)
///      - DNS: Record type ID
///      - PRICE_FEED: Asset pair ID
uint256 sourceId;
```

| Source Type | Source ID | Example                        |
| ----------- | --------- | ------------------------------ |
| BLOCKCHAIN  | `1`       | Ethereum mainnet (chain ID)    |
| BLOCKCHAIN  | `56`      | BNB Smart Chain (chain ID)     |
| BLOCKCHAIN  | `42161`   | Arbitrum One (chain ID)        |
| JWK         | `1`       | Google OAuth                   |
| JWK         | `2`       | Apple Sign-In                  |
| DNS         | `1`       | TXT records                    |
| PRICE_FEED  | `1`       | ETH/USD                        |
| PRICE_FEED  | `2`       | BTC/USD                        |

### Source Name (Internal)

Internally, the oracle computes a `sourceName` from source type and source ID for efficient storage:

```solidity
/// @notice Compute internal source name from source type and source ID
/// @param sourceType The source type (uint32)
/// @param sourceId The source identifier (uint256)
/// @return sourceName = keccak256(abi.encode(sourceType, sourceId))
function computeSourceName(uint32 sourceType, uint256 sourceId) pure returns (bytes32);
```

### Sync ID

The `syncId` is a `uint128` value that tracks the sync status for each (sourceType, sourceId) pair.

**Requirements:**
- **Must start from 1**: The first syncId for any source must be >= 1 (cannot be 0)
- **Strictly increasing**: Each subsequent syncId must be greater than the previous

```solidity
/// @notice Sync ID (uint128)
/// @dev Must start from 1 and strictly increase for each source
///      Interpretation depends on source type:
///      - BLOCKCHAIN: Block number
///      - JWK: Unix timestamp
///      - DNS: Unix timestamp
///      - PRICE_FEED: Sequence number or timestamp
uint128 syncId;
```

| Source Type | syncId Meaning  | Example                     |
| ----------- | --------------- | --------------------------- |
| Blockchain  | Block number    | `19000000` (Ethereum block) |
| JWK         | Unix timestamp  | `1704067200`                |
| DNS         | Unix timestamp  | `1704067200`                |
| Custom      | Sequence number | `1`, `2`, `3`, ...          |

**Invariants:**
- `syncId >= 1` for the first record
- `syncId` must be strictly increasing for each (sourceType, sourceId) pair

### DataRecord

```solidity
struct DataRecord {
    uint128 syncId;    // Sync ID when recorded (0 = not exists)
    bytes data;        // Empty for hash-only, populated for data mode
}
```

Record existence is determined by `syncId > 0`.

### SyncStatus

```solidity
struct SyncStatus {
    bool initialized;      // Whether this source has been initialized
    uint128 latestSyncId;  // Latest sync ID (block height, timestamp, etc.)
}
```

---

## Contract: GravityPortal (Ethereum)

Entry point on Ethereum for sending messages to Gravity. Charges fees in ETH.

### Constants

```solidity
/// @notice Minimum base fee (can be set to 0)
uint256 public constant MIN_BASE_FEE = 0;
```

### State Variables

```solidity
/// @notice Base fee for any bridge operation (in wei)
uint256 public baseFee;

/// @notice Fee per byte of payload (in wei)
uint256 public feePerByte;

/// @notice Address receiving collected fees
address public feeRecipient;

/// @notice Monotonically increasing nonce
uint256 public nonce;

/// @notice Contract owner (can update fees)
address public owner;
```

### Interface

```solidity
interface IGravityPortal {
    // ========== Message Bridging ==========

    /// @notice Send message to Gravity (hash-only mode)
    /// @param message The message body
    /// @return messageNonce The nonce assigned to this message
    /// @dev Payload = abi.encode(msg.sender, nonce, message)
    function sendMessage(bytes calldata message) external payable returns (uint256 messageNonce);

    /// @notice Send message to Gravity (data mode, stored on-chain)
    /// @param message The message body
    /// @return messageNonce The nonce assigned to this message
    function sendMessageWithData(bytes calldata message) external payable returns (uint256 messageNonce);

    // ========== Fee Management (Owner Only) ==========

    /// @notice Set base fee
    function setBaseFee(uint256 newBaseFee) external;

    /// @notice Set fee per byte
    function setFeePerByte(uint256 newFeePerByte) external;

    /// @notice Set fee recipient
    function setFeeRecipient(address newRecipient) external;

    /// @notice Withdraw collected fees to fee recipient
    function withdrawFees() external;

    // ========== View Functions ==========

    /// @notice Calculate required fee for a message
    /// @param messageLength Length of the message in bytes
    /// @return requiredFee The fee in wei
    function calculateFee(uint256 messageLength) external view returns (uint256 requiredFee);
}
```

### Fee Calculation

```solidity
fee = baseFee + (encodedPayload.length * feePerByte)

// Where encodedPayload = abi.encode(msg.sender, nonce, message)
// Approximate: 32 (sender) + 32 (nonce) + message.length + ABI overhead
```

### Events

```solidity
/// @notice Emitted when a message is sent (hash-only mode)
event MessageSent(
    bytes32 indexed payloadHash,
    address indexed sender,
    uint256 indexed nonce,
    bytes payload
);

/// @notice Emitted when a message is sent (data mode)
event MessageSentWithData(
    bytes32 indexed payloadHash,
    address indexed sender,
    uint256 indexed nonce,
    bytes payload
);

/// @notice Emitted when fee configuration is updated
event FeeConfigUpdated(uint256 baseFee, uint256 feePerByte);

/// @notice Emitted when fee recipient is updated
event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

/// @notice Emitted when fees are withdrawn
event FeesWithdrawn(address indexed recipient, uint256 amount);
```

### Errors

```solidity
/// @notice Insufficient fee provided
error InsufficientFee(uint256 required, uint256 provided);

/// @notice Zero address not allowed
error ZeroAddress();

/// @notice No fees to withdraw
error NoFeesToWithdraw();

/// @notice Only owner can call
error OnlyOwner();
```

---

## Contract: NativeOracle (Gravity)

Stores verified data from external sources. Only writable by SYSTEM_CALLER via consensus.

### Constants

```solidity
/// @notice Gas limit for callback execution
uint256 public constant CALLBACK_GAS_LIMIT = 500_000;
```

### State Variables

```solidity
/// @notice Data records: hash => DataRecord
mapping(bytes32 => DataRecord) private _dataRecords;

/// @notice Sync status per source: sourceName => SyncStatus
/// @dev sourceName = keccak256(abi.encode(sourceType, sourceId))
mapping(bytes32 => SyncStatus) private _syncStatus;

/// @notice Callback handlers: sourceName => callback contract
mapping(bytes32 => address) private _callbacks;

/// @notice Total number of records stored
uint256 private _totalRecords;

/// @notice Whether the contract has been initialized
bool private _initialized;
```

### Interface

```solidity
interface INativeOracle {
    // ========== Recording (SYSTEM_CALLER Only) ==========

    /// @notice Record a hash (hash-only mode)
    /// @param dataHash The hash of the data being recorded
    /// @param sourceType The source type (uint32, e.g., 0 = BLOCKCHAIN, 1 = JWK)
    /// @param sourceId The source identifier (e.g., chain ID for blockchains)
    /// @param syncId The sync ID - must start from 1 and strictly increase
    /// @param payload The event payload (for callback, not stored in hash mode)
    function recordHash(
        bytes32 dataHash,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes calldata payload
    ) external;

    /// @notice Record data (data mode)
    /// @param dataHash The hash of the data (for indexing and verification)
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param syncId The sync ID - must start from 1 and strictly increase
    /// @param payload The event payload (stored on-chain)
    function recordData(
        bytes32 dataHash,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes calldata payload
    ) external;

    /// @notice Batch record hashes
    function recordHashBatch(
        bytes32[] calldata dataHashes,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    /// @notice Batch record data
    function recordDataBatch(
        bytes32[] calldata dataHashes,
        uint32 sourceType,
        uint256 sourceId,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    // ========== Callback Management (GOVERNANCE Only) ==========

    /// @notice Register callback for a source
    function setCallback(uint32 sourceType, uint256 sourceId, address callback) external;

    /// @notice Get callback for a source
    function getCallback(uint32 sourceType, uint256 sourceId) external view returns (address);

    // ========== Verification ==========

    /// @notice Verify hash exists (existence determined by record.syncId > 0)
    function verifyHash(bytes32 dataHash) external view returns (DataRecord memory record);

    /// @notice Verify pre-image (existence determined by record.syncId > 0)
    function verifyPreImage(bytes calldata preImage) external view returns (DataRecord memory record);

    /// @notice Get stored data
    function getData(bytes32 dataHash) external view returns (bytes memory);

    // ========== Sync Status ==========

    /// @notice Get sync status for a source
    function getSyncStatus(uint32 sourceType, uint256 sourceId) external view returns (SyncStatus memory);

    /// @notice Check if synced past a point
    function isSyncedPast(uint32 sourceType, uint256 sourceId, uint128 syncId) external view returns (bool);

    // ========== Helpers ==========

    /// @notice Compute internal sourceName from sourceType and sourceId
    function computeSourceName(uint32 sourceType, uint256 sourceId) external pure returns (bytes32);

    /// @notice Get total records
    function getTotalRecords() external view returns (uint256);
}
```

### Callback Interface

```solidity
interface IOracleCallback {
    /// @notice Called when an oracle event is recorded
    /// @dev Callback failures are caught - do NOT revert oracle recording
    /// @param dataHash The hash of the recorded data
    /// @param payload The event payload
    function onOracleEvent(bytes32 dataHash, bytes calldata payload) external;
}
```

### Callback Execution

```solidity
function _invokeCallback(
    bytes32 sourceName,
    uint32 sourceType,
    uint256 sourceId,
    bytes32 dataHash,
    bytes calldata payload
) internal {
    address callback = _callbacks[sourceName];
    if (callback == address(0)) return;

    try IOracleCallback(callback).onOracleEvent{gas: CALLBACK_GAS_LIMIT}(dataHash, payload) {
        emit CallbackSuccess(sourceType, sourceId, dataHash, callback);
    } catch (bytes memory reason) {
        emit CallbackFailed(sourceType, sourceId, dataHash, callback, reason);
    }
}
```

### Events

```solidity
event HashRecorded(
    bytes32 indexed dataHash,
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 syncId
);

event DataRecorded(
    bytes32 indexed dataHash,
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 syncId,
    uint256 dataLength
);

event SyncStatusUpdated(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    uint128 previousSyncId,
    uint128 newSyncId
);

event CallbackSet(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    address indexed oldCallback,
    address newCallback
);

event CallbackSuccess(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    bytes32 dataHash,
    address callback
);

event CallbackFailed(
    uint32 indexed sourceType,
    uint256 indexed sourceId,
    bytes32 dataHash,
    address callback,
    bytes reason
);
```

### Errors

```solidity
/// @dev For first record, latestSyncId is 0, so syncId must be >= 1
error SyncIdNotIncreasing(uint32 sourceType, uint256 sourceId, uint128 currentSyncId, uint128 providedSyncId);
error ArrayLengthMismatch(uint256 hashesLength, uint256 payloadsLength);
error OracleNotInitialized();
```

---

## Contract: BlockchainEventRouter (Gravity)

Routes blockchain events to handlers based on sender address. Registered as callback for BLOCKCHAIN source type (sourceType = 0).

### Constants

```solidity
/// @notice Gas limit for handler execution
uint256 public constant HANDLER_GAS_LIMIT = 400_000;
```

### State Variables

```solidity
/// @notice Registered handlers: sender address => handler contract
mapping(address => address) private _handlers;

/// @notice Whether initialized
bool private _initialized;
```

### Interface

```solidity
interface IBlockchainEventRouter {
    // ========== Handler Registration (GOVERNANCE Only) ==========

    /// @notice Register handler for a sender
    function registerHandler(address sender, address handler) external;

    /// @notice Unregister handler
    function unregisterHandler(address sender) external;

    /// @notice Get handler for a sender
    function getHandler(address sender) external view returns (address);

    // ========== IOracleCallback Implementation ==========

    /// @notice Called by NativeOracle when blockchain event is recorded
    function onOracleEvent(bytes32 dataHash, bytes calldata payload) external;
}

interface IMessageHandler {
    /// @notice Handle a routed message
    /// @param dataHash The original payload hash
    /// @param sender The sender address on the source chain
    /// @param nonce The message nonce
    /// @param message The message body
    function handleMessage(
        bytes32 dataHash,
        address sender,
        uint256 nonce,
        bytes calldata message
    ) external;
}
```

### Payload Decoding

```solidity
// Blockchain event payloads are encoded as:
// abi.encode(sender, nonce, message)
(address sender, uint256 eventNonce, bytes memory message) = abi.decode(
    payload,
    (address, uint256, bytes)
);
```

### Events

```solidity
event HandlerRegistered(address indexed sender, address indexed handler);
event HandlerUnregistered(address indexed sender);
event MessageRouted(bytes32 indexed dataHash, address indexed sender, address indexed handler);
event RoutingFailed(bytes32 indexed dataHash, address indexed sender, bytes reason);
```

### Errors

```solidity
error OnlyNativeOracle();
error HandlerNotRegistered(address sender);
error RouterNotInitialized();
```

---

## Contract: GTokenBridge (Ethereum)

Locks G tokens on Ethereum and calls GravityPortal to bridge to Gravity.

### State Variables

```solidity
/// @notice The G token contract (ERC20)
IERC20 public immutable G_TOKEN;

/// @notice The GravityPortal contract
IGravityPortal public immutable GRAVITY_PORTAL;
```

### Interface

```solidity
interface IGTokenBridge {
    /// @notice Lock G tokens and bridge to Gravity
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity
    /// @return messageNonce The portal nonce
    function bridgeToGravity(uint256 amount, address recipient) external payable returns (uint256 messageNonce);

    /// @notice Get the G token address
    function gToken() external view returns (address);

    /// @notice Get the portal address
    function gravityPortal() external view returns (address);
}
```

### Message Format

```solidity
// Message sent to GravityPortal:
bytes memory message = abi.encode(amount, recipient);

// Full payload created by GravityPortal:
bytes memory payload = abi.encode(
    address(this),  // GTokenBridge address (sender)
    nonce,          // Portal nonce
    message         // abi.encode(amount, recipient)
);
```

### Events

```solidity
event TokensLocked(address indexed from, address indexed recipient, uint256 amount, uint256 nonce);
```

### Errors

```solidity
error ZeroAmount();
error ZeroRecipient();
error TransferFailed();
```

---

## Contract: NativeTokenMinter (Gravity)

Mints native G tokens when bridge messages are received from GTokenBridge.

### Constants

```solidity
/// @notice Address of the native mint precompile
address public constant NATIVE_MINT_PRECOMPILE = address(0x...); // TBD
```

### State Variables

```solidity
/// @notice Trusted GTokenBridge address on Ethereum
address public immutable TRUSTED_ETH_BRIDGE;

/// @notice Processed nonces for replay protection
mapping(uint256 => bool) private _processedNonces;

/// @notice Whether initialized
bool private _initialized;
```

### Interface

```solidity
interface INativeTokenMinter {
    // ========== IMessageHandler Implementation ==========

    /// @notice Handle bridge message from BlockchainEventRouter
    function handleMessage(
        bytes32 dataHash,
        address sender,
        uint256 nonce,
        bytes calldata message
    ) external;

    // ========== View Functions ==========

    /// @notice Check if a nonce has been processed
    function isProcessed(uint256 nonce) external view returns (bool);

    /// @notice Get trusted bridge address
    function trustedBridge() external view returns (address);
}
```

### Native Mint Precompile Interface

```solidity
/// @notice System precompile for minting native tokens
interface INativeMintPrecompile {
    /// @notice Mint native tokens to recipient
    /// @param recipient Address to receive tokens
    /// @param amount Amount to mint (in wei)
    function mint(address recipient, uint256 amount) external;
}
```

### Message Decoding

```solidity
// Message from GTokenBridge:
(uint256 amount, address recipient) = abi.decode(message, (uint256, address));
```

### Events

```solidity
event NativeMinted(address indexed recipient, uint256 amount, uint256 indexed nonce);
event MintFailed(bytes32 indexed dataHash, uint256 indexed nonce, bytes reason);
```

### Errors

```solidity
error OnlyRouter();
error InvalidSender(address sender, address expected);
error AlreadyProcessed(uint256 nonce);
error MinterNotInitialized();
```

---

## Message Flow: G Token Bridge

```
1. User on Ethereum:
   └─> Approves GTokenBridge for amount
   └─> Calls gTokenBridge.bridgeToGravity(amount, recipient) + ETH fee
       └─> G tokens transferred to GTokenBridge (locked)
       └─> Calls gravityPortal.sendMessage(abi.encode(amount, recipient))
           └─> Fee validated (baseFee + bytes * feePerByte)
           └─> Payload = abi.encode(GTokenBridge, nonce, abi.encode(amount, recipient))
           └─> Emit MessageSent(payloadHash, GTokenBridge, nonce, payload)

2. Gravity Validators:
   └─> Monitor MessageSent events on Ethereum
   └─> Reach consensus on event validity
   └─> SYSTEM_CALLER calls nativeOracle.recordHash(
           payloadHash,
           sourceType=0,     // BLOCKCHAIN
           sourceId=1,       // Ethereum chain ID
           syncId=blockNumber,
           payload
       )

3. NativeOracle on Gravity:
   └─> Validates syncId >= 1 and increasing
   └─> Stores record
   └─> Looks up callback for (sourceType=0, sourceId=1) → BlockchainEventRouter
   └─> Calls router.onOracleEvent{gas: 500,000}(payloadHash, payload)

4. BlockchainEventRouter:
   └─> Verifies caller is NativeOracle
   └─> Decodes payload: (sender=GTokenBridge, nonce, message)
   └─> Looks up handler for sender → NativeTokenMinter
   └─> Calls minter.handleMessage{gas: 400,000}(payloadHash, sender, nonce, message)

5. NativeTokenMinter:
   └─> Verifies caller is BlockchainEventRouter
   └─> Verifies sender == TRUSTED_ETH_BRIDGE (defense in depth)
   └─> Verifies nonce not already processed
   └─> Decodes message: (amount, recipient)
   └─> Marks nonce as processed
   └─> Calls NATIVE_MINT_PRECOMPILE.mint(recipient, amount)
   └─> Emit NativeMinted(recipient, amount, nonce)
```

---

## Access Control Matrix

| Contract                  | Function              | Allowed Callers             |
| ------------------------- | --------------------- | --------------------------- |
| **GravityPortal**         |                       |                             |
|                           | sendMessage()         | Anyone (with fee)           |
|                           | sendMessageWithData() | Anyone (with fee)           |
|                           | setBaseFee()          | Owner                       |
|                           | setFeePerByte()       | Owner                       |
|                           | setFeeRecipient()     | Owner                       |
|                           | withdrawFees()        | Anyone (sends to recipient) |
| **NativeOracle**          |                       |                             |
|                           | initialize()          | GENESIS                     |
|                           | recordHash()          | SYSTEM_CALLER               |
|                           | recordData()          | SYSTEM_CALLER               |
|                           | recordHashBatch()     | SYSTEM_CALLER               |
|                           | recordDataBatch()     | SYSTEM_CALLER               |
|                           | setCallback()         | GOVERNANCE                  |
|                           | View functions        | Anyone                      |
| **BlockchainEventRouter** |                       |                             |
|                           | initialize()          | GENESIS                     |
|                           | registerHandler()     | GOVERNANCE                  |
|                           | unregisterHandler()   | GOVERNANCE                  |
|                           | onOracleEvent()       | NATIVE_ORACLE               |
|                           | View functions        | Anyone                      |
| **GTokenBridge**          |                       |                             |
|                           | bridgeToGravity()     | Anyone (with tokens + fee)  |
| **NativeTokenMinter**     |                       |                             |
|                           | initialize()          | GENESIS                     |
|                           | handleMessage()       | BLOCKCHAIN_EVENT_ROUTER     |
|                           | View functions        | Anyone                      |

---

## Security Considerations

1. **Fee Validation**: GravityPortal requires sufficient ETH before accepting messages
2. **Consensus Required**: All oracle data requires validator consensus via SYSTEM_CALLER
3. **Two-Level Routing**: NativeOracle → Router → Handler provides defense in depth
4. **Sender Verification**: Router verifies sender from payload, Handler re-verifies trusted bridge
5. **Callback Gas Limits**: 500,000 for oracle callbacks, 400,000 for handlers
6. **Callback Failure Tolerance**: Failures do NOT revert oracle recording
7. **Replay Protection**: NativeTokenMinter tracks processed nonces
8. **GOVERNANCE Control**: Callback and handler registration require governance
9. **Sync ID Ordering**: Must start from 1 and strictly increase - prevents replay and ensures data freshness

---

## Invariants

1. **Sync ID Monotonicity**: For each (sourceType, sourceId), `latestSyncId` only increases
2. **Sync ID Minimum**: First syncId for any source must be >= 1
3. **Record Existence**: If `syncId > 0`, record was written by SYSTEM_CALLER
4. **Nonce Uniqueness**: Each nonce from GravityPortal is unique (monotonic)
5. **Total Count**: `_totalRecords` equals count of unique hashes recorded
6. **Callback Safety**: Callback failures never affect oracle state
7. **Handler Isolation**: Handler failures never affect router state
8. **Token Conservation**: G tokens locked on Ethereum = native G minted on Gravity (minus failed mints)

---

## Testing Requirements

### Unit Tests

1. **GravityPortal**

   - Fee calculation correctness
   - sendMessage with sufficient/insufficient fee
   - sendMessageWithData
   - Fee config updates (owner only)
   - Fee withdrawal
   - Nonce incrementing

2. **NativeOracle**

   - Record hash/data with sourceType, sourceId, syncId
   - Batch recording
   - Sync ID validation (must start from 1, must increase)
   - Callback invocation
   - Callback failure handling
   - GOVERNANCE callback registration
   - Source name computation

3. **BlockchainEventRouter**

   - Payload decoding
   - Handler registration (GOVERNANCE)
   - Message routing by sender
   - Handler failure handling
   - Only NativeOracle can call

4. **GTokenBridge**

   - Token locking
   - Portal integration
   - Fee forwarding
   - Message format

5. **NativeTokenMinter**
   - Message decoding
   - Sender verification
   - Nonce replay protection
   - Precompile minting
   - Only router can call

### Integration Tests

1. **End-to-End Bridge Flow**

   - Lock tokens on Ethereum
   - Record in oracle
   - Route through router
   - Mint native tokens

2. **Failure Scenarios**
   - Callback reverts
   - Handler reverts
   - Out of gas
   - Invalid sender

### Fuzz Tests

1. **Random payloads and amounts**
2. **Nonce ordering**
3. **Fee calculations**
4. **SyncId boundaries (must be >= 1)**
5. **SourceType and SourceId combinations**

---

## Future Extensions

1. **Gravity → Ethereum Bridge**: Burn native G, release locked G tokens
2. **Multi-Chain Support**: Additional portals on BSC, Arbitrum, etc.
3. **JWK Registry**: Dedicated module for JWK key management
4. **DNS Verification**: On-chain DNS record verification
5. **Generic Message Passing**: Application-level messaging protocol
