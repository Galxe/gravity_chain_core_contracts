---
status: drafting
owner: @yuejing
---

# Native Oracle Specification

## TODOs

1. callback router can only be registered by governance. 
2. callback router can be more flexible, routing based on event type and source id. if no source id is provided, it will route to the default handler.
3. oracle configurations like jwk lists, dns records etc, should be stored on chain and be configurable by governance.

## Overview

The Native Oracle module stores and verifies data from external sources, enabling Gravity smart contracts to access
validated information from other blockchains and real-world systems. The oracle is powered by the Gravity validator
consensus—information is only accepted after validators reach consensus on its validity.

**Supported data sources include:**

- **Blockchains**: Ethereum, other EVM chains (events, state roots, etc.)
- **Real-world state**: JWK keys (Google, Apple, etc.), DNS records, and other verifiable data

## Storage Modes

The Native Oracle supports two storage modes to balance efficiency and accessibility:

### 1. Hash Storage Mode (Storage-Efficient)

Stores only the hash of verified data. When verifying, users provide the original data (pre-image) as transaction
calldata (much cheaper than storage), and the contract hashes it to recover and verify against the stored hash.

**Use cases:**

- Cross-chain event verification (deposits, withdrawals)
- Large data where calldata is cheaper than storage
- Cost-sensitive applications

**Verification flow:**

```
User transaction calldata: original_data
Contract execution: keccak256(original_data) == stored_hash
```

### 2. Data Storage Mode (Direct Access)

Stores the full data on-chain, allowing smart contracts to access it directly without user input.

**Use cases:**

- JWK keys (for signature verification)
- DNS records (for usecases like zkEmail that relies on reading DNS records on-chain)
- Any data that contracts need to read directly without user providing pre-image

---

## Oracle Event Structure

All oracle events follow a canonical structure:

```solidity
/// @notice Canonical oracle event structure
/// @dev All events bridged through the oracle follow this structure
struct OracleEvent {
    EventType eventType;    // Type of event source
    bytes32 sourceId;       // Identifier within the type (e.g., keccak256("ethereum"), keccak256("google"))
    bytes payload;          // Event-specific data (encoding depends on event type)
}

/// @notice Event source types
enum EventType {
    BLOCKCHAIN,     // Cross-chain events (Ethereum, BSC, etc.)
    JWK,            // JWK key providers (Google, Apple, etc.)
    DNS,            // DNS records
    CUSTOM          // Custom/extensible sources
}

/// @notice Compute the sourceName from event type and source ID
/// @dev sourceName = keccak256(abi.encode(eventType, sourceId))
function computeSourceName(EventType eventType, bytes32 sourceId) pure returns (bytes32) {
    return keccak256(abi.encode(eventType, sourceId));
}
```

### Payload Encoding by Event Type

Each event type has its own payload encoding. **Only blockchain events include sender** (as part of the payload):

| Event Type | Payload Encoding                         | Notes                                        |
| ---------- | ---------------------------------------- | -------------------------------------------- |
| BLOCKCHAIN | `abi.encode(sender, nonce, messageBody)` | Sender is critical for security verification |
| JWK        | `abi.encode(kid, n, e, ...)`             | JWK key components                           |
| DNS        | `abi.encode(domain, recordType, value)`  | DNS record data                              |
| CUSTOM     | Application-defined                      | Flexible encoding                            |

### Source ID Examples

| Event Type | Source ID                           | Description                       |
| ---------- | ----------------------------------- | --------------------------------- |
| BLOCKCHAIN | `keccak256("ethereum")`             | Ethereum mainnet                  |
| BLOCKCHAIN | `keccak256("bsc")`                  | BNB Smart Chain                   |
| BLOCKCHAIN | `keccak256("arbitrum")`             | Arbitrum One                      |
| JWK        | `keccak256("google")`               | Google OAuth                      |
| JWK        | `keccak256("apple")`                | Apple Sign-In                     |
| DNS        | `keccak256("google.com:txt:owner")` | Google.com's TXT record for owner |
| CUSTOM     | `keccak256("price-feed")`           | Custom price feed                 |

---

## Architecture

### Contract Naming Convention

| Chain    | Contract Name   | Purpose                                     |
| -------- | --------------- | ------------------------------------------- |
| Gravity  | `NativeOracle`  | Stores verified data, triggers callbacks    |
| Ethereum | `GravityPortal` | Entry point for sending messages to Gravity |

