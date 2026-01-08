---
status: draft
owner: @yxia
layer: oracle
---

# EVM Bridge Specification

## Overview

The EVM Bridge module enables **cross-chain message passing** from Ethereum (or other EVM chains) to Gravity. It
consists of contracts deployed on both chains, providing:

1. **Fee-based message portal** on Ethereum (GravityPortal)
2. **Compact message encoding** for gas efficiency (PortalMessage)
3. **Base callback handler** for processing oracle events (BlockchainEventHandler)
4. **Native token bridging** (G token: ERC20 on Ethereum ↔ native on Gravity)

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
│   │  • Compact encoding: sender (20B) + nonce (16B) + message           │  │
│   │  • Emits MessageSent events for consensus monitoring                │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                     ▲                                       │
│                                     │ Calls send()                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                          GBridgeSender                              │  │
│   │                                                                      │  │
│   │  • Locks G tokens (ERC20) in escrow                                 │  │
│   │  • Calls GravityPortal with bridge message                          │  │
│   │  • Supports ERC20Permit for gasless approvals                       │  │
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
│   │                    Calls record()                                    │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                         NativeOracle                                 │  │
│   │                                                                      │  │
│   │  • Stores verified payload                                          │  │
│   │  • Invokes callback with specified gas limit                        │  │
│   │  • Callback failures do NOT revert recording                        │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                         │                                                   │
│                         │ Callback: onOracleEvent()                        │
│                         ▼                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                     GBridgeReceiver                                  │  │
│   │                     (extends BlockchainEventHandler)                 │  │
│   │                                                                      │  │
│   │  • Parses PortalMessage payload                                     │  │
│   │  • Verifies sender is trusted GBridgeSender                         │  │
│   │  • Mints native G tokens via system precompile                      │  │
│   │  • Tracks processed nonces for replay protection                    │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

### Contract Deployment

| Chain    | Contract               | Address                                     |
| -------- | ---------------------- | ------------------------------------------- |
| Ethereum | GravityPortal          | Regular deployment                          |
| Ethereum | GBridgeSender          | Regular deployment                          |
| Gravity  | GBridgeReceiver        | Regular deployment (registered as callback) |
| Gravity  | NATIVE_MINT_PRECOMPILE | `0x0000000000000000000000000001625F2100`    |

---

## Library: PortalMessage

Compact encoding library for portal messages. Uses packed encoding to minimize gas costs.

### Encoding Format

```
┌─────────────────────────────────────────────────────────────────┐
│ sender (20 bytes) │ nonce (16 bytes) │ message (variable)       │
└─────────────────────────────────────────────────────────────────┘
   └─ address          └─ uint128           └─ application data
```

**Total overhead: 36 bytes** (vs 128+ bytes with abi.encode)

### Constants

```solidity
/// @notice Minimum payload length: 20 (sender) + 16 (nonce) = 36 bytes
uint256 internal constant MIN_PAYLOAD_LENGTH = 36;

/// @notice Offset for sender address (starts at position 0, 20 bytes)
uint256 internal constant SENDER_OFFSET = 20;

/// @notice Offset for nonce end (starts at position 20, 16 bytes, ends at 36)
uint256 internal constant NONCE_OFFSET = 36;
```

### Interface

```solidity
library PortalMessage {
    // ========== Encoding ==========

    /// @notice Encodes sender, nonce, and message into a compact byte array
    /// @dev Uses assembly for gas efficiency
    function encode(
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) internal pure returns (bytes memory payload);

    /// @notice Encodes with calldata message input (more gas-efficient)
    function encodeCalldata(
        address sender,
        uint128 messageNonce,
        bytes calldata message
    ) internal pure returns (bytes memory payload);

    // ========== Decoding ==========

    /// @notice Decodes a payload into sender, nonce, and message
    function decode(
        bytes memory payload
    ) internal pure returns (address sender, uint128 messageNonce, bytes memory message);

    /// @notice Decodes only the sender (gas-efficient for partial decoding)
    function decodeSender(bytes memory payload) internal pure returns (address sender);

    /// @notice Decodes only the nonce (gas-efficient for partial decoding)
    function decodeNonce(bytes memory payload) internal pure returns (uint128 messageNonce);

    /// @notice Decodes sender and nonce (gas-efficient for partial decoding)
    function decodeSenderAndNonce(
        bytes memory payload
    ) internal pure returns (address sender, uint128 messageNonce);

    /// @notice Get the message portion without copying
    function getMessageSlice(
        bytes memory payload
    ) internal pure returns (uint256 messageStart, uint256 messageLength);
}
```

