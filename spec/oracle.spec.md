---
status: unstarted
owner: @yuejing
---

# Oracle Specification

## Overview

The HashOracle module stores and verifies cross-chain hash records, enabling Gravity smart contracts to verify that specific events occurred on other blockchains. The oracle is powered by the Gravity validator consensus, meaning information is only accepted after validators reach consensus on its validity.

## Architecture

The Oracle module is part of the modular Gravity system:

```
┌──────────────────────────────────────────────────────────────────────┐
│                           Gravity Portal                              │
│                      (Consensus Entry Point)                          │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   Consensus Layer                                                     │
│        │                                                              │
│        ▼                                                              │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                   GravityPortal                             │   │
│   │                  processConsensusData()                     │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                       │
│        │                    │                    │                    │
│        ▼                    ▼                    ▼                    │
│   ┌─────────────┐    ┌──────────────┐    ┌─────────────┐            │
│   │ JWKRegistry │    │HashOracle    │    │CrossChain   │            │
│   │             │    │              │    │Gateway      │            │
│   │ (JWK logic) │    │(This spec)   │    │(Bridging)   │            │
│   └─────────────┘    └──────────────┘    └─────────────┘            │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

> **Note**: JWK management has been moved to a separate `JWKRegistry` module. See [jwkregistry.spec.md](./jwkregistry.spec.md) for details.

## Contract: `HashOracle`

Stores and verifies cross-chain hash records with optional data values, allowing contracts to verify that specific events occurred on other chains.

### State Variables

```solidity
/// @notice Hash/Data records: hash => record
mapping(bytes32 => DataRecord) public dataRecords;

/// @notice Latest processed sequence number per source chain: chainId => latestSequenceNumber
/// @dev Sequences must be processed in order. If sequence N is processed, all sequences < N are also processed.
mapping(uint32 => uint256) public latestSequenceNumber;

/// @notice Total records
uint256 public totalRecords;
```

### Data Structures

```solidity
struct DataRecord {
    bytes32 hash;           // The hash value (serves as mapping key)
    uint64 blockNumber;     // Block number on source chain
    bytes value;            // Optional: Raw data or encoded value
}
```

### Interface

```solidity
interface IHashOracle {
    // ========== Recording (Consensus Only) ==========

    /// @notice Record a hash after validator consensus
    /// @param hash The hash to record
    /// @param blockNumber Block number on source chain
    /// @param sourceChain Source chain identifier
    /// @param sequenceNumber Sequence number to prevent duplicates
    function recordHash(
        bytes32 hash,
        uint64 blockNumber,
        uint32 sourceChain,
        uint256 sequenceNumber
    ) external;

    /// @notice Record a hash with associated data value
    /// @param hash The hash to record
    /// @param blockNumber Block number on source chain
    /// @param sourceChain Source chain identifier
    /// @param sequenceNumber Sequence number to prevent duplicates
    /// @param value Optional data value to store
    function recordData(
        bytes32 hash,
        uint64 blockNumber,
        uint32 sourceChain,
        uint256 sequenceNumber,
        bytes calldata value
    ) external;

    // ========== Verification ==========

    /// @notice Verify if a hash exists and get its record
    /// @param hash The hash to verify
    /// @return exists True if hash is recorded
    /// @return record The data record
    function verifyHash(bytes32 hash) external view returns (bool exists, DataRecord memory record);

    /// @notice Check if a sequence has been processed (or can be processed)
    /// @dev Returns true if sequenceNumber <= latestSequenceNumber for the chain
    function isSequenceProcessed(uint32 sourceChain, uint256 sequenceNumber) external view returns (bool);

    // ========== Statistics ==========

    function getStatistics() external view returns (uint256 totalRecords);
}
```

### Events

```solidity
event HashRecorded(
    bytes32 indexed hash,
    uint32 indexed sourceChain,
    uint64 blockNumber,
    uint256 sequenceNumber
);