### System Overview

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              GRAVITY CHAIN                                  │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                    GravityPortal (on Gravity)                        │  │
│   │                    processConsensusData()                            │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                         NativeOracle                                 │  │
│   │                                                                      │  │
│   │  • Stores verified hashes and data                                  │  │
│   │  • Tracks sync status per source                                    │  │
│   │  • Triggers callbacks with LIMITED GAS (prevents DOS)               │  │
│   │  • Written ONLY by consensus engine                                 │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                         │                                                   │
│                         │ Callback (limited gas, try/catch)                │
│                         ▼                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                   BlockchainEventRouter                              │  │
│   │                   (Callback for blockchain events)                   │  │
│   │                                                                      │  │
│   │  • Decodes sender from payload                                      │  │
│   │  • Routes to registered handlers based on sender                    │  │
│   │  • e.g., GTokenBridge, NFTBridge, etc.                              │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                         │                                                   │
│                         │ Route by sender                                  │
│                         ▼                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │              Application Handlers (e.g. GTokenBridge)                │  │
│   │                                                                      │  │
│   │  • Receives routed payload (without sender prefix)                  │  │
│   │  • Handles application-specific logic                               │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
                                     ▲
                                     │ Consensus engine monitors
                                     │ events and bridges data
                                     │
┌────────────────────────────────────────────────────────────────────────────┐
│                        ETHEREUM / OTHER EVM CHAINS                          │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                        GravityPortal                                 │  │
│   │                                                                      │  │
│   │  • Entry point for sending messages to Gravity                      │  │
│   │  • Records sender (msg.sender) in payload                           │  │
│   │  • Emits events for consensus engine to monitor                     │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                     ▲                                       │
│                                     │ Calls sendMessage()                  │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │              Application Contracts (e.g. GTokenBridge)               │  │
│   │                                                                      │  │
│   │  • Locks tokens                                                     │  │
│   │  • Calls GravityPortal.sendMessage() with message body              │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Contract: `NativeOracle` (Gravity Chain)

Stores verified data from external sources. Only writable by the consensus engine via GravityPortal.

### Constants

```solidity
/// @notice Gas limit for callback execution
/// @dev Prevents malicious callbacks from consuming excessive gas
uint256 public constant CALLBACK_GAS_LIMIT = 500_000;
```

### State Variables

```solidity
/// @notice Data records: hash => DataRecord
/// @dev The hash serves as the unique key for each record
mapping(bytes32 => DataRecord) public dataRecords;

/// @notice Sync status per source: sourceName => SyncStatus
/// @dev Tracks the latest verified position for each source
mapping(bytes32 => SyncStatus) public syncStatus;

/// @notice Callback handlers: sourceName => callback contract
/// @dev When an event is recorded, the callback is invoked (if registered)
mapping(bytes32 => address) public callbacks;

/// @notice Total number of records stored
uint256 public totalRecords;
```

### Data Structures

```solidity
/// @notice Record stored in the oracle
struct DataRecord {
    bool exists;            // Whether this record exists
    uint128 syncId;         // Sync ID when this was recorded (for ordering)
    bytes data;             // Empty for hash-only mode, populated for data mode
}

/// @notice Sync status for a source
/// @dev The syncId must be strictly increasing for each source
struct SyncStatus {
    bool initialized;       // Whether this source has been initialized
    uint128 latestSyncId;   // Latest sync ID (block height, timestamp, etc.)
}
```

### Callback Interface

```solidity
/// @notice Interface for oracle callback handlers
/// @dev Implement this to receive oracle events
interface IOracleCallback {
    /// @notice Called when an oracle event is recorded
    /// @param dataHash The hash of the recorded data
    /// @param payload The event payload (encoding depends on event type)
    /// @dev The callback is responsible for decoding the payload
    /// @dev Callback failures are caught - they do NOT revert the oracle recording
    /// @dev Callbacks are invoked with limited gas (CALLBACK_GAS_LIMIT)
    function onOracleEvent(bytes32 dataHash, bytes calldata payload) external;
}
```

### Interface

