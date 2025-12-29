# System Registry Specification

## Overview

The System Registry is a central contract that stores system-wide addresses and configuration constants. It replaces the original `System.sol` pattern of inheritance-based address constants with a more flexible registry-based approach.

## Design Goals

1. **Single Source of Truth**: All system addresses are stored in one place
2. **Immutable Core Addresses**: Critical addresses are immutable after genesis
3. **Configurable Values**: Some values can be updated via governance
4. **Gas Efficient**: Optimized for frequent reads

## Contract: `Registry`

### State Variables

```solidity
// Immutable system addresses (set at genesis, never change)
mapping(bytes32 => address) private immutableAddresses;

// Mutable configuration values (governance-controlled)
mapping(bytes32 => uint256) private configValues;
mapping(bytes32 => bytes) private configData;

// Address keys
bytes32 constant KEY_SYSTEM_CALLER = keccak256("SYSTEM_CALLER");
bytes32 constant KEY_GENESIS = keccak256("GENESIS");
bytes32 constant KEY_EPOCH_MANAGER = keccak256("EPOCH_MANAGER");
bytes32 constant KEY_VALIDATOR_MANAGER = keccak256("VALIDATOR_MANAGER");
bytes32 constant KEY_TIMESTAMP = keccak256("TIMESTAMP");
bytes32 constant KEY_BLOCK = keccak256("BLOCK");
// ... more address keys
```

### Predefined Addresses

| Key | Address | Description |
|-----|---------|-------------|
| `SYSTEM_CALLER` | `0x2000` | Reserved for blockchain runtime calls |
| `GENESIS` | `0x2008` | Genesis initialization contract |
| `EPOCH_MANAGER` | `0x2010` | Epoch management |
| `STAKE_CONFIG` | `0x2011` | Staking configuration |
| `VALIDATOR_MANAGER` | `0x2013` | Validator set management |
| `BLOCK` | `0x2016` | Block prologue handler |
| `TIMESTAMP` | `0x2017` | On-chain time |
| `JWK_MANAGER` | `0x2018` | JWK management for keyless |
| `SYSTEM_REWARD` | `0x201A` | System reward distribution |
| `GOV_HUB` | `0x201B` | Governance hub |
| `GOV_TOKEN` | `0x201D` | Governance token |
| `GOVERNOR` | `0x201E` | Governor contract |
| `TIMELOCK` | `0x201F` | Timelock controller |
| `RANDOMNESS_CONFIG` | `0x2020` | Randomness configuration |
| `DKG` | `0x2021` | DKG contract |
| `RECONFIGURATION_DKG` | `0x2022` | Reconfiguration with DKG |
| `HASH_ORACLE` | `0x2023` | Hash oracle |
| `REGISTRY` | `0x20FF` | This registry contract |

### Interface

```solidity
interface IRegistry {
    // ========== Address Queries ==========
    
    /// @notice Get a system address by key
    /// @param key The address key (e.g., keccak256("VALIDATOR_MANAGER"))
    /// @return The address, or address(0) if not set
    function getAddress(bytes32 key) external view returns (address);
    
    /// @notice Get a system address, revert if not set
    /// @param key The address key
    /// @return The address
    function requireAddress(bytes32 key) external view returns (address);
    
    // ========== Configuration Queries ==========
    
    /// @notice Get a uint256 configuration value
    /// @param key The config key
    /// @return The value, or 0 if not set
    function getUint(bytes32 key) external view returns (uint256);
    
    /// @notice Get bytes configuration data
    /// @param key The config key
    /// @return The data, or empty bytes if not set
    function getBytes(bytes32 key) external view returns (bytes memory);
    
    // ========== Admin Functions ==========
    
    /// @notice Initialize the registry (genesis only)
    function initialize() external;
    
    /// @notice Update a configuration value (governance only)
    /// @param key The config key
    /// @param value The new value
    function setUint(bytes32 key, uint256 value) external;
    
    /// @notice Update bytes configuration (governance only)
    /// @param key The config key
    /// @param data The new data
    function setBytes(bytes32 key, bytes calldata data) external;
}
```

### Events

```solidity
/// @notice Emitted when a configuration value is updated
event ConfigUpdated(bytes32 indexed key, uint256 oldValue, uint256 newValue);

/// @notice Emitted when bytes configuration is updated
event ConfigBytesUpdated(bytes32 indexed key, bytes oldData, bytes newData);
```

### Errors

```solidity
/// @notice Address not found in registry
error AddressNotFound(bytes32 key);

/// @notice Only genesis can call this function
error OnlyGenesis();

/// @notice Only governance can call this function
error OnlyGovernance();

/// @notice Registry already initialized
error AlreadyInitialized();
```

## Access Control

| Function | Caller |
|----------|--------|
| `initialize()` | Genesis only |
| `getAddress()` | Anyone |
| `getUint()` | Anyone |
| `getBytes()` | Anyone |
| `setUint()` | Governance only |
| `setBytes()` | Governance only |

## Initialization

During genesis, the registry is initialized with all predefined addresses. These addresses are **immutable** and cannot be changed after initialization.

```solidity
function initialize() external onlyGenesis {
    if (initialized) revert AlreadyInitialized();
    
    // Set all immutable addresses
    immutableAddresses[KEY_SYSTEM_CALLER] = 0x0000000000000000000000000000000000002000;
    immutableAddresses[KEY_GENESIS] = 0x0000000000000000000000000000000000002008;
    // ... set all addresses
    
    initialized = true;
}
```

## Usage Pattern

Other contracts should use the registry to look up addresses instead of hardcoding:

```solidity
// Old pattern (hardcoded)
address constant VALIDATOR_MANAGER = 0x0000000000000000000000000000000000002013;

// New pattern (registry lookup)
function getValidatorManager() internal view returns (IValidatorManager) {
    return IValidatorManager(IRegistry(REGISTRY_ADDR).requireAddress(KEY_VALIDATOR_MANAGER));
}
```

## Gas Optimization

For frequently accessed addresses, contracts may cache the address locally after first lookup:

```solidity
address private _cachedValidatorManager;

function validatorManager() internal returns (IValidatorManager) {
    if (_cachedValidatorManager == address(0)) {
        _cachedValidatorManager = IRegistry(REGISTRY_ADDR).requireAddress(KEY_VALIDATOR_MANAGER);
    }
    return IValidatorManager(_cachedValidatorManager);
}
```

## Upgrade Considerations

- The registry contract itself is non-upgradeable
- System addresses are immutable after genesis
- Configuration values can be updated via governance
- New address keys can be added in future versions

## Security Considerations

1. **Immutable Addresses**: Core system addresses cannot be changed, preventing address substitution attacks
2. **Governance-only Configuration**: Only governance can modify configuration values
3. **No Self-destruct**: Registry cannot be destroyed
4. **Initialization Guard**: Prevents re-initialization attacks

## Testing Requirements

1. Verify all addresses are set correctly at initialization
2. Test that immutable addresses cannot be modified
3. Test governance-controlled value updates
4. Fuzz test address lookups for gas consistency
5. Test error conditions (address not found, unauthorized)

