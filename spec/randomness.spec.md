---
status: drafting
owner: @changliang
---

# Randomness Specification

## TODOs

1. Add Aptos's Move contract github link to this spec.
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/dkg.spec.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/reconfiguration_with_dkg.spec.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/configs/randomness_config.spec.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/dkg.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/reconfiguration_with_dkg.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/configs/randomness_config.move

2. Governance contract should be able to manage randomness config.
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/aptos-release-builder/data/proposals/enable_randomness.move

## Overview

The Randomness module provides secure, verifiable random number generation for the Gravity blockchain using Distributed
Key Generation (DKG). This enables applications to access unpredictable, bias-resistant random values.

## Design Goals

1. **Unpredictability**: No party can predict random values before they're revealed
2. **Verifiability**: Anyone can verify randomness was generated correctly
3. **Bias Resistance**: No party can manipulate the random output
4. **Availability**: System remains available even if some validators are offline

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Randomness Module                              │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │                    RandomnessConfig                         │     │
│   │  ┌─────────────┐  ┌─────────────────────┐                  │     │
│   │  │   Current   │  │      Pending        │                  │     │
│   │  │   Config    │  │ (next epoch config) │                  │     │
│   │  └─────────────┘  └─────────────────────┘                  │     │
│   └────────────────────────────────────────────────────────────┘     │
│                              │                                        │
│                              ▼                                        │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │                          DKG                                │     │
│   │  ┌─────────────────┐  ┌─────────────────────────────────┐  │     │
│   │  │   In-Progress   │  │       Last Completed            │  │     │
│   │  │     Session     │  │         Session                 │  │     │
│   │  └─────────────────┘  └─────────────────────────────────┘  │     │
│   └────────────────────────────────────────────────────────────┘     │
│                              │                                        │
│                              ▼                                        │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │                 ReconfigurationWithDKG                      │     │
│   │           (Coordinates DKG with Epoch Transitions)          │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## Contract: `RandomnessConfig`

Stores configuration parameters for the randomness system.

### Configuration Versions

```solidity
enum ConfigVariant {
    V1,     // Original config format
    V2      // Extended with fast path threshold
}

struct ConfigV1 {
    FixedPoint64 secrecyThreshold;        // Min stake for secrecy
    FixedPoint64 reconstructionThreshold; // Min stake for reconstruction
}

struct ConfigV2 {
    FixedPoint64 secrecyThreshold;
    FixedPoint64 reconstructionThreshold;
    FixedPoint64 fastPathSecrecyThreshold;  // For optimistic path
}

struct RandomnessConfigData {
    ConfigVariant variant;
    ConfigV1 configV1;
    ConfigV2 configV2;
}
```

### Threshold Meaning

| Threshold         | Purpose                  | Typical Value |
| ----------------- | ------------------------ | ------------- |
| Secrecy           | Min stake to keep secret | 50% + 1       |
| Reconstruction    | Min stake to reveal      | 50% + 1       |
| Fast Path Secrecy | For optimistic execution | 66%           |

### Interface

```solidity
interface IRandomnessConfig {
    // ========== Queries ==========

    /// @notice Check if randomness is enabled
    function enabled() external view returns (bool);

    /// @notice Get current config
    function current() external view returns (RandomnessConfigData memory);

    /// @notice Get pending config for next epoch
    function pending() external view returns (bool hasPending, RandomnessConfigData memory config);

    /// @notice Check if initialized
    function isInitialized() external view returns (bool);

    // ========== Config Updates ==========

    /// @notice Initialize with config (genesis only)
    function initialize(RandomnessConfigData memory config) external;

    /// @notice Set config for next epoch
    function setForNextEpoch(RandomnessConfigData memory newConfig) external;

    /// @notice Apply pending config (epoch manager only)
    function onNewEpoch() external;

    // ========== Config Builders ==========

    /// @notice Create a V1 config
    function newV1(
        FixedPoint64 memory secrecyThreshold,
        FixedPoint64 memory reconstructionThreshold
    ) external pure returns (RandomnessConfigData memory);

    /// @notice Create a V2 config
    function newV2(
        FixedPoint64 memory secrecyThreshold,
        FixedPoint64 memory reconstructionThreshold,
        FixedPoint64 memory fastPathSecrecyThreshold
    ) external pure returns (RandomnessConfigData memory);
}
```

### Events

```solidity
event ConfigUpdated(RandomnessConfigData oldConfig, RandomnessConfigData newConfig);
event PendingConfigSet(RandomnessConfigData config);
```