```solidity
interface INativeOracle {
    // ========== Recording (Consensus Only) ==========

    /// @notice Record a hash (hash-only mode, storage-efficient)
    /// @param dataHash The hash of the data being recorded
    /// @param sourceName The source identifier (hash of eventType + sourceId)
    /// @param syncId The sync ID (block height, timestamp, etc.) - must be > current
    /// @param payload The event payload (for callback, not stored in hash mode)
    function recordHash(
        bytes32 dataHash,
        bytes32 sourceName,
        uint128 syncId,
        bytes calldata payload
    ) external;

    /// @notice Record data (data mode, direct access)
    /// @param dataHash The hash of the data (for indexing and verification)
    /// @param sourceName The source identifier
    /// @param syncId The sync ID - must be > current
    /// @param payload The event payload (stored on-chain)
    function recordData(
        bytes32 dataHash,
        bytes32 sourceName,
        uint128 syncId,
        bytes calldata payload
    ) external;

    /// @notice Batch record multiple hashes from the same source
    /// @param dataHashes Array of hashes to record
    /// @param sourceName The source identifier
    /// @param syncId The sync ID for all records
    /// @param payloads Array of payloads
    function recordHashBatch(
        bytes32[] calldata dataHashes,
        bytes32 sourceName,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    /// @notice Batch record multiple data entries from the same source
    /// @param dataHashes Array of hashes
    /// @param sourceName The source identifier
    /// @param syncId The sync ID for all records
    /// @param payloads Array of payloads to store
    function recordDataBatch(
        bytes32[] calldata dataHashes,
        bytes32 sourceName,
        uint128 syncId,
        bytes[] calldata payloads
    ) external;

    // ========== Callback Management (Admin Only) ==========

    /// @notice Register a callback handler for a source
    /// @param sourceName The source identifier
    /// @param callback The callback contract address (address(0) to unregister)
    function setCallback(bytes32 sourceName, address callback) external;

    /// @notice Get the callback handler for a source
    /// @param sourceName The source identifier
    /// @return callback The callback contract address
    function getCallback(bytes32 sourceName) external view returns (address callback);

    // ========== Verification ==========

    /// @notice Verify a hash exists and get its record
    /// @param dataHash The hash to verify
    /// @return exists True if the hash is recorded
    /// @return record The data record (data field empty if hash-only mode)
    function verifyHash(bytes32 dataHash) external view returns (
        bool exists,
        DataRecord memory record
    );

    /// @notice Verify pre-image matches a recorded hash
    /// @param preImage The original data (provided as calldata)
    /// @return exists True if hash(preImage) is recorded
    /// @return record The data record
    function verifyPreImage(bytes calldata preImage) external view returns (
        bool exists,
        DataRecord memory record
    );

    /// @notice Get stored data directly (for data mode records)
    /// @param dataHash The hash key
    /// @return data The stored data (empty if hash-only or not found)
    function getData(bytes32 dataHash) external view returns (bytes memory data);

    // ========== Sync Status ==========

    /// @notice Get sync status for a source
    /// @param sourceName The source identifier
    /// @return status The current sync status
    function getSyncStatus(bytes32 sourceName) external view returns (SyncStatus memory status);

    /// @notice Check if a source has synced past a certain point
    /// @param sourceName The source identifier
    /// @param syncId The sync ID to check
    /// @return True if latestSyncId >= syncId
    function isSyncedPast(bytes32 sourceName, uint128 syncId) external view returns (bool);

    // ========== Statistics ==========

    /// @notice Get total number of records
    function getTotalRecords() external view returns (uint256);
}
```

### Callback Execution (Failure-Tolerant with Gas Limit)

```solidity
/// @dev Internal function to invoke callback with limited gas
/// @dev Failures are caught to prevent DOS attacks
function _invokeCallback(bytes32 sourceName, bytes32 dataHash, bytes calldata payload) internal {
    address callback = callbacks[sourceName];
    if (callback == address(0)) return;

    // Try to call the callback with limited gas
    // This prevents malicious callbacks from:
    // 1. Consuming excessive gas
    // 2. Blocking oracle updates by reverting
    try IOracleCallback(callback).onOracleEvent{gas: CALLBACK_GAS_LIMIT}(dataHash, payload) {
        emit CallbackSuccess(sourceName, dataHash, callback);
    } catch (bytes memory reason) {
        emit CallbackFailed(sourceName, dataHash, callback, reason);
    }
}
```

### Events

```solidity
/// @notice Emitted when a hash is recorded (hash-only mode)
event HashRecorded(
    bytes32 indexed dataHash,
    bytes32 indexed sourceName,
    uint128 syncId
);

/// @notice Emitted when data is recorded (data mode)
event DataRecorded(
    bytes32 indexed dataHash,
    bytes32 indexed sourceName,
    uint128 syncId,
    uint256 dataLength
);

/// @notice Emitted when sync status is updated
event SyncStatusUpdated(
    bytes32 indexed sourceName,
    uint128 previousSyncId,
    uint128 newSyncId
);

/// @notice Emitted when a callback is registered or updated
event CallbackSet(
    bytes32 indexed sourceName,
    address indexed oldCallback,
    address indexed newCallback
);

/// @notice Emitted when a callback succeeds
event CallbackSuccess(
    bytes32 indexed sourceName,
    bytes32 indexed dataHash,
    address indexed callback
);

/// @notice Emitted when a callback fails (tx continues)
event CallbackFailed(
    bytes32 indexed sourceName,
    bytes32 indexed dataHash,
    address indexed callback,
    bytes reason
);
```

