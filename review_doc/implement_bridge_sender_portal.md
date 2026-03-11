# implement_bridge_sender_portal

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 79021ms
- **Steps**: 1

## Report

Here is the factual implementation summary:

---

## Implementation Analysis: Ethereum-side Bridge Contracts

### Files/Contracts Involved

| File | Contract | Role |
|------|----------|------|
| `src/oracle/evm/native_token_bridge/GBridgeSender.sol` | `GBridgeSender` | Locks ERC20 G tokens on Ethereum, sends bridge messages via GravityPortal |
| `src/oracle/evm/GravityPortal.sol` | `GravityPortal` | Generic message-passing entry point on Ethereum; charges fees, emits events for consensus engine |
| `src/oracle/evm/PortalMessage.sol` | `PortalMessage` (library) | Compact encoding/decoding: `sender(20B) + nonce(16B) + message(variable)` |
| `src/oracle/evm/IGravityPortal.sol` | `IGravityPortal` | Interface for GravityPortal |
| `src/oracle/evm/native_token_bridge/IGBridgeSender.sol` | `IGBridgeSender` | Interface for GBridgeSender |
| `src/oracle/evm/native_token_bridge/GBridgeReceiver.sol` | `GBridgeReceiver` | Gravity-side receiver; mints native tokens via precompile |
| `src/Genesis.sol` | `Genesis` | System initializer; optionally deploys `GBridgeReceiver` during genesis |

---

### Execution Path: Token Bridge (Ethereum → Gravity)

#### Step 1: User calls `GBridgeSender.bridgeToGravity(amount, recipient)` (or `bridgeToGravityWithPermit`)

1. **Permit variant**: If `bridgeToGravityWithPermit` is called, it first calls `IERC20Permit(gToken).permit(msg.sender, address(this), amount, deadline, v, r, s)` to set the allowance in one transaction.

2. **`_bridgeToGravity(amount, recipient)`** internal function:
   - Reverts if `amount == 0` (`ZeroAmount`) or `recipient == address(0)` (`ZeroRecipient`).
   - Calls `IERC20(gToken).safeTransferFrom(msg.sender, address(this), amount)` — locks tokens in the GBridgeSender contract.
   - Encodes message: `abi.encode(amount, recipient)` → 64 bytes (two ABI-encoded `uint256`/`address` slots).
   - Calls `IGravityPortal(gravityPortal).send{value: msg.value}(message)` — forwards all ETH for fee payment.
   - Emits `TokensLocked(msg.sender, recipient, amount, messageNonce)`.

#### Step 2: `GravityPortal.send(message)` processes the message

1. **Nonce assignment**: `messageNonce = ++nonce` (pre-increment, so first message gets nonce 1).
2. **Payload encoding**: `PortalMessage.encodeCalldata(msg.sender, messageNonce, message)` — produces compact bytes: `GBridgeSender address (20B) || nonce (16B) || message (64B)` = 100 bytes total.
3. **Fee calculation**: `_calculateFee(payload.length)` = `baseFee + (payload.length * feePerByte)`.
4. **Fee validation**: Reverts with `InsufficientFee(required, provided)` if `msg.value < requiredFee`.
5. **Refund**: If `msg.value > requiredFee`, refunds the excess via `msg.sender.call{value: refundAmount}("")`. Reverts with `RefundFailed()` if the call fails.
6. **Event emission**: `MessageSent(messageNonce, block.number, payload)` — `messageNonce` and `block.number` are indexed.

#### Step 3: Gravity consensus engine picks up `MessageSent` event, delivers to `GBridgeReceiver`