### Errors

```solidity
error NotInitialized();
error AlreadyInitialized();
error InvalidConfigVariant();
error NotAuthorized(address caller);
```

## Contract: `DKG`

Manages Distributed Key Generation sessions.

### DKG Session Lifecycle

```
┌──────────────┐         start()          ┌──────────────┐
│   No Active  │─────────────────────────▶│  In Progress │
│   Session    │                          │              │
└──────────────┘                          └──────┬───────┘
       ▲                                         │
       │                                  finish(transcript)
       │                                         │
       │         tryClear()                      ▼
       └──────────────────────────────────┌──────────────┐
                                          │  Completed   │
                                          └──────────────┘
```

### Data Structures

```solidity
struct FixedPoint64 {
    uint128 value;    // Fixed-point representation
}

struct ValidatorConsensusInfo {
    bytes aptosAddress;     // Validator identifier
    bytes pkBytes;          // Public key bytes
    uint64 votingPower;     // Voting power
}

struct DKGSessionMetadata {
    uint64 dealerEpoch;                              // Epoch running DKG
    RandomnessConfigData randomnessConfig;           // Config for this session
    ValidatorConsensusInfo[] dealerValidatorSet;     // Current validators
    ValidatorConsensusInfo[] targetValidatorSet;     // Next epoch validators
}

struct DKGSessionState {
    DKGSessionMetadata metadata;
    uint64 startTimeUs;           // Start timestamp (microseconds)
    bytes transcript;             // DKG transcript (set on completion)
}

struct DKGState {
    DKGSessionState inProgress;     // Current session if any
    DKGSessionState lastCompleted;  // Last completed session
    bool hasInProgress;
    bool hasLastCompleted;
}
```

### Interface

```solidity
interface IDKG {
    // ========== Session Management ==========

    /// @notice Initialize the DKG contract (genesis only)
    function initialize() external;

    /// @notice Start a new DKG session
    /// @param dealerEpoch Current epoch number
    /// @param randomnessConfig Randomness configuration
    /// @param dealerValidatorSet Current validators
    /// @param targetValidatorSet Next epoch validators
    function start(
        uint64 dealerEpoch,
        RandomnessConfigData memory randomnessConfig,
        ValidatorConsensusInfo[] memory dealerValidatorSet,
        ValidatorConsensusInfo[] memory targetValidatorSet
    ) external;

    /// @notice Complete a DKG session with the generated transcript
    /// @param transcript The DKG transcript
    function finish(bytes memory transcript) external;

    /// @notice Clear an incomplete session (if epoch changed)
    function tryClearIncompleteSession() external;

    // ========== Queries ==========

    /// @notice Check if DKG is in progress
    function isDKGInProgress() external view returns (bool);

    /// @notice Get the incomplete session if any
    function incompleteSession() external view returns (bool hasSession, DKGSessionState memory session);

    /// @notice Get the last completed session
    function lastCompletedSession() external view returns (bool hasSession, DKGSessionState memory session);

    /// @notice Get dealer epoch from a session
    function sessionDealerEpoch(DKGSessionState memory session) external pure returns (uint64);
}
```

### Events

```solidity
event DKGStartEvent(DKGSessionMetadata metadata, uint64 startTimeUs);
event DKGCompleted(uint64 dealerEpoch, bytes32 transcriptHash);
event DKGSessionCleared(uint64 dealerEpoch);
```

### Errors

```solidity
error DKGInProgress();
error DKGNotInProgress();
error DKGNotInitialized();
error NotAuthorized(address caller);
```

## Contract: `ReconfigurationWithDKG`

Coordinates DKG with epoch transitions.

### Flow

```
┌─────────────┐     canTransition?     ┌─────────────────┐
│   Blocker   │───────────────────────▶│ EpochManager    │
└──────┬──────┘                        └────────┬────────┘
       │                                        │
       │ yes                                    │
       ▼                                        │
┌─────────────────────────┐                    │
│ ReconfigurationWithDKG  │◀───────────────────┘
│       tryStart()        │
└──────────┬──────────────┘
           │
           │ Start DKG if not running
           ▼
    ┌──────────────┐
    │     DKG      │
    │   (async)    │
    └──────┬───────┘
           │
           │ DKG completes off-chain
           ▼
┌─────────────────────────┐
│ ReconfigurationWithDKG  │
│  finishWithDkgResult()  │
└──────────┬──────────────┘
           │
           │ Apply configs & trigger transition
           ▼
    ┌──────────────┐
    │ EpochManager │
    │  transition  │
    └──────────────┘
```