### Errors

```solidity
/// @notice Thrown when trying to record with a non-increasing sync ID
error SyncIdNotIncreasing(bytes32 sourceName, uint128 currentSyncId, uint128 providedSyncId);

/// @notice Thrown when a non-system caller tries to write
error OnlySystemCaller();

/// @notice Thrown when batch arrays have mismatched lengths
error ArrayLengthMismatch();

/// @notice Thrown when a non-admin tries to set callback
error OnlyAdmin();
```

---

## Contract: `GravityPortal` (Ethereum / Other EVM Chains)

The `GravityPortal` is the entry point on source chains for sending messages to Gravity. Application contracts (like
token bridges) call this contract to emit events that the consensus engine monitors.

### Interface

```solidity
interface IGravityPortal {
    /// @notice Send a message to Gravity (hash only, storage-efficient)
    /// @param message The message body
    /// @dev Emits event with sender (msg.sender) + nonce + message
    /// @dev The payload hash is what gets recorded on Gravity
    function sendMessage(bytes calldata message) external;

    /// @notice Send a message to Gravity with full data storage
    /// @param message The message body
    /// @dev Full payload (sender + nonce + message) is stored on Gravity
    function sendMessageWithData(bytes calldata message) external;

    /// @notice Get the current nonce
    function nonce() external view returns (uint256);
}
```

### Implementation

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GravityPortal
/// @notice Entry point on Ethereum for sending messages to Gravity chain
contract GravityPortal {
    /// @notice Nonce for unique message identification
    uint256 public nonce;

    /// @notice Emitted when a message is sent (hash only mode)
    /// @dev Consensus engine monitors this event
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

    /// @notice Send a message to Gravity (hash only mode)
    /// @param message The message body
    function sendMessage(bytes calldata message) external {
        uint256 currentNonce = nonce++;

        // Encode payload: sender + nonce + message
        // sender is msg.sender - the contract that called this function
        bytes memory payload = abi.encode(msg.sender, currentNonce, message);
        bytes32 payloadHash = keccak256(payload);

        emit MessageSent(payloadHash, msg.sender, currentNonce, payload);
    }

    /// @notice Send a message to Gravity (data mode)
    /// @param message The message body
    function sendMessageWithData(bytes calldata message) external {
        uint256 currentNonce = nonce++;

        bytes memory payload = abi.encode(msg.sender, currentNonce, message);
        bytes32 payloadHash = keccak256(payload);

        emit MessageSentWithData(payloadHash, msg.sender, currentNonce, payload);
    }
}
```

---

## Contract: `BlockchainEventRouter` (Gravity Chain)

The `BlockchainEventRouter` is the callback handler for blockchain events. It decodes the sender from the payload and
routes to the appropriate application handler.

### Interface

```solidity
interface IBlockchainEventRouter {
    /// @notice Register a handler for a specific sender address
    /// @param sender The sender address on the source chain
    /// @param handler The handler contract on Gravity
    function registerHandler(address sender, address handler) external;

    /// @notice Unregister a handler
    /// @param sender The sender address
    function unregisterHandler(address sender) external;

    /// @notice Get the handler for a sender
    /// @param sender The sender address
    /// @return handler The handler contract address
    function getHandler(address sender) external view returns (address handler);
}