1. `GBridgeReceiver` inherits `BlockchainEventHandler`, which parses the oracle payload and calls `_handlePortalMessage`.
2. **Validations**: Checks `sourceId == trustedSourceId`, `sender == trustedBridge`, and `!_processedNonces[messageNonce]`.
3. **Decode**: `abi.decode(message, (uint256, address))` → `(amount, recipient)`. Reverts if either is zero.
4. **Mark processed**: `_processedNonces[messageNonce] = true` (before minting, CEI pattern).
5. **Mint**: Calls `SystemAddresses.NATIVE_MINT_PRECOMPILE.call(abi.encodePacked(0x01, recipient, amount))`.
6. Emits `NativeMinted(recipient, amount, messageNonce)`, returns `true` to store the event in NativeOracle.

---

### Key Functions

#### GBridgeSender

| Function | Access | Description |
|----------|--------|-------------|
| `bridgeToGravity(uint256, address) → uint128` | `external payable` | Locks tokens via `safeTransferFrom`, sends portal message |
| `bridgeToGravityWithPermit(uint256, address, uint256, uint8, bytes32, bytes32) → uint128` | `external payable` | Calls `permit()` then delegates to `_bridgeToGravity` |
| `_bridgeToGravity(uint256, address) → uint128` | `internal` | Core logic: validate → lock → encode → portal.send |
| `initiateEmergencyWithdraw()` | `onlyOwner` | Sets `emergencyUnlockTime = block.timestamp + 7 days`; reverts if `emergencyUsed == true` |
| `emergencyWithdraw(address, uint256)` | `onlyOwner` | Requires `emergencyUnlockTime > 0` and `block.timestamp >= emergencyUnlockTime`; sets `emergencyUsed = true`, `emergencyUnlockTime = 0`; calls `safeTransfer` |
| `calculateBridgeFee(uint256, address) → uint256` | `view` | Encodes message, delegates to `portal.calculateFee(message.length)` |

#### GravityPortal

| Function | Access | Description |
|----------|--------|-------------|
| `send(bytes) → uint128` | `external payable` | Increments nonce, encodes via PortalMessage, validates fee, refunds excess, emits `MessageSent` |
| `setBaseFee(uint256)` | `onlyOwner` | Updates `baseFee` storage |
| `setFeePerByte(uint256)` | `onlyOwner` | Updates `feePerByte` storage |
| `setFeeRecipient(address)` | `onlyOwner` | Updates `feeRecipient`; reverts on `address(0)` |
| `withdrawFees()` | `onlyOwner` | Sends entire contract ETH balance to `feeRecipient` via low-level `call` |
| `calculateFee(uint256) → uint256` | `view` | Returns `baseFee + ((36 + messageLength) * feePerByte)` |
| `_calculateFee(uint256) → uint256` | `internal view` | Returns `baseFee + (payloadLength * feePerByte)` |

#### PortalMessage (Library)

| Function | Description |
|----------|-------------|
| `encode(address, uint128, bytes memory) → bytes` | Assembly-based compact encoding from memory input |
| `encodeCalldata(address, uint128, bytes calldata) → bytes` | Same encoding using `calldatacopy` for calldata input |
| `decode(bytes) → (address, uint128, bytes)` | Full decode; reverts if `payload.length < 36` |
| `decodeSender(bytes) → address` | Partial decode — sender only |
| `decodeNonce(bytes) → uint128` | Partial decode — nonce only |
| `decodeSenderAndNonce(bytes) → (address, uint128)` | Partial decode — sender + nonce |
| `getMessageSlice(bytes) → (uint256, uint256)` | Returns memory pointer and length of message portion without copying |

---

### State Changes

| Contract | Storage Variable | Modification |
|----------|-----------------|--------------|
| `GBridgeSender` | (ERC20 `gToken` balances) | `safeTransferFrom`: decreases sender's balance, increases GBridgeSender's balance |
| `GBridgeSender` | `emergencyUnlockTime` | Set to `block.timestamp + 7 days` on initiate; reset to `0` on execute |
| `GBridgeSender` | `emergencyUsed` | Set to `true` on emergency execution (one-shot, irreversible) |
| `GravityPortal` | `nonce` | Incremented by 1 on each `send()` call (uint128, pre-increment) |
| `GravityPortal` | ETH balance | Accumulates fees (msg.value minus refunds); drained on `withdrawFees()` |
| `GravityPortal` | `baseFee`, `feePerByte`, `feeRecipient` | Modified by owner via setters |
| `GBridgeReceiver` | `_processedNonces[nonce]` | Set to `true` per processed message (replay protection) |

