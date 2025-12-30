---
status: pending review 
owner: @yxia
---

# System Registry Specification

## Overview

The System Registry provides system-wide addresses and configuration constants through a modular design that separates compile-time constants from runtime configuration.

## Design Goals

1. **Single Source of Truth**: All system addresses are defined in one place
2. **Immutable Core Addresses**: Critical addresses are compile-time constants
3. **Configurable Values**: Some values can be updated via governance
4. **Gas Efficient**: Predefined addresses are inlined at compile-time (zero storage reads)
5. **Developer Friendly**: Import constants and access control functions without inheritance

## Architecture

```
src/registry/
├── GravityAddresses.sol       # Compile-time constants (library)
├── GravityAccessControl.sol   # Access control free functions
├── GravitySystemRegistry.sol  # Dynamic config contract
└── IGravitySystemRegistry.sol # Interface
```

### Gas Comparison

| Approach                  | Gas Cost                                      |
| ------------------------- | --------------------------------------------- |
| Compile-time constant     | ~3 gas (PUSH opcode, inlined)                 |
| Immutable storage         | ~100 gas                                      |
| SLOAD (mapping)           | ~2100 gas (cold) / ~100 gas (warm)            |
| External call + SLOAD     | ~2600 gas base + SLOAD                        |

Since predefined addresses are **immutable after genesis**, they are defined as **compile-time constants** in a library—not stored in mappings.

---

## Library: `GravityAddresses`

Pure compile-time constants for all system addresses. Importing this library gives zero-cost address access (inlined by compiler).

### Predefined Addresses

| Key                 | Address         | Description                           |
| ------------------- | --------------- | ------------------------------------- |
| `REGISTRY`          | `0x1625F0000`   | This registry contract                |
| `SYSTEM_CALLER`     | `0x1625F2000`   | Reserved for blockchain runtime calls |
| `GENESIS`           | `0x1625F2008`   | Genesis initialization contract       |
| `EPOCH_MANAGER`     | `0x1625F2010`   | Epoch management                      |
| `STAKE_CONFIG`      | `0x1625F2011`   | Staking configuration                 |
| `VALIDATOR_MANAGER` | `0x1625F2013`   | Validator set management              |
| `BLOCK`             | `0x1625F2016`   | Block prologue handler                |
| `TIMESTAMP`         | `0x1625F2017`   | On-chain time                         |
| `JWK_MANAGER`       | `0x1625F2018`   | JWK management for keyless            |
| `TIMELOCK`          | `0x1625F201F`   | Timelock controller                   |
| `HASH_ORACLE`       | `0x1625F2023`   | Hash oracle                           |

### Implementation

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GravityAddresses
/// @notice Compile-time constants for Gravity system addresses
/// @dev Import this library to get zero-cost address access (inlined by compiler)
library GravityAddresses {
    address internal constant REGISTRY = 0x0000000000000000000000000001625F0000;
    address internal constant SYSTEM_CALLER = 0x0000000000000000000000000001625F2000;
    address internal constant GENESIS = 0x0000000000000000000000000001625F2008;
    address internal constant EPOCH_MANAGER = 0x0000000000000000000000000001625F2010;
    address internal constant STAKE_CONFIG = 0x0000000000000000000000000001625F2011;
    address internal constant VALIDATOR_MANAGER = 0x0000000000000000000000000001625F2013;
    address internal constant BLOCK = 0x0000000000000000000000000001625F2016;
    address internal constant TIMESTAMP = 0x0000000000000000000000000001625F2017;
    address internal constant JWK_MANAGER = 0x0000000000000000000000000001625F2018;
    address internal constant TIMELOCK = 0x0000000000000000000000000001625F201F;
    address internal constant HASH_ORACLE = 0x0000000000000000000000000001625F2023;
}
```

---

## Free Functions: `GravityAccessControl`

Unified access control functions that can be imported and used directly or wrapped in modifiers. No inheritance required.

### Errors

```solidity
/// @notice Caller is not the allowed address
/// @param caller The actual msg.sender
/// @param allowed The expected address
error NotAllowed(address caller, address allowed);

/// @notice Caller is not in the allowed set
/// @param caller The actual msg.sender
/// @param allowed The array of allowed addresses
error NotAllowedAny(address caller, address[] allowed);
```

### Implementation

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GravityAddresses} from "./GravityAddresses.sol";

error NotAllowed(address caller, address allowed);
error NotAllowedAny(address caller, address[] allowed);

/// @notice Reverts if msg.sender is not the allowed address
function requireAllowed(address allowed) view {
    if (msg.sender != allowed) {
        revert NotAllowed(msg.sender, allowed);
    }
}

/// @notice Reverts if msg.sender is not one of the two allowed addresses
function requireAllowed(address a1, address a2) view {
    if (msg.sender != a1 && msg.sender != a2) {
        address[] memory allowed = new address[](2);
        allowed[0] = a1;
        allowed[1] = a2;
        revert NotAllowedAny(msg.sender, allowed);
    }
}

/// @notice Reverts if msg.sender is not one of the three allowed addresses
function requireAllowed(address a1, address a2, address a3) view {
    if (msg.sender != a1 && msg.sender != a2 && msg.sender != a3) {
        address[] memory allowed = new address[](3);
        allowed[0] = a1;
        allowed[1] = a2;
        allowed[2] = a3;
        revert NotAllowedAny(msg.sender, allowed);
    }
}

/// @notice Reverts if msg.sender is not one of the four allowed addresses
function requireAllowed(address a1, address a2, address a3, address a4) view {
    if (msg.sender != a1 && msg.sender != a2 && msg.sender != a3 && msg.sender != a4) {
        address[] memory allowed = new address[](4);
        allowed[0] = a1;
        allowed[1] = a2;
        allowed[2] = a3;
        allowed[3] = a4;
        revert NotAllowedAny(msg.sender, allowed);
    }
}

/// @notice Reverts if msg.sender is not in the allowed array
function requireAllowedAny(address[] memory allowed) view {
    uint256 len = allowed.length;
    for (uint256 i; i < len;) {
        if (msg.sender == allowed[i]) return;
        unchecked { ++i; }
    }
    revert NotAllowedAny(msg.sender, allowed);
}
```