/// @notice Interface for application handlers that receive routed messages
interface IMessageHandler {
    /// @notice Handle a routed message
    /// @param dataHash The original payload hash
    /// @param sender The sender address on the source chain
    /// @param nonce The message nonce
    /// @param message The message body (without sender/nonce prefix)
    function handleMessage(
        bytes32 dataHash,
        address sender,
        uint256 nonce,
        bytes calldata message
    ) external;
}
```

### Implementation

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracleCallback} from "./interfaces/IOracleCallback.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";

/// @title BlockchainEventRouter
/// @notice Routes blockchain events to registered handlers based on sender
contract BlockchainEventRouter is IOracleCallback {
    /// @notice The Native Oracle contract
    address public immutable ORACLE;

    /// @notice Admin address
    address public admin;

    /// @notice Registered handlers: sender address => handler contract
    mapping(address => address) public handlers;

    /// @notice Gas limit for handler execution
    uint256 public constant HANDLER_GAS_LIMIT = 400_000;

    event HandlerRegistered(address indexed sender, address indexed handler);
    event HandlerUnregistered(address indexed sender);
    event MessageRouted(
        bytes32 indexed dataHash,
        address indexed sender,
        address indexed handler
    );
    event RoutingFailed(
        bytes32 indexed dataHash,
        address indexed sender,
        string reason
    );

    error OnlyOracle();
    error OnlyAdmin();
    error NoHandlerRegistered(address sender);

    constructor(address oracle, address _admin) {
        ORACLE = oracle;
        admin = _admin;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Register a handler for a sender address
    function registerHandler(address sender, address handler) external onlyAdmin {
        handlers[sender] = handler;
        emit HandlerRegistered(sender, handler);
    }

    /// @notice Unregister a handler
    function unregisterHandler(address sender) external onlyAdmin {
        delete handlers[sender];
        emit HandlerUnregistered(sender);
    }

    /// @notice Get handler for a sender
    function getHandler(address sender) external view returns (address) {
        return handlers[sender];
    }

    /// @notice Callback from NativeOracle
    /// @dev Decodes sender from payload and routes to appropriate handler
    function onOracleEvent(bytes32 dataHash, bytes calldata payload) external override {
        if (msg.sender != ORACLE) revert OnlyOracle();

        // Decode blockchain event payload: (sender, nonce, message)
        (address sender, uint256 eventNonce, bytes memory message) = abi.decode(
            payload,
            (address, uint256, bytes)
        );

        // Look up handler for this sender
        address handler = handlers[sender];
        if (handler == address(0)) {
            emit RoutingFailed(dataHash, sender, "No handler registered");
            return; // Don't revert - allow oracle to continue
        }

        // Route to handler with limited gas
        try IMessageHandler(handler).handleMessage{gas: HANDLER_GAS_LIMIT}(
            dataHash,
            sender,
            eventNonce,
            message
        ) {
            emit MessageRouted(dataHash, sender, handler);
        } catch (bytes memory reason) {
            emit RoutingFailed(dataHash, sender, string(reason));
        }
    }
}
```

---

## Example: G Token Bridge (Ethereum ↔ Gravity)

This example demonstrates how to build a G token bridge using the Native Oracle system.

### Ethereum Side: `GTokenBridge`

Locks G tokens on Ethereum and calls `GravityPortal` to send the message to Gravity.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGravityPortal} from "./interfaces/IGravityPortal.sol";

