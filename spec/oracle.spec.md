---
status: unstarted
owner: @yuejing
---

# Oracle Specification

## TODOs

1. simplify contract design. Only keep the "oracle" part. Fancy features like JWK can be deployed later. It doesn't need to be part of the core system contracts.

## Overview

The Oracle module provides native support for verifying information from outside the Gravity blockchain. This includes:

1. **Hash Oracle**: Verify cross-chain events by their hash
2. **JWK Manager**: Manage JSON Web Keys for keyless authentication
3. **DNS Oracle** (future): Verify DNS records

These oracles are powered by the Gravity validator consensus, meaning information is only accepted after validators reach consensus on its validity.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                           Oracle Module                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   External Sources          Validator Consensus         On-Chain      │
│                                                                       │
│   ┌──────────┐              ┌──────────────┐         ┌──────────┐   │
│   │ Ethereum │─────────────▶│  Validators  │────────▶│  Hash    │   │
│   │  Events  │              │   Observe    │         │  Oracle  │   │
│   └──────────┘              │   & Agree    │         └──────────┘   │
│                             └──────────────┘                         │
│   ┌──────────┐                    │              ┌──────────────┐   │
│   │  OIDC    │────────────────────┼─────────────▶│ JWK Manager  │   │
│   │Providers │                    │              └──────────────┘   │
│   └──────────┘                    │                                  │
│                                   │              ┌──────────────┐   │
│   ┌──────────┐                    └─────────────▶│ DNS Oracle   │   │
│   │   DNS    │                   (future)        │  (future)    │   │
│   │ Records  │                                   └──────────────┘   │
│   └──────────┘                                                       │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## Contract: `HashOracle`

Stores and verifies cross-chain hash records, allowing contracts to verify that specific events occurred on other chains.

### State Variables

```solidity
/// @notice Hash records: hash => record
mapping(bytes32 => HashRecord) public hashRecords;

/// @notice Processed sequences per source chain: chainId => sequenceNumber => processed
mapping(uint32 => mapping(uint256 => bool)) public processedSequences;

/// @notice Total hashes recorded
uint256 public totalHashesRecorded;
```

### Data Structures

```solidity
struct HashRecord {
    bytes32 hash;           // The hash value
    uint64 blockNumber;     // Block number on source chain
    uint32 sourceChain;     // Source chain identifier
    uint64 recordedAt;      // When recorded on Gravity
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
    
    // ========== Verification ==========
    
    /// @notice Verify if a hash exists and get its record
    /// @param hash The hash to verify
    /// @return exists True if hash is recorded
    /// @return record The hash record
    function verifyHash(bytes32 hash) external view returns (bool exists, HashRecord memory record);
    
    /// @notice Check if a sequence has been processed
    function isSequenceProcessed(uint32 sourceChain, uint256 sequenceNumber) external view returns (bool);
    
    // ========== Statistics ==========
    
    function getStatistics() external view returns (uint256 totalHashes);
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
```

### Errors

```solidity
error HashAlreadyRecorded(bytes32 hash);
error SequenceAlreadyProcessed(uint32 sourceChain, uint256 sequenceNumber);
error OnlySystemCaller();
```

### Use Cases

1. **Bridge Verification**: Verify Ethereum deposit events before minting on Gravity
2. **Cross-chain Messages**: Verify message hashes for cross-chain communication
3. **Proof Verification**: Verify Merkle root hashes for light client proofs

## Contract: `JWKManager`

Manages JSON Web Keys (JWKs) for OIDC providers, enabling keyless authentication on Gravity.

### Overview

JWKs are public keys used by OIDC providers (Google, Apple, etc.) to sign JWT tokens. By tracking these keys on-chain, Gravity can verify keyless account signatures.

### Key Concepts