event DataRecorded(
    bytes32 indexed hash,
    uint32 indexed sourceChain,
    uint64 blockNumber,
    uint256 sequenceNumber,
    uint256 valueLength
);
```

### Errors

```solidity
error HashAlreadyRecorded(bytes32 hash);
error SequenceOutOfOrder(uint32 sourceChain, uint256 sequenceNumber, uint256 expectedNext);
error OnlySystemCaller();
```

## Use Cases

### Bridge Verification

Verify Ethereum deposit events before minting on Gravity:

```solidity
function claimDeposit(
    bytes32 depositHash,
    uint256 amount,
    address recipient
) external {
    // Verify the deposit hash was recorded by oracle
    (bool exists, IHashOracle.DataRecord memory record) =
        IHashOracle(HASH_ORACLE).verifyHash(depositHash);

    require(exists, "Deposit not verified");

    // Process deposit...
}
```

### DNS Record Storage

DNS records can be stored using the `recordData` function with standardized encoding:

```solidity
// DNS record encoding for HashOracle
library DNSEncoding {
    struct DNSRecord {
        string domain;
        string recordType;  // "A", "AAAA", "TXT", etc.
        bytes data;
        uint64 ttl;
    }

    function encode(DNSRecord calldata record) external pure returns (bytes32, bytes memory) {
        bytes32 hash = keccak256(abi.encode(record.domain, record.recordType));
        bytes value = abi.encode(record.data, record.ttl);
        return (hash, value);
    }

    function decode(bytes memory value) external pure returns (bytes memory data, uint64 ttl) {
        (data, ttl) = abi.decode(value, (bytes, uint64));
    }
}
```

Usage example:
```solidity
// Record a DNS record
(bytes32 dnsHash, bytes memory dnsValue) = DNSEncoding.encode(dnsRecord);
hashOracle.recordData{sourceChain: DNS_CHAIN_ID}(dnsHash, blockNumber, sequenceNumber, dnsValue);

// Verify and retrieve DNS record
(bool exists, IHashOracle.DataRecord memory record) = hashOracle.verifyHash(dnsHash);
(bytes memory data, uint64 ttl) = DNSEncoding.decode(record.value);
```

### Cross-chain Message Verification

Verify message hashes for cross-chain communication:

```solidity
function verifyCrossChainMessage(bytes32 messageHash) external view returns (bool) {
    (bool exists, ) = IHashOracle(HASH_ORACLE).verifyHash(messageHash);
    return exists;
}
```

### Merkle Root Verification

Verify Merkle root hashes for light client proofs:

```solidity
function verifyMerkleRoot(
    bytes32 rootHash,
    bytes32 leafHash,
    bytes32[] calldata proofs
) external view returns (bool) {
    (bool exists, ) = IHashOracle(HASH_ORACLE).verifyHash(rootHash);
    if (!exists) return false;

    // Verify Merkle proof against the root
    return _verifyMerkleProof(rootHash, leafHash, proofs);
}
```

## Security Considerations

1. **Consensus Required**: All oracle data requires validator consensus
2. **Sequence Deduplication**: Prevents replay of cross-chain events by enforcing sequential processing (sequences must be processed in order)
3. **Storage Optimization**: Using `latestSequenceNumber` per chain instead of nested mappings reduces gas costs

## Access Control

| Function | Caller |
|----------|--------|
| `recordHash()` | System Caller (via GravityPortal) |
| `recordData()` | System Caller (via GravityPortal) |
| Query functions | Anyone |

## Integration Examples

### Recording via GravityPortal

The GravityPortal routes consensus data to HashOracle:

```solidity
// In GravityPortal
function processConsensusData(
    ProviderJWKs[] calldata jwks,
    CrossChainParams[] calldata params
) external onlySystem {
    // Process JWK data -> JWKRegistry
    if (jwks.length > 0) {
        jwkRegistry.updateObservedJWKs(jwks);
    }

    // Process cross-chain events
    for (uint256 i = 0; i < params.length; i++) {
        CrossChainParams calldata param = params[i];

        // Check block number via JWKRegistry (de-duplication)
        if (!jwkRegistry.updateProviderBlockNumber(param.issuer, param.blockNumber)) {
            continue; // Skip already processed
        }

        // Route to appropriate module
        if (param.eventType == EventType.DEPOSIT) {
            crossChainGateway.processDeposit(param);
        } else if (param.eventType == EventType.HASH) {
            hashOracle.recordHash(
                param.hash,
                param.blockNumber,
                param.sourceChain,
                param.sequenceNumber
            );
        } else if (param.eventType == EventType.DATA) {
            hashOracle.recordData(
                param.hash,
                param.blockNumber,
                param.sourceChain,
                param.sequenceNumber,
                param.value
            );
        }
    }
}
```

## Testing Requirements

1. **Unit Tests**:
   - Hash recording and verification
   - Data recording with value
   - Sequence number validation
   - Storage optimization verification

2. **Integration Tests**:
   - Full cross-chain verification flow
   - GravityPortal routing to HashOracle
   - Sequence boundary handling

3. **Fuzz Tests**:
   - Random hash values
   - Random sequence numbers
   - Edge cases in sequence ordering

4. **Security Tests**:
   - Replay attack prevention (sequence out of order)
   - Unauthorized access attempts
   - Invalid data rejection