/// @title GTokenBridge (Ethereum)
/// @notice Locks G tokens on Ethereum for bridging to Gravity
contract GTokenBridge {
    /// @notice The G token contract
    IERC20 public immutable G_TOKEN;

    /// @notice The GravityPortal contract
    IGravityPortal public immutable GRAVITY_PORTAL;

    /// @notice Emitted when tokens are locked for bridging
    event TokensLocked(
        address indexed from,
        address indexed recipient,
        uint256 amount
    );

    constructor(address gToken, address gravityPortal) {
        G_TOKEN = IERC20(gToken);
        GRAVITY_PORTAL = IGravityPortal(gravityPortal);
    }

    /// @notice Lock G tokens and request bridge to Gravity
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity chain
    function bridgeToGravity(uint256 amount, address recipient) external {
        // Transfer tokens to this contract (lock)
        G_TOKEN.transferFrom(msg.sender, address(this), amount);

        // Encode the bridge message (amount + recipient)
        // Note: sender and nonce are added by GravityPortal
        bytes memory message = abi.encode(amount, recipient);

        // Send message through GravityPortal
        // The portal will encode: (this contract's address, nonce, message)
        GRAVITY_PORTAL.sendMessage(message);

        emit TokensLocked(msg.sender, recipient, amount);
    }

    /// @notice Unlock tokens when bridging from Gravity
    /// @dev Called by admin after verifying Gravity → Ethereum bridge
    function unlockTokens(address recipient, uint256 amount) external {
        // TODO: Verify bridge from Gravity via oracle
        G_TOKEN.transfer(recipient, amount);
    }
}
```

### Gravity Side: `GTokenBridgeHandler`

Receives routed messages from `BlockchainEventRouter` and mints G tokens.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMessageHandler} from "./interfaces/IMessageHandler.sol";

/// @title GTokenBridgeHandler (Gravity)
/// @notice Receives bridge messages and mints G tokens on Gravity
contract GTokenBridgeHandler is IMessageHandler {
    /// @notice The BlockchainEventRouter contract
    address public immutable ROUTER;

    /// @notice The trusted GTokenBridge contract on Ethereum
    address public immutable TRUSTED_ETH_BRIDGE;

    /// @notice The G token contract on Gravity (mintable)
    IGToken public immutable G_TOKEN;

    /// @notice Processed nonces to prevent replay
    mapping(uint256 => bool) public processedNonces;

    /// @notice Emitted when tokens are minted from bridge
    event BridgeMinted(
        address indexed recipient,
        uint256 amount,
        uint256 nonce
    );

    /// @notice Emitted when bridge processing fails
    event BridgeFailed(
        bytes32 indexed dataHash,
        string reason
    );

    error OnlyRouter();
    error AlreadyProcessed(uint256 nonce);
    error InvalidSender(address sender);

    constructor(address router, address trustedEthBridge, address gToken) {
        ROUTER = router;
        TRUSTED_ETH_BRIDGE = trustedEthBridge;
        G_TOKEN = IGToken(gToken);
    }

    /// @notice Handle routed message from BlockchainEventRouter
    /// @param dataHash The original payload hash
    /// @param sender The sender address on Ethereum (should be GTokenBridge)
    /// @param nonce The message nonce
    /// @param message The message body (amount, recipient)
    function handleMessage(
        bytes32 dataHash,
        address sender,
        uint256 nonce,
        bytes calldata message
    ) external override {
        // Only router can call this
        if (msg.sender != ROUTER) revert OnlyRouter();

        // Verify sender is the trusted bridge contract on Ethereum
        // This check is defense-in-depth (router already verified sender)
        if (sender != TRUSTED_ETH_BRIDGE) {
            emit BridgeFailed(dataHash, "Invalid sender");
            return;
        }

        // Check nonce hasn't been processed
        if (processedNonces[nonce]) {
            emit BridgeFailed(dataHash, "Already processed");
            return;
        }

        // Decode the message: (amount, recipient)
        (uint256 amount, address recipient) = abi.decode(message, (uint256, address));

        // Mark nonce as processed
        processedNonces[nonce] = true;

        // Mint tokens to recipient
        G_TOKEN.mint(recipient, amount);

        emit BridgeMinted(recipient, amount, nonce);
    }
}

/// @notice G Token interface with mint capability
interface IGToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
```

### Registration and Setup

```solidity
// 1. Deploy contracts
GravityPortal gravityPortal = new GravityPortal(); // On Ethereum
GTokenBridge gTokenBridge = new GTokenBridge(gToken, address(gravityPortal)); // On Ethereum

BlockchainEventRouter router = new BlockchainEventRouter(nativeOracle, admin); // On Gravity
GTokenBridgeHandler handler = new GTokenBridgeHandler(
    address(router),
    address(gTokenBridge), // Trusted Ethereum bridge address
    gToken
); // On Gravity

// 2. Register router as callback for Ethereum events
bytes32 sourceName = keccak256(abi.encode(EventType.BLOCKCHAIN, keccak256("ethereum")));
nativeOracle.setCallback(sourceName, address(router));

// 3. Register handler in router for the Ethereum bridge contract
router.registerHandler(address(gTokenBridge), address(handler));
```

### Bridge Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           G TOKEN BRIDGE FLOW                                │
└─────────────────────────────────────────────────────────────────────────────┘

1. User on Ethereum:
   └─> Calls gTokenBridge.bridgeToGravity(amount, recipient)
       └─> G tokens locked in GTokenBridge contract
       └─> Calls gravityPortal.sendMessage(abi.encode(amount, recipient))
           └─> Portal emits MessageSent with payload:
               abi.encode(gTokenBridge, nonce, abi.encode(amount, recipient))

2. Consensus Engine:
   └─> Monitors MessageSent events on Ethereum
   └─> Reaches consensus on event validity
   └─> Calls nativeOracle.recordHash(payloadHash, sourceName, blockNumber, payload)

3. NativeOracle on Gravity:
   └─> Records the hash
   └─> Looks up callback for sourceName (ethereum)
   └─> Calls router.onOracleEvent{gas: CALLBACK_GAS_LIMIT}(payloadHash, payload)
       └─> If callback fails or runs out of gas, logs error but DOES NOT REVERT

