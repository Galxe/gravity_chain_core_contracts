---
status: unstarted
owner: TBD
---

# Governance Specification

## Overview

The Governance module enables on-chain governance for the Gravity blockchain, allowing validators and token holders to
propose and vote on protocol changes. This includes parameter updates, contract upgrades, and other administrative
actions.

## Design Goals

1. **Decentralized Control**: No single party can unilaterally change the protocol
2. **Transparent Process**: All proposals and votes are on-chain and auditable
3. **Time-locked Execution**: Mandatory delay before executing approved changes
4. **Flexible Voting**: Support for different voting strategies

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Governance Module                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌────────────────┐         ┌────────────────┐                      │
│   │   GovToken     │────────▶│   Governor     │                      │
│   │ (voting power) │         │ (proposals)    │                      │
│   └────────────────┘         └───────┬────────┘                      │
│                                      │                               │
│                              queue approved                          │
│                                      │                               │
│                                      ▼                               │
│                              ┌────────────────┐                      │
│                              │   Timelock     │                      │
│                              │ (delay + exec) │                      │
│                              └───────┬────────┘                      │
│                                      │                               │
│                               execute                                │
│                                      │                               │
│                                      ▼                               │
│                              ┌────────────────┐                      │
│                              │    GovHub      │                      │
│                              │ (param routing)│                      │
│                              └───────┬────────┘                      │
│                                      │                               │
│              ┌───────────────┬───────┼───────┬───────────────┐       │
│              ▼               ▼       ▼       ▼               ▼       │
│        ┌──────────┐   ┌──────────┐       ┌──────────┐  ┌──────────┐ │
│        │StakeConf │   │EpochMgr  │       │Randomness│  │  Other   │ │
│        └──────────┘   └──────────┘       └──────────┘  └──────────┘ │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## Contract: `GovToken`

An ERC20 token with voting capabilities (ERC20Votes).

### Purpose

- Represents voting power in governance
- Can be delegated to other addresses
- Minted to validators/stakers proportional to their stake

### Interface

```solidity
interface IGovToken {
    // ========== ERC20 ==========
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);

    // ========== Voting ==========

    /// @notice Get current voting power
    function getVotes(address account) external view returns (uint256);

    /// @notice Get voting power at a past block
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);

    /// @notice Delegate voting power to another address
    function delegate(address delegatee) external;

    /// @notice Get current delegate
    function delegates(address account) external view returns (address);

    // ========== Minting (Authorized Only) ==========

    /// @notice Mint tokens to an address
    function mint(address to, uint256 amount) external;

    /// @notice Burn tokens from an address
    function burn(address from, uint256 amount) external;
}
```

### Events

```solidity
event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);
```

## Contract: `Governor`

Manages governance proposals and voting.

### Proposal Lifecycle

```
┌────────────┐   create    ┌────────────┐   voting    ┌────────────┐
│  Pending   │────────────▶│   Active   │────────────▶│  Succeeded │
└────────────┘   delay     └────────────┘   period    └─────┬──────┘
                                 │                          │
                           vote fails                  queue
                                 │                          │
                                 ▼                          ▼
                           ┌────────────┐            ┌────────────┐
                           │  Defeated  │            │   Queued   │
                           └────────────┘            └─────┬──────┘
                                                           │
                                                      timelock
                                                           │
                                                           ▼
                                                     ┌────────────┐
                                                     │  Executed  │
                                                     └────────────┘
```

### Proposal States

| State     | Description                              |
| --------- | ---------------------------------------- |
| Pending   | Created, waiting for voting to start     |
| Active    | Voting is open                           |
| Canceled  | Proposal was canceled                    |
| Defeated  | Did not reach quorum or majority against |
| Succeeded | Passed, ready to queue                   |
| Queued    | In timelock, waiting for execution       |
| Expired   | Timelock expired without execution       |
| Executed  | Successfully executed                    |

### Configuration