### Errors

```solidity
/// @notice Insufficient data length for decoding
error InsufficientDataLength(uint256 length, uint256 required);
```

---

## Contract: GravityPortal (Ethereum)

Entry point on Ethereum for sending messages to Gravity. Charges fees in ETH.

### State Variables

```solidity
/// @notice Base fee for any bridge operation (in wei)
uint256 public baseFee;

/// @notice Fee per byte of payload (in wei)
uint256 public feePerByte;

/// @notice Address receiving collected fees
address public feeRecipient;

/// @notice Monotonically increasing nonce for message ordering
uint128 public nonce;
```

### Interface

```solidity
interface IGravityPortal {
    // ========== Message Bridging ==========

    /// @notice Send a message to Gravity
    /// @dev The payload uses compact encoding: sender (20B) || nonce (16B) || message
    /// @param message The message body to send
    /// @return messageNonce The nonce assigned to this message
    function send(bytes calldata message) external payable returns (uint128 messageNonce);

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

    /// @notice Get current base fee
    function baseFee() external view returns (uint256);

    /// @notice Get current fee per byte
    function feePerByte() external view returns (uint256);

    /// @notice Get current fee recipient
    function feeRecipient() external view returns (address);

    /// @notice Get current nonce
    function nonce() external view returns (uint128);

    /// @notice Calculate required fee for a message
    /// @param messageLength Length of the message in bytes
    /// @return requiredFee The fee in wei
    function calculateFee(uint256 messageLength) external view returns (uint256 requiredFee);
}
```

### Fee Calculation

```solidity
// Fee based on encoded payload length:
// payload = sender (20B) + nonce (16B) + message
// fee = baseFee + (36 + message.length) * feePerByte
```

### Events

```solidity
/// @notice Emitted when a message is sent to Gravity
/// @param nonce The unique nonce for this message
/// @param payload The encoded payload: sender (20B) || nonce (16B) || message
event MessageSent(uint128 indexed nonce, bytes payload);

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
```

---

## Contract: BlockchainEventHandler (Gravity - Abstract)

Abstract base contract for handling blockchain events from NativeOracle. Implements `IOracleCallback` and parses
PortalMessage payloads.

### Interface

```solidity
abstract contract BlockchainEventHandler is IOracleCallback {
    /// @notice Called by NativeOracle when a blockchain event is recorded
    /// @dev Parses the portal message payload and delegates to _handlePortalMessage()
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        bytes calldata payload
    ) external override;

    /// @notice Handle a parsed portal message (override in derived contracts)
    /// @param sourceType The source type from NativeOracle
    /// @param sourceId The source identifier (chain ID)
    /// @param oracleNonce The oracle nonce for this record
    /// @param sender The sender address on the source chain
    /// @param messageNonce The message nonce from the source chain
    /// @param message The message body (application-specific encoding)
    function _handlePortalMessage(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) internal virtual;
}
```

### Payload Decoding

```solidity
// Oracle payload is encoded as PortalMessage:
// sender (20 bytes) || nonce (16 bytes) || message (variable)
(address sender, uint128 messageNonce, bytes memory message) = PortalMessage.decode(payload);
```

### Errors

```solidity
/// @notice Only NativeOracle can call onOracleEvent
error OnlyNativeOracle();
```

---

## Contract: GBridgeSender (Ethereum)

Locks G tokens on Ethereum and calls GravityPortal to bridge to Gravity.

### State Variables

```solidity
/// @notice The G token contract (ERC20)
address public immutable gToken;

/// @notice The GravityPortal contract
address public immutable gravityPortal;
```