4. BlockchainEventRouter:
   └─> Decodes payload: (sender=gTokenBridge, nonce, message)
   └─> Looks up handler for sender (gTokenBridge → GTokenBridgeHandler)
   └─> Calls handler.handleMessage{gas: HANDLER_GAS_LIMIT}(...)

5. GTokenBridgeHandler:
   └─> Verifies sender == TRUSTED_ETH_BRIDGE (defense in depth)
   └─> Decodes message: (amount, recipient)
   └─> Verifies nonce not already processed
   └─> Mints G tokens to recipient
```

### Blockchain Event Payload Encoding

```solidity
/// @notice Payload structure for blockchain events
/// @dev Created by GravityPortal.sendMessage()

// Full payload (what gets hashed and stored):
bytes memory payload = abi.encode(
    sender,         // msg.sender of GravityPortal.sendMessage() (e.g., GTokenBridge)
    nonce,          // Unique nonce from GravityPortal
    message         // Application-specific message body
);

// For G Token Bridge, the message is:
bytes memory message = abi.encode(
    amount,         // uint256: Amount of tokens to bridge
    recipient       // address: Recipient on Gravity
);
```

---

## Source Name Convention

Sources are identified by a `bytes32` hash computed from event type and source ID:

```solidity
sourceName = keccak256(abi.encode(eventType, sourceId))
```

| Event Type | Source ID               | sourceName                                                           |
| ---------- | ----------------------- | -------------------------------------------------------------------- |
| BLOCKCHAIN | `keccak256("ethereum")` | `keccak256(abi.encode(EventType.BLOCKCHAIN, keccak256("ethereum")))` |
| BLOCKCHAIN | `keccak256("bsc")`      | `keccak256(abi.encode(EventType.BLOCKCHAIN, keccak256("bsc")))`      |
| JWK        | `keccak256("google")`   | `keccak256(abi.encode(EventType.JWK, keccak256("google")))`          |
| JWK        | `keccak256("apple")`    | `keccak256(abi.encode(EventType.JWK, keccak256("apple")))`           |
| DNS        | `keccak256("txt")`      | `keccak256(abi.encode(EventType.DNS, keccak256("txt")))`             |

### Sync ID Semantics

The `syncId` (uint128) meaning depends on source type:

| Source Type | syncId Meaning  | Example                            |
| ----------- | --------------- | ---------------------------------- |
| Blockchain  | Block number    | `19000000` (Ethereum block)        |
| JWK         | Unix timestamp  | `1704067200` (2024-01-01 00:00:00) |
| DNS         | Unix timestamp  | `1704067200`                       |
| Custom      | Sequence number | `1`, `2`, `3`, ...                 |

**Invariant**: `syncId` must be strictly increasing for each source.

---

## Use Cases

### 1. JWK Verification (Data Mode, No Callback)

JWK data is stored directly for smart contracts to access:

```solidity
function verifyGoogleSignature(
    bytes32 jwkHash,
    bytes calldata signature,
    bytes calldata message
) external view returns (bool) {
    // Get JWK data directly from oracle
    bytes memory jwkData = nativeOracle.getData(jwkHash);
    require(jwkData.length > 0, "JWK not found");

    // Decode JWK payload (no sender for JWK events)
    JWK memory jwk = abi.decode(jwkData, (JWK));
    return _verifySignature(jwk, signature, message);
}
```

### 2. DNS Record Verification (Data Mode, No Callback)

```solidity
function verifyDomainOwnership(
    string calldata domain,
    address expectedOwner
) external view returns (bool) {
    bytes32 dnsHash = keccak256(abi.encode("TXT", domain));

    bytes memory dnsData = nativeOracle.getData(dnsHash);
    require(dnsData.length > 0, "DNS record not found");

    // Parse TXT record (no sender for DNS events)
    address owner = _parseTxtRecord(dnsData);
    return owner == expectedOwner;
}
```

### 3. Cross-Chain Bridge with Callback

See the G Token Bridge example above.

---

## Security Considerations

1. **Consensus Required**: All oracle data requires validator consensus before recording
2. **Sender in Payload**: For blockchain events, sender is encoded in payload for security verification
3. **Callback Gas Limit**: Callbacks are invoked with limited gas (`CALLBACK_GAS_LIMIT = 500_000`) to prevent DOS
4. **Callback Failure Tolerance**: Callback failures are caught - they do NOT revert oracle recording
5. **Two-Level Routing**: For blockchain events, router verifies sender then routes to handler
6. **Sync ID Ordering**: Prevents replay attacks and ensures data freshness
7. **Source Isolation**: Each source has independent sync tracking and callback
8. **No Overwrites**: Once recorded, data cannot be modified
9. **Pre-image Security**: Hash mode requires users to know exact encoding

---

## Access Control

| Contract              | Function            | Caller                                       |
| --------------------- | ------------------- | -------------------------------------------- |
| NativeOracle          | `recordHash()`      | System Caller (via GravityPortal on Gravity) |
| NativeOracle          | `recordData()`      | System Caller (via GravityPortal on Gravity) |
| NativeOracle          | `recordHashBatch()` | System Caller (via GravityPortal on Gravity) |
| NativeOracle          | `recordDataBatch()` | System Caller (via GravityPortal on Gravity) |
| NativeOracle          | `setCallback()`     | Admin                                        |
| NativeOracle          | Query functions     | Anyone                                       |
| BlockchainEventRouter | `registerHandler()` | Admin                                        |
| BlockchainEventRouter | `onOracleEvent()`   | NativeOracle only                            |
| GravityPortal (ETH)   | `sendMessage()`     | Anyone                                       |

---

## Integration: GravityPortal Routing (on Gravity)

```solidity
// In GravityPortal (on Gravity chain)
function processOracleData(
    OracleUpdate[] calldata updates
) external onlySystem {
    for (uint256 i = 0; i < updates.length; i++) {
        OracleUpdate calldata update = updates[i];

        if (update.isDataMode) {
            nativeOracle.recordData(
                update.dataHash,
                update.sourceName,
                update.syncId,
                update.payload
            );
        } else {
            nativeOracle.recordHash(
                update.dataHash,
                update.sourceName,
                update.syncId,
                update.payload
            );
        }
    }
}