---

### External Dependencies

| Contract | Dependency | Type |
|----------|-----------|------|
| `GBridgeSender` | `@openzeppelin/Ownable2Step` | Inheritance — two-step ownership transfer |
| `GBridgeSender` | `@openzeppelin/SafeERC20` | Library — `safeTransferFrom`, `safeTransfer` for token operations |
| `GBridgeSender` | `@openzeppelin/IERC20Permit` | Interface — `permit()` call for gasless approvals |
| `GBridgeSender` | `IGravityPortal` | External call — `send()` and `calculateFee()` |
| `GravityPortal` | `@openzeppelin/Ownable2Step` | Inheritance |
| `GravityPortal` | `PortalMessage` | Library — `encodeCalldata()` for payload encoding |
| `GBridgeReceiver` | `BlockchainEventHandler` | Inheritance — oracle callback handler |
| `GBridgeReceiver` | `SystemAddresses.NATIVE_MINT_PRECOMPILE` | External call — native token minting precompile at `0x01` opcode |
| `Genesis` | `GBridgeReceiver` | Deploys new instance via `new GBridgeReceiver(trustedBridge, trustedSourceId)` when `bridgeConfig.deploy == true` |

---

### Access Control Summary

| Contract | Mechanism | Protected Functions |
|----------|-----------|-------------------|
| `GBridgeSender` | `Ownable2Step` (OpenZeppelin) | `initiateEmergencyWithdraw`, `emergencyWithdraw` |
| `GravityPortal` | `Ownable2Step` (OpenZeppelin) | `setBaseFee`, `setFeePerByte`, `setFeeRecipient`, `withdrawFees` |
| `GBridgeReceiver` | Called via `BlockchainEventHandler` → `NativeOracle` | `_handlePortalMessage` (internal, invoked by oracle system) |
| `Genesis` | `requireAllowed(SYSTEM_CALLER)` + `_isInitialized` one-shot guard | `initialize` |

---

### PortalMessage Encoding Layout

```
Offset:  0         20        36        36+N
         |---------|---------|---------|
         | sender  | nonce   | message |
         | 20 bytes| 16 bytes| N bytes |
```

- Constant `MIN_PAYLOAD_LENGTH = 36`
- Assembly uses `shl(96, sender)` to left-align address in 32-byte word
- Assembly uses `shl(128, nonce)` to left-align uint128 in 32-byte word
- `encodeCalldata` variant uses `calldatacopy` instead of memory loop for gas efficiency

### Fee Calculation Formula

```
requiredFee = baseFee + (payloadLength × feePerByte)
```

Where `payloadLength = 36 + message.length`. For a bridge operation, `message = abi.encode(amount, recipient)` = 64 bytes, so `payloadLength = 100 bytes`.

The `calculateFee` view uses `MIN_PAYLOAD_LENGTH + messageLength` to estimate, which matches the actual encoding in `send()`.

### Emergency Withdrawal Mechanism (GBridgeSender)

Two-step process with one-shot design:
1. **Initiate**: Owner calls `initiateEmergencyWithdraw()` → sets `emergencyUnlockTime = now + 7 days`. Reverts if `emergencyUsed` is already `true`.
2. **Execute**: Owner calls `emergencyWithdraw(recipient, amount)` after 7 days → transfers specified amount of G tokens via `safeTransfer`, sets `emergencyUsed = true` and resets `emergencyUnlockTime = 0`.

The `emergencyUsed` flag is a one-shot mechanism — once used, `initiateEmergencyWithdraw` cannot be called again, permanently disabling the emergency path.

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | Here is the factual implementation summary:

---

## Impleme | 79020ms |