### Interface

```solidity
interface IGBridgeSender {
    /// @notice Lock G tokens and bridge to Gravity
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity
    /// @return messageNonce The portal nonce
    function bridgeToGravity(
        uint256 amount,
        address recipient
    ) external payable returns (uint128 messageNonce);

    /// @notice Lock G tokens and bridge using ERC20Permit
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity
    /// @param deadline Permit deadline
    /// @param v Signature recovery byte
    /// @param r Signature r value
    /// @param s Signature s value
    /// @return messageNonce The portal nonce
    function bridgeToGravityWithPermit(
        uint256 amount,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (uint128 messageNonce);

    /// @notice Get the G token address
    function gToken() external view returns (address);

    /// @notice Get the portal address
    function gravityPortal() external view returns (address);

    /// @notice Calculate required bridge fee
    function calculateBridgeFee(
        uint256 amount,
        address recipient
    ) external view returns (uint256 requiredFee);
}
```

### Message Format

```solidity
// Message sent to GravityPortal:
bytes memory message = abi.encode(amount, recipient);

// Full payload created by GravityPortal (compact encoding):
// sender (20B) || nonce (16B) || abi.encode(amount, recipient)
```

### Events

```solidity
/// @notice Emitted when G tokens are locked for bridging
event TokensLocked(
    address indexed from,
    address indexed recipient,
    uint256 amount,
    uint128 indexed nonce
);
```

### Errors

```solidity
/// @notice Zero address not allowed
error ZeroAddress();

/// @notice Cannot bridge zero amount
error ZeroAmount();

/// @notice Cannot bridge to zero address
error ZeroRecipient();
```

---

## Contract: GBridgeReceiver (Gravity)

Mints native G tokens when bridge messages are received from GBridgeSender.

### State Variables

```solidity
/// @notice Trusted GBridgeSender address on Ethereum
address public immutable trustedBridge;

/// @notice Processed nonces for replay protection
mapping(uint128 => bool) private _processedNonces;
```

### Interface

```solidity
interface IGBridgeReceiver {
    /// @notice Check if a nonce has been processed
    function isProcessed(uint128 nonce) external view returns (bool);

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
// Message from GBridgeSender:
(uint256 amount, address recipient) = abi.decode(message, (uint256, address));
```

### Events

```solidity
/// @notice Emitted when native G tokens are minted
event NativeMinted(address indexed recipient, uint256 amount, uint128 indexed nonce);
```

### Errors

```solidity
/// @notice Message sender is not the trusted bridge
error InvalidSender(address sender, address expected);

/// @notice Nonce has already been processed
error AlreadyProcessed(uint128 nonce);
```

---

## Message Flow: G Token Bridge

```
1. User on Ethereum:
   └─> Approves GBridgeSender for amount (or uses permit)
   └─> Calls gBridgeSender.bridgeToGravity(amount, recipient) + ETH fee
       └─> G tokens transferred to GBridgeSender (locked)
       └─> Calls gravityPortal.send(abi.encode(amount, recipient))
           └─> Fee validated (baseFee + bytes * feePerByte)
           └─> Payload = sender (20B) || nonce (16B) || abi.encode(amount, recipient)
           └─> Emit MessageSent(nonce, payload)

2. Gravity Validators:
   └─> Monitor MessageSent events on Ethereum
   └─> Reach consensus on event validity
   └─> SYSTEM_CALLER calls nativeOracle.record(
           sourceType=0,        // BLOCKCHAIN
           sourceId=1,          // Ethereum chain ID
           nonce=messageNonce,  // Portal nonce
           payload,             // Full portal message
           callbackGasLimit     // Caller-specified
       )

3. NativeOracle on Gravity:
   └─> Validates nonce >= 1 and increasing
   └─> Stores record
   └─> Resolves callback using 2-layer lookup → GBridgeReceiver
   └─> Calls receiver.onOracleEvent{gas: callbackGasLimit}(...)

4. GBridgeReceiver (extends BlockchainEventHandler):
   └─> Verifies caller is NativeOracle
   └─> Decodes PortalMessage: (sender=GBridgeSender, messageNonce, message)
   └─> Verifies sender == trustedBridge (defense in depth)
   └─> Verifies nonce not already processed
   └─> Decodes message: (amount, recipient)
   └─> Marks nonce as processed (CEI pattern)
   └─> Calls NATIVE_MINT_PRECOMPILE.mint(recipient, amount)
   └─> Emit NativeMinted(recipient, amount, nonce)
```