struct OracleUpdate {
    bytes32 dataHash;
    bytes32 sourceName;
    uint128 syncId;
    bool isDataMode;
    bytes payload;
}
```

---

## Testing Requirements

### Unit Tests

1. **Hash Recording**

   - Record single hash
   - Verify hash exists
   - Verify pre-image matching (calldata verification)

2. **Data Recording**

   - Record data with payload
   - Retrieve data directly
   - Verify data integrity

3. **Callback System**

   - Register callback for source
   - Verify callback is invoked on record
   - Verify callback failure doesn't revert recording
   - Verify callback gas limit is enforced
   - Verify callback can be updated/removed

4. **Sync Status**

   - Initialize new source
   - Update sync ID (must increase)
   - Reject non-increasing sync ID
   - Multiple sources independent
   - Test uint128 boundaries

5. **Batch Operations**

   - Batch hash recording
   - Batch data recording with callbacks
   - Array length validation

### Integration Tests

1. **G Token Bridge Flow**

   - Lock tokens on Ethereum via GTokenBridge
   - GTokenBridge calls GravityPortal.sendMessage()
   - Record in oracle on Gravity
   - BlockchainEventRouter routes to GTokenBridgeHandler
   - Handler mints tokens on Gravity
   - Verify replay protection (nonce)
   - Verify sender verification at both levels

2. **Callback Failure Handling**

   - Callback that reverts
   - Callback that runs out of gas
   - Handler that reverts
   - Handler that runs out of gas
   - Verify oracle recording succeeds despite failures

3. **Router Registration**

   - Register handler for sender
   - Unregister handler
   - Message to unregistered sender

### Fuzz Tests

1. **Random Data**

   - Random hashes and payloads
   - Random source names
   - Random sync IDs (maintaining ordering)

2. **Edge Cases**

   - Empty payload
   - Maximum payload size
   - Sync ID boundaries (uint128 max)
   - Gas limit edge cases

### Security Tests

1. **Access Control**

   - Only system caller can record
   - Only admin can set callback
   - Only admin can register handlers
   - Anyone can read

2. **Callback Security**

   - Malicious callback cannot block oracle (gas limit)
   - Callback cannot re-enter oracle
   - Callback receives correct data

3. **Router Security**

   - Only oracle can call router
   - Only router can call handlers
   - Sender verification in router
   - Defense-in-depth sender check in handler

4. **Gas Limit Enforcement**

   - Callback exceeding gas limit fails gracefully
   - Handler exceeding gas limit fails gracefully
   - Oracle recording succeeds regardless

5. **Ordering**

   - Reject out-of-order sync IDs
   - Handle concurrent sources

6. **Data Integrity**

   - Hash matches payload
   - No data corruption