| Parameter               | Default     | Description                  |
| ----------------------- | ----------- | ---------------------------- |
| Voting Delay            | 0 blocks    | Delay before voting starts   |
| Voting Period           | 7 days      | Duration of voting           |
| Proposal Threshold      | 2,000,000 G | Tokens needed to propose     |
| Quorum                  | 10%         | Minimum participation        |
| Min Period After Quorum | 1 day       | Extended voting after quorum |

### Interface

```solidity
interface IGravityGovernor {
    // ========== Proposals ==========

    /// @notice Create a new proposal
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256 proposalId);

    /// @notice Queue a succeeded proposal for execution
    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256 proposalId);

    /// @notice Execute a queued proposal
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external payable returns (uint256 proposalId);

    /// @notice Cancel a proposal
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256 proposalId);

    // ========== Voting ==========

    /// @notice Cast a vote
    /// @param support 0 = Against, 1 = For, 2 = Abstain
    function castVote(uint256 proposalId, uint8 support) external returns (uint256 weight);

    /// @notice Cast a vote with reason
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external returns (uint256 weight);

    // ========== Queries ==========

    function state(uint256 proposalId) external view returns (ProposalState);
    function proposalVotes(uint256 proposalId) external view returns (
        uint256 againstVotes,
        uint256 forVotes,
        uint256 abstainVotes
    );
    function hasVoted(uint256 proposalId, address account) external view returns (bool);
    function proposalThreshold() external view returns (uint256);
    function quorum(uint256 blockNumber) external view returns (uint256);

    // ========== Configuration ==========

    function updateParam(string calldata key, bytes calldata value) external;
}
```

### Events

```solidity
event ProposalCreated(
    uint256 proposalId,
    address proposer,
    address[] targets,
    uint256[] values,
    string[] signatures,
    bytes[] calldatas,
    uint256 startBlock,
    uint256 endBlock,
    string description
);

event VoteCast(
    address indexed voter,
    uint256 proposalId,
    uint8 support,
    uint256 weight,
    string reason
);

event ProposalQueued(uint256 proposalId, uint256 eta);
event ProposalExecuted(uint256 proposalId);
event ProposalCanceled(uint256 proposalId);
```

### Errors

```solidity
error NotWhitelisted();
error TotalSupplyNotEnough();
error OneLiveProposalPerProposer();
error ProposalNotSucceeded();
error ProposalNotQueued();
error TimelockNotReady();
```

## Contract: `Timelock`

Enforces a delay between proposal approval and execution.

### Purpose

- Provides time for users to react to approved changes
- Prevents flash governance attacks
- Allows for emergency intervention if needed

### Interface

```solidity
interface ITimelock {
    /// @notice Get minimum delay for operations
    function getMinDelay() external view returns (uint256);

    /// @notice Check if operation is ready for execution
    function isOperationReady(bytes32 id) external view returns (bool);

    /// @notice Check if operation is pending
    function isOperationPending(bytes32 id) external view returns (bool);

    /// @notice Check if operation was executed
    function isOperationDone(bytes32 id) external view returns (bool);

    /// @notice Schedule an operation
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    /// @notice Execute a scheduled operation
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    /// @notice Cancel a scheduled operation
    function cancel(bytes32 id) external;
}
```

### Default Configuration

| Parameter | Default         | Description                      |
| --------- | --------------- | -------------------------------- |
| Min Delay | 1 day           | Minimum time before execution    |
| Proposers | Governor        | Who can schedule operations      |
| Executors | Anyone          | Who can execute ready operations |
| Admin     | Timelock itself | Who can change config            |

## Contract: `GovHub`

Routes governance parameter updates to target contracts.

### Purpose

- Central point for parameter updates
- Validates update requests
- Emits standardized events

### Interface

```solidity
interface IGovHub {
    /// @notice Update a parameter on a target contract
    function updateParam(
        address target,
        string calldata key,
        bytes calldata value
    ) external;

    /// @notice Batch update multiple parameters
    function batchUpdateParam(
        address[] calldata targets,
        string[] calldata keys,
        bytes[] calldata values
    ) external;
}
```