| Concept | Description |
|---------|-------------|
| **OIDC Provider** | Identity provider (Google, Apple, etc.) |
| **JWK** | JSON Web Key - public key for signature verification |
| **Observed JWKs** | Keys fetched from providers by validators |
| **Patched JWKs** | Keys after governance patches applied |
| **Federated JWKs** | Custom keys registered by dApps |

### State Variables

```solidity
/// @notice Supported OIDC providers
OIDCProvider[] public supportedProviders;

/// @notice Validator-observed JWKs
AllProvidersJWKs private observedJWKs;

/// @notice JWKs after patches applied
AllProvidersJWKs private patchedJWKs;

/// @notice Governance patches
Patch[] public patches;

/// @notice Federated JWKs per dApp
mapping(address => AllProvidersJWKs) private federatedJWKs;
```

### Data Structures

```solidity
struct OIDCProvider {
    string name;              // e.g., "https://accounts.google.com"
    string configUrl;         // OIDC config URL
    bool active;              // Is provider active
    uint256 lastBlockNumber;  // Last observed block
}

struct JWK {
    uint8 variant;            // 0 = RSA, 1 = Unsupported
    bytes data;               // Encoded key data
}

struct RSA_JWK {
    string kid;               // Key ID
    string kty;               // Key type ("RSA")
    string alg;               // Algorithm ("RS256")
    string e;                 // Exponent
    string n;                 // Modulus
}

struct ProviderJWKs {
    string issuer;            // Provider identifier
    uint256 version;          // Version number
    JWK[] jwks;               // Keys for this provider
}

struct AllProvidersJWKs {
    ProviderJWKs[] entries;   // All provider entries
}

enum PatchType {
    RemoveAll,
    RemoveIssuer,
    RemoveJWK,
    UpsertJWK
}

struct Patch {
    PatchType patchType;
    string issuer;
    bytes jwkId;
    JWK jwk;
}
```

### Interface

```solidity
interface IJWKManager {
    // ========== Provider Management ==========
    
    /// @notice Add or update an OIDC provider
    function upsertOIDCProvider(string calldata name, string calldata configUrl) external;
    
    /// @notice Remove an OIDC provider
    function removeOIDCProvider(string calldata name) external;
    
    /// @notice Get active providers
    function getActiveProviders() external view returns (OIDCProvider[] memory);
    
    // ========== Observed JWKs (Consensus) ==========
    
    /// @notice Update observed JWKs from validator consensus
    function upsertObservedJWKs(ProviderJWKs[] calldata providerJWKs) external;
    
    /// @notice Remove an issuer's observed JWKs
    function removeIssuerFromObservedJWKs(string calldata issuer) external;
    
    // ========== Patches (Governance) ==========
    
    /// @notice Set all patches
    function setPatches(Patch[] calldata newPatches) external;
    
    /// @notice Add a single patch
    function addPatch(Patch calldata patch) external;
    
    // ========== Federated JWKs (dApps) ==========
    
    /// @notice Update federated JWKs for the caller
    function updateFederatedJWKSet(
        string calldata issuer,
        string[] calldata kidArray,
        string[] calldata algArray,
        string[] calldata eArray,
        string[] calldata nArray
    ) external;
    
    /// @notice Apply patches to caller's federated JWKs
    function patchFederatedJWKs(Patch[] calldata patches) external;
    
    // ========== Queries ==========
    
    /// @notice Get a patched JWK by issuer and key ID
    function getPatchedJWK(string calldata issuer, bytes calldata jwkId) external view returns (JWK memory);
    
    /// @notice Get a federated JWK
    function getFederatedJWK(address dapp, string calldata issuer, bytes calldata jwkId) external view returns (JWK memory);
    
    /// @notice Get all observed JWKs
    function getObservedJWKs() external view returns (AllProvidersJWKs memory);
    
    /// @notice Get all patched JWKs
    function getPatchedJWKs() external view returns (AllProvidersJWKs memory);
}
```

### JWK Update Flow

