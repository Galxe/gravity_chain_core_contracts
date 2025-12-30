---
status: unstarted
owner: @yuejing
---

# JWK Registry Specification

## Overview

The JWKRegistry module manages JSON Web Keys (JWKs) for OIDC providers, enabling keyless authentication on Gravity. JWKs are public keys used by OIDC providers (Google, Apple, etc.) to sign JWT tokens. By tracking these keys on-chain, Gravity can verify keyless account signatures.

## Architecture

The JWKRegistry is part of the modular Gravity system:

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
│        │                                                              │
│        ▼                                                              │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                     JWKRegistry                             │   │
│   │                    (This spec)                             │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

> **Note**: This module was previously part of `JWKManager`. It has been refactored into a dedicated `JWKRegistry` that handles only JWK logic.

## Key Concepts

| Concept | Description |
|---------|-------------|
| **OIDC Provider** | Identity provider (Google, Apple, etc.) |
| **JWK** | JSON Web Key - public key for signature verification |
| **Observed JWKs** | Keys fetched from providers by validators |
| **Patched JWKs** | Keys after governance patches applied |
| **Federated JWKs** | Custom keys registered by dApps |

## Contract: `JWKRegistry`

Manages JSON Web Keys (JWKs) for OIDC providers and provider state for GravityPortal coordination.

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
interface IJWKRegistry {
    // ========== Provider Management ==========

    /// @notice Add or update an OIDC provider
    function upsertOIDCProvider(string calldata name, string calldata configUrl) external;

    /// @notice Remove an OIDC provider
    function removeOIDCProvider(string calldata name) external;

    /// @notice Get active providers
    function getActiveProviders() external view returns (OIDCProvider[] memory);

    // ========== Provider State Coordination (GravityPortal) ==========

    /// @notice Update provider block number and check if event should be processed
    /// @dev Used by GravityPortal to coordinate state and prevent duplicate processing
    /// @param issuer The provider issuer
    /// @param blockNumber The new block number
    /// @return success True if block number was updated (event should be processed), false if already processed
    function updateProviderBlockNumber(string calldata issuer, uint256 blockNumber) external returns (bool success);

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
│ OIDC Providers │     │   Validators   │     │  JWKRegistry   │
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
| `updateProviderBlockNumber()` | GravityPortal only |
| `upsertObservedJWKs()` | System Caller (via GravityPortal) |
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
event ProviderBlockNumberUpdated(string indexed issuer, uint256 blockNumber);
```

### Errors

```solidity
error ProviderNotFound(string issuer);
error ProviderAlreadyExists(string name);
error InvalidBlockNumber(uint256 blockNumber, uint256 lastBlockNumber);
error OnlyGravityPortal();
error OnlyGovernance();
}
```

## Integration with GravityPortal

The JWKRegistry provides state coordination for GravityPortal:

```solidity
// In GravityPortal
function processConsensusData(
    ProviderJWKs[] calldata jwks,
    CrossChainParams[] calldata params
) external onlySystem {
    // Process JWK data
    if (jwks.length > 0) {
        jwkRegistry.upsertObservedJWKs(jwks);
    }

    // Process cross-chain events
    for (uint256 i = 0; i < params.length; i++) {
        CrossChainParams calldata param = params[i];

        // Check block number via JWKRegistry (de-duplication)
        // Returns false if already processed, true if should process
        if (!jwkRegistry.updateProviderBlockNumber(param.issuer, param.blockNumber)) {
            continue; // Skip already processed event
        }

        // Route to appropriate module (HashOracle, CrossChainGateway, etc.)
        // ...
    }
}
```

## Use Cases

### Verifying a Keyless Signature

```solidity
function verifyKeylessSignature(
    string calldata issuer,
    bytes calldata jwkId,
    bytes calldata signature,
    bytes32 message
) external view returns (bool) {
    // Get the JWK for verification
    IJWKRegistry.JWK memory jwk = IJWKRegistry(JWK_REGISTRY).getPatchedJWK(issuer, jwkId);

    // Verify signature using the JWK
    return _verifyRSASignature(jwk, signature, message);
}
```

## Security Considerations

1. **Consensus Required**: Observed JWK updates require validator consensus
2. **Version Control**: JWK updates are versioned to prevent rollback
3. **Governance Patches**: Allow emergency key rotation via governance
4. **Federated Isolation**: dApp JWKs are isolated from system JWKs
5. **State Coordination**: Provider block numbers are managed by GravityPortal to prevent duplicate event processing

## Testing Requirements

1. **Unit Tests**:
   - Provider CRUD operations
   - JWK CRUD operations
   - Patch application
   - Federated JWK management
   - Block number coordination

2. **Integration Tests**:
   - GravityPortal routing to JWKRegistry
   - JWK rotation scenarios
   - Epoch boundary handling

3. **Fuzz Tests**:
   - Random JWK structures
   - Edge cases in patch application
   - Block number edge cases

4. **Security Tests**:
   - Unauthorized access attempts
   - Invalid JWK data rejection
   - Replay attack prevention