---

## Access Control Matrix

| Contract            | Function                    | Allowed Callers             |
| ------------------- | --------------------------- | --------------------------- |
| **GravityPortal**   |                             |                             |
|                     | send()                      | Anyone (with fee)           |
|                     | setBaseFee()                | Owner                       |
|                     | setFeePerByte()             | Owner                       |
|                     | setFeeRecipient()           | Owner                       |
|                     | withdrawFees()              | Anyone (sends to recipient) |
| **GBridgeSender**   |                             |                             |
|                     | bridgeToGravity()           | Anyone (with tokens + fee)  |
|                     | bridgeToGravityWithPermit() | Anyone (with tokens + fee)  |
| **GBridgeReceiver** |                             |                             |
|                     | onOracleEvent()             | NATIVE_ORACLE               |
|                     | View functions              | Anyone                      |

---

## Security Considerations

1. **Fee Validation**: GravityPortal requires sufficient ETH before accepting messages
2. **Consensus Required**: All oracle data requires validator consensus via SYSTEM_CALLER
3. **Sender Verification**: GBridgeReceiver verifies sender from payload is the trusted bridge
4. **Callback Failure Tolerance**: Failures do NOT revert oracle recording
5. **Replay Protection**: GBridgeReceiver tracks processed nonces
6. **CEI Pattern**: Nonce marked as processed BEFORE minting (prevents reentrancy)
7. **Compact Encoding**: PortalMessage uses 36-byte overhead (vs 128+ with abi.encode)

---

## Invariants

1. **Nonce Uniqueness**: Each nonce from GravityPortal is unique (monotonic uint128)
2. **Callback Safety**: Callback failures never affect oracle state
3. **Token Conservation**: G tokens locked on Ethereum = native G minted on Gravity (minus failed mints)
4. **Replay Prevention**: Each message nonce can only be processed once on GBridgeReceiver

---

## Testing Requirements

### Unit Tests

1. **PortalMessage**

   - Encode/decode roundtrip for various message sizes
   - Partial decoding functions (decodeSender, decodeNonce)
   - Error on insufficient data length

2. **GravityPortal**

   - Fee calculation correctness
   - send with sufficient/insufficient fee
   - Fee config updates (owner only)
   - Fee withdrawal
   - Nonce incrementing (uint128)

3. **GBridgeSender**

   - Token locking with approval
   - Token locking with permit
   - Portal integration
   - Fee forwarding
   - Message format

4. **BlockchainEventHandler**

   - Payload decoding
   - Only NativeOracle can call
   - Correct delegation to \_handlePortalMessage

5. **GBridgeReceiver**
   - Message decoding
   - Sender verification
   - Nonce replay protection
   - Precompile minting

### Integration Tests

1. **End-to-End Bridge Flow**

   - Lock tokens on Ethereum
   - Record in oracle
   - Callback invocation
   - Mint native tokens

2. **Failure Scenarios**
   - Callback reverts (should not affect oracle)
   - Invalid sender
   - Duplicate nonce (replay attempt)

### Fuzz Tests

1. **Random payloads and amounts**
2. **Nonce ordering**
3. **Fee calculations with various message lengths**
4. **PortalMessage encoding/decoding with random data**

---

## Future Extensions

1. **Gravity → Ethereum Bridge**: Burn native G, release locked G tokens
2. **Multi-Chain Support**: Additional portals on BSC, Arbitrum, etc.
3. **Generic Message Handlers**: Application-level messaging protocol
4. **Fee Token Diversification**: Accept fees in tokens other than ETH