---

## Contract: `GravitySystemRegistry`

Stores governance-controlled dynamic configuration values. Predefined addresses are NOT stored here—use `GravityAddresses` library instead.

### Interface

```solidity
interface IGravitySystemRegistry {
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
event ConfigBytesUpdated(bytes32 indexed key);
```

### Errors

```solidity
/// @notice Registry already initialized
error AlreadyInitialized();
```

### Implementation

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGravitySystemRegistry} from "./IGravitySystemRegistry.sol";
import {GravityAddresses} from "./GravityAddresses.sol";
import {requireAllowed} from "./GravityAccessControl.sol";

/// @title GravitySystemRegistry
/// @notice Central registry for governance-controlled configuration values
/// @dev Predefined addresses are NOT stored here—use GravityAddresses library instead
contract GravitySystemRegistry is IGravitySystemRegistry {
    bool private _initialized;
    mapping(bytes32 => uint256) private _configValues;
    mapping(bytes32 => bytes) private _configData;

    event ConfigUpdated(bytes32 indexed key, uint256 oldValue, uint256 newValue);
    event ConfigBytesUpdated(bytes32 indexed key);

    error AlreadyInitialized();

    function initialize() external {
        requireAllowed(GravityAddresses.GENESIS);
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
    }

    function getUint(bytes32 key) external view returns (uint256) {
        return _configValues[key];
    }

    function getBytes(bytes32 key) external view returns (bytes memory) {
        return _configData[key];
    }

    function setUint(bytes32 key, uint256 value) external {
        requireAllowed(GravityAddresses.TIMELOCK);
        uint256 oldValue = _configValues[key];
        _configValues[key] = value;
        emit ConfigUpdated(key, oldValue, value);
    }

    function setBytes(bytes32 key, bytes calldata data) external {
        requireAllowed(GravityAddresses.TIMELOCK);
        _configData[key] = data;
        emit ConfigBytesUpdated(key);
    }
}
```

---

## Usage Pattern

### Importing Constants (No Inheritance)

```solidity
import {GravityAddresses} from "./system/GravityAddresses.sol";

contract MyContract {
    function getEpochManager() external pure returns (address) {
        return GravityAddresses.EPOCH_MANAGER; // Inlined, ~3 gas
    }
}
```

### Access Control with Modifiers

```solidity
import {GravityAddresses} from "./system/GravityAddresses.sol";
import {requireAllowed, requireAllowedAny} from "./system/GravityAccessControl.sol";

contract ValidatorManager {
    // Define modifiers as one-liners
    modifier onlySystemCaller() {
        requireAllowed(GravityAddresses.SYSTEM_CALLER);
        _;
    }

    modifier onlyGovernance() {
        requireAllowed(GravityAddresses.TIMELOCK);
        _;
    }

    // Allow multiple callers
    modifier onlySystemOrEpochManager() {
        requireAllowed(GravityAddresses.SYSTEM_CALLER, GravityAddresses.EPOCH_MANAGER);
        _;
    }

    function updateValidator() external onlySystemCaller {
        // ...
    }

    function setConfig() external onlyGovernance {
        // ...
    }

    // Or call inline without modifier
    function emergencyAction() external {
        requireAllowed(
            GravityAddresses.SYSTEM_CALLER,
            GravityAddresses.GENESIS,
            GravityAddresses.TIMELOCK
        );
        // ...
    }

    // For dynamic or large sets of allowed addresses, use requireAllowedAny
    function dynamicAccess(address[] calldata allowedCallers) external {
        requireAllowedAny(allowedCallers);
        // ...
    }
}
```

---

## Access Control Summary

| Function       | Caller          |
| -------------- | --------------- |
| `initialize()` | Genesis only    |
| `getUint()`    | Anyone          |
| `getBytes()`   | Anyone          |
| `setUint()`    | Governance only |
| `setBytes()`   | Governance only |

---

## Security Considerations

1. **Compile-time Addresses**: Core system addresses are compile-time constants, eliminating storage manipulation attacks
2. **Governance-only Configuration**: Only governance can modify configuration values
3. **No Self-destruct**: Registry cannot be destroyed
4. **Initialization Guard**: Prevents re-initialization attacks
5. **Detailed Errors**: Access control errors include caller and expected addresses for debugging

---

## Testing Requirements

1. Verify all addresses in `GravityAddresses` match expected values
2. Test `requireAllowed()` with valid and invalid callers
3. Test `requireAllowed()` overloads (2, 3, 4 addresses)
4. Test governance-controlled value updates
5. Fuzz test `requireAllowedAny()` with various array sizes
6. Verify error messages contain correct caller and allowed addresses