```
┌────────────────┐     ┌────────────────┐     ┌────────────────┐
│ OIDC Providers │     │   Validators   │     │  JWKManager    │
│ (Google, etc.) │────▶│  Fetch & Vote  │────▶│ observedJWKs   │
└────────────────┘     └────────────────┘     └───────┬────────┘
                                                      │
                                               Apply patches
                                                      │
                                                      ▼
                                              ┌────────────────┐
                                              │  patchedJWKs   │
                                              │  (final keys)  │
                                              └────────────────┘
```

### Access Control

| Function | Caller |
|----------|--------|
| `upsertOIDCProvider()` | Governance |
| `removeOIDCProvider()` | Governance |
| `upsertObservedJWKs()` | System Caller |
| `removeIssuerFromObservedJWKs()` | Governance |
| `setPatches()` | Governance |
| `addPatch()` | Governance |
| `updateFederatedJWKSet()` | Any dApp |
| `patchFederatedJWKs()` | Any dApp |
| Query functions | Anyone |

### Events

```solidity
event OIDCProviderAdded(string indexed name, string configUrl);
event OIDCProviderUpdated(string indexed name, string configUrl);
event OIDCProviderRemoved(string indexed name);
event ObservedJWKsUpdated(uint256 indexed epoch, ProviderJWKs[] entries);
event PatchesUpdated(uint256 count);
event PatchedJWKsRegenerated(bytes32 hash);
event FederatedJWKsUpdated(address indexed dapp, string issuer);
```

## Future: DNS Oracle

For verifying DNS records on-chain:

```solidity
interface IDNSOracle {
    struct DNSRecord {
        string domain;
        string recordType;  // A, AAAA, TXT, etc.
        bytes data;
        uint64 ttl;
        uint64 recordedAt;
    }
    
    function recordDNS(
        string calldata domain,
        string calldata recordType,
        bytes calldata data,
        uint64 ttl
    ) external;
    
    function verifyDNS(
        string calldata domain,
        string calldata recordType
    ) external view returns (bool exists, DNSRecord memory record);
}
```

## Security Considerations

1. **Consensus Required**: All oracle data requires validator consensus
2. **Sequence Deduplication**: Prevents replay of cross-chain events
3. **Version Control**: JWK updates are versioned to prevent rollback
4. **Governance Patches**: Allow emergency key rotation via governance
5. **Federated Isolation**: dApp JWKs are isolated from system JWKs

## Integration Examples

### Verifying a Bridge Deposit

```solidity
function claimDeposit(
    bytes32 depositHash,
    uint256 amount,
    address recipient
) external {
    // Verify the deposit hash was recorded by oracle
    (bool exists, IHashOracle.HashRecord memory record) = 
        IHashOracle(HASH_ORACLE).verifyHash(depositHash);
    
    require(exists, "Deposit not verified");
    require(record.sourceChain == ETHEREUM_CHAIN_ID, "Wrong source chain");
    
    // Process deposit...
}
```

### Verifying a Keyless Signature

```solidity
function verifyKeylessSignature(
    string calldata issuer,
    bytes calldata jwkId,
    bytes calldata signature,
    bytes32 message
) external view returns (bool) {
    // Get the JWK for verification
    IJWKManager.JWK memory jwk = IJWKManager(JWK_MANAGER).getPatchedJWK(issuer, jwkId);
    
    // Verify signature using the JWK
    return _verifyRSASignature(jwk, signature, message);
}
```

## Testing Requirements

1. **Unit Tests**:
   - Hash recording and verification
   - JWK CRUD operations
   - Patch application
   - Federated JWK management

2. **Integration Tests**:
   - Full cross-chain verification flow
   - JWK rotation scenarios
   - Epoch boundary handling

3. **Fuzz Tests**:
   - Random hash values
   - Random JWK structures
   - Edge cases in patch application

4. **Security Tests**:
   - Replay attack prevention
   - Unauthorized access attempts
   - Invalid data rejection