### Interface

```solidity
interface IReconfigurationWithDKG {
    /// @notice Initialize (genesis only)
    function initialize() external;

    /// @notice Try to start DKG for epoch transition
    function tryStart() external;

    /// @notice Finish with DKG result and trigger epoch transition
    /// @param dkgResult The completed DKG transcript
    function finishWithDkgResult(bytes calldata dkgResult) external;

    /// @notice Finish without DKG (for cases where DKG is not needed)
    function finish() external;

    /// @notice Check if reconfiguration is in progress
    function isReconfigurationInProgress() external view returns (bool);
}
```

### Logic

```solidity
function tryStart() external onlyAuthorizedCallers {
    uint256 currentEpoch = IEpochManager(EPOCH_MANAGER).currentEpoch();

    // Check for incomplete session from current epoch
    (bool hasIncomplete, DKGSessionState memory session) = IDKG(DKG).incompleteSession();

    if (hasIncomplete && session.metadata.dealerEpoch == currentEpoch) {
        // Already running for this epoch
        return;
    }

    if (hasIncomplete) {
        // Clear old session from previous epoch
        IDKG(DKG).tryClearIncompleteSession();
    }

    // Get validator sets
    ValidatorConsensusInfo[] memory current = _getCurrentValidators();
    ValidatorConsensusInfo[] memory next = _getNextValidators();

    // Get config
    RandomnessConfigData memory config = IRandomnessConfig(RANDOMNESS_CONFIG).current();

    // Start DKG
    IDKG(DKG).start(currentEpoch, config, current, next);
}

function finishWithDkgResult(bytes calldata dkgResult) external onlyAuthorizedCallers {
    // Finish DKG session
    IDKG(DKG).finish(dkgResult);

    // Apply pending configs
    IRandomnessConfig(RANDOMNESS_CONFIG).onNewEpoch();

    // Trigger epoch transition
    IEpochManager(EPOCH_MANAGER).triggerEpochTransition();
}
```

## Access Control

### RandomnessConfig

| Function            | Caller                                            |
| ------------------- | ------------------------------------------------- |
| `initialize()`      | Genesis                                           |
| `current()`         | Anyone                                            |
| `pending()`         | Anyone                                            |
| `setForNextEpoch()` | System Caller, Governance, ReconfigurationWithDKG |
| `onNewEpoch()`      | ReconfigurationWithDKG                            |

### DKG

| Function                      | Caller                                                  |
| ----------------------------- | ------------------------------------------------------- |
| `initialize()`                | Genesis                                                 |
| `start()`                     | System Caller, Blocker, Genesis, ReconfigurationWithDKG |
| `finish()`                    | System Caller, Blocker, Genesis, ReconfigurationWithDKG |
| `tryClearIncompleteSession()` | System Caller, Blocker, Genesis, ReconfigurationWithDKG |
| Query functions               | Anyone                                                  |

### ReconfigurationWithDKG

| Function                        | Caller                          |
| ------------------------------- | ------------------------------- |
| `initialize()`                  | Genesis                         |
| `tryStart()`                    | System Caller, Blocker, Genesis |
| `finishWithDkgResult()`         | System Caller, Blocker, Genesis |
| `finish()`                      | System Caller, Blocker, Genesis |
| `isReconfigurationInProgress()` | Anyone                          |

## Security Considerations

1. **Threshold Security**: Thresholds must be > 50% to prevent single-party control
2. **Session Isolation**: Only one DKG session at a time
3. **Epoch Binding**: Sessions are bound to specific epochs
4. **Validator Verification**: Only registered validators participate
5. **Transcript Verification**: Transcripts verified before acceptance

## Invariants

1. At most one DKG session in progress at any time
2. `reconstructionThreshold > secrecyThreshold`
3. DKG sessions cannot span multiple epochs
4. Completed sessions have non-empty transcripts

## Testing Requirements

1. **Unit Tests**:

   - Config creation and validation
   - DKG session lifecycle
   - Reconfiguration coordination

2. **Integration Tests**:

   - Full DKG flow with epoch transitions
   - Config updates across epochs
   - Validator set changes

3. **Fuzz Tests**:

   - Random threshold values
   - Random session timing

4. **Invariant Tests**:
   - Session uniqueness
   - Threshold ordering
   - Epoch binding