### Target Contracts

All system contracts that support governance updates implement:

```solidity
interface IParamSubscriber {
    /// @notice Update a parameter
    function updateParam(string calldata key, bytes calldata value) external;
}
```

### Whitelisted Targets

Only whitelisted contracts can receive updates through GovHub:

| Contract         | Parameters                                       |
| ---------------- | ------------------------------------------------ |
| StakeConfig      | minValidatorStake, maxValidatorStake, lockAmount |
| EpochManager     | epochIntervalMicros                              |
| RandomnessConfig | thresholds                                       |
| Governor         | votingDelay, votingPeriod, proposalThreshold     |

## Governance Flow Example

### Updating Epoch Duration

```solidity
// 1. Create proposal
uint256 proposalId = governor.propose(
    [GOV_HUB_ADDR],                    // targets
    [0],                                // values (no ETH)
    [abi.encodeWithSignature(
        "updateParam(address,string,bytes)",
        EPOCH_MANAGER_ADDR,
        "epochIntervalMicros",
        abi.encode(4 hours * 1_000_000) // new value
    )],
    "Increase epoch duration to 4 hours"
);

// 2. Vote (during voting period)
governor.castVote(proposalId, 1); // 1 = For

// 3. Queue (after voting succeeds)
governor.queue(
    [GOV_HUB_ADDR],
    [0],
    [/* same calldata */],
    keccak256(bytes("Increase epoch duration to 4 hours"))
);

// 4. Execute (after timelock delay)
governor.execute(
    [GOV_HUB_ADDR],
    [0],
    [/* same calldata */],
    keccak256(bytes("Increase epoch duration to 4 hours"))
);

// Result: EpochManager.epochIntervalMicros is now 4 hours
```

## Access Control

### GovToken

| Function     | Caller           |
| ------------ | ---------------- |
| `transfer()` | Token holder     |
| `delegate()` | Token holder     |
| `mint()`     | ValidatorManager |
| `burn()`     | ValidatorManager |

### Governor

| Function        | Caller                         |
| --------------- | ------------------------------ |
| `propose()`     | Anyone with threshold tokens   |
| `castVote()`    | Token holders                  |
| `queue()`       | Anyone (if proposal succeeded) |
| `execute()`     | Anyone (if timelock ready)     |
| `cancel()`      | Proposer or admin              |
| `updateParam()` | Governance (self)              |

### Timelock

| Function     | Caller   |
| ------------ | -------- |
| `schedule()` | Governor |
| `execute()`  | Anyone   |
| `cancel()`   | Admin    |

### GovHub

| Function        | Caller   |
| --------------- | -------- |
| `updateParam()` | Timelock |

## Security Considerations

1. **Proposal Threshold**: Prevents spam proposals
2. **Quorum Requirement**: Ensures sufficient participation
3. **Timelock Delay**: Provides reaction time
4. **One Proposal Limit**: Prevents proposal spam per address
5. **Whitelisted Targets**: Only approved contracts can be called
6. **Supply Threshold**: Proposals only start after sufficient token distribution

## Invariants

1. Only one active proposal per proposer at a time
2. Proposals cannot be executed before timelock delay
3. Votes are weighted by token balance at proposal creation
4. Quorum is calculated as % of total supply

## Testing Requirements

1. **Unit Tests**:

   - Token minting and delegation
   - Proposal creation and voting
   - Timelock scheduling and execution
   - Parameter updates

2. **Integration Tests**:

   - Full governance flow
   - Multi-proposal scenarios
   - Epoch transitions during governance

3. **Fuzz Tests**:

   - Random vote distributions
   - Edge case timing
   - Malicious proposal attempts

4. **Invariant Tests**:
   - Token supply conservation
   - Vote weight accuracy
   - Timelock timing constraints
