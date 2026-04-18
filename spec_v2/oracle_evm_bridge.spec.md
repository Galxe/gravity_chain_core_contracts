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
| Gravity  | NATIVE_MINT_PRECOMPILE | `0x0000000000000000000000000001625F5000`    |

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
/// @param block_number The Ethereum block number this message was emitted at (carried into the oracle DataRecord as provenance)
/// @param payload The encoded payload: sender (20B) || nonce (16B) || message
event MessageSent(uint128 indexed nonce, uint256 indexed block_number, bytes payload);

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

/// @notice Fee overpayment — we reject msg.value > requiredFee so callers do not silently overpay
error ExcessiveFee(uint256 required, uint256 provided);

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
    /// @dev Parses the portal message payload and delegates to _handlePortalMessage().
    ///      Returns `shouldStore` up to NativeOracle so the derived handler can decide whether
    ///      the raw payload is worth persisting.
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        bytes calldata payload
    ) external override returns (bool shouldStore);

    /// @notice Handle a parsed portal message (override in derived contracts)
    /// @return shouldStore Whether NativeOracle should persist the raw payload
    function _handlePortalMessage(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        address sender,
        uint128 messageNonce,
        bytes memory message
    ) internal virtual returns (bool shouldStore);
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

/// @notice Trusted source chain ID (e.g. 1 for Ethereum mainnet).
///         Incoming callbacks with a different sourceId are rejected.
uint256 public immutable trustedSourceId;

// @deprecated — a previous revision tracked processedNonces here. Replay protection is now provided
// by NativeOracle's sequential-nonce enforcement (`nonce == currentNonce + 1`), so local tracking is
// redundant. The storage slot is retained as __deprecated_processedNonces only to preserve layout
// across the hardfork.
uint256 private __deprecated_processedNonces;
```

### Interface

```solidity
interface IGBridgeReceiver {
    /// @notice Get trusted bridge address
    function trustedBridge() external view returns (address);

    /// @notice Get trusted source chain ID
    function trustedSourceId() external view returns (uint256);
}
```

### Validation

`_handlePortalMessage` validates, in order:

1. `sourceId == trustedSourceId` — else revert with `InvalidSourceChain(provided, expected)`.
2. `sender == trustedBridge` — defence-in-depth, even though the Ethereum side is already gated.
3. `amount != 0` — reject no-op mints (`Errors.ZeroAmount`).
4. `recipient != address(0)` — reject burns to the zero address (`Errors.ZeroAddress`).

Replay protection is **not** implemented locally; `NativeOracle` already enforces `nonce == currentNonce + 1` for this (sourceType, sourceId), so a message cannot be delivered twice.

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

/// @notice Source chain ID does not match the receiver's trusted source
error InvalidSourceChain(uint256 provided, uint256 expected);

/// @notice Native mint precompile call failed
error MintFailed(address recipient, uint256 amount);
```

---

## Message Flow: G Token Bridge

```
1. User on Ethereum:
   └─> Approves GBridgeSender for amount (or uses permit)
   └─> Calls gBridgeSender.bridgeToGravity(amount, recipient) + ETH fee
       └─> G tokens transferred to GBridgeSender (locked)
       └─> Calls gravityPortal.send(abi.encode(amount, recipient))
           └─> Fee validated: reverts with InsufficientFee if msg.value < required
               and with ExcessiveFee if msg.value > required
           └─> Payload = sender (20B) || nonce (16B) || abi.encode(amount, recipient)
           └─> Emit MessageSent(nonce, block.number, payload)

2. Gravity Validators:
   └─> Monitor MessageSent events on Ethereum (including block.number for provenance)
   └─> Reach consensus on event validity
   └─> SYSTEM_CALLER calls nativeOracle.record(
           sourceType=0,        // BLOCKCHAIN
           sourceId=1,          // Ethereum chain ID (matches GBridgeReceiver.trustedSourceId)
           nonce=currentNonce+1,// Sequential; NativeOracle enforces expectedNonce == currentNonce+1
           blockNumber,         // From MessageSent.block_number; stored as provenance in DataRecord
           payload,             // Full portal message
           callbackGasLimit     // Caller-specified
       )

3. NativeOracle on Gravity:
   └─> Validates nonce == currentNonce + 1 (reverts NonceNotSequential otherwise — replay-safe)
   └─> Resolves callback using 2-layer lookup → GBridgeReceiver
   └─> Calls receiver.onOracleEvent{gas: callbackGasLimit}(...) — expects bool return
   └─> Stores DataRecord (with blockNumber) iff callback returned true (or no callback / gas=0 / revert)

4. GBridgeReceiver (extends BlockchainEventHandler):
   └─> Verifies sourceId == trustedSourceId
   └─> Verifies sender == trustedBridge (defence in depth)
   └─> Decodes message: (amount, recipient); reverts on amount==0 or recipient==0
   └─> Calls NATIVE_MINT_PRECOMPILE (0x...1625F5000) via low-level call
       with callData = 0x01 || recipient || amount
   └─> Emits NativeMinted(recipient, amount, messageNonce)
   └─> Returns shouldStore = true so the oracle keeps the payload for audit
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

1. **Fee Validation**: GravityPortal rejects both underpayment (`InsufficientFee`) and overpayment (`ExcessiveFee`) so a caller sees a deterministic cost.
2. **Consensus Required**: All oracle data requires validator consensus via SYSTEM_CALLER
3. **Source and Sender Verification**: GBridgeReceiver checks both `sourceId == trustedSourceId` and the in-payload `sender == trustedBridge`.
4. **Callback Failure Tolerance**: Failures do NOT revert oracle recording; NativeOracle falls back to storing the payload for later inspection.
5. **Replay Protection**: Enforced by NativeOracle's sequential-nonce rule (`nonce == currentNonce + 1`). GBridgeReceiver does NOT keep its own processed-nonce map; the legacy slot exists only as `__deprecated_processedNonces` for storage-layout compatibility.
6. **Compact Encoding**: PortalMessage uses 36-byte overhead (vs 128+ with abi.encode)

---

## Invariants

1. **Nonce Uniqueness**: Each nonce from GravityPortal is unique (monotonic uint128)
2. **Callback Safety**: Callback failures never affect oracle state
3. **Token Conservation**: G tokens locked on Ethereum = native G minted on Gravity (minus failed mints)
4. **Replay Prevention**: NativeOracle enforces `nonce == currentNonce + 1` per (sourceType, sourceId), so each portal nonce can be delivered to the receiver at most once.

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
