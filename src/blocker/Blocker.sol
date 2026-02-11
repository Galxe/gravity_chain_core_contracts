// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { ITimestampWriter } from "../runtime/ITimestampWriter.sol";
import { IReconfiguration } from "./IReconfiguration.sol";
import { IValidatorPerformanceTracker } from "./IValidatorPerformanceTracker.sol";
import { IValidatorManagement } from "../staking/IValidatorManagement.sol";

/// @title Blocker
/// @author Gravity Team
/// @notice Block prologue entry point for the Gravity blockchain
/// @dev Called by VM runtime at the start of each block to update on-chain state.
///      Coordinates timestamp updates and epoch transition checks.
///      Follows Aptos pattern: proposers are identified by index into the active validator set.
contract Blocker {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Special index value indicating a NIL block (no real proposer)
    /// @dev NIL blocks occur when consensus cannot produce a block with transactions
    uint64 public constant NIL_PROPOSER_INDEX = type(uint64).max;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted at the start of each block
    /// @param blockHeight Current block number
    /// @param epoch Current epoch number
    /// @param proposer Resolved proposer address
    /// @param timestampMicros Block timestamp in microseconds
    event BlockStarted(uint256 indexed blockHeight, uint64 indexed epoch, address proposer, uint64 timestampMicros);

    /// @notice Emitted when a component update fails (non-fatal)
    /// @param component Address of the failed component
    /// @param reason Error reason bytes
    event ComponentUpdateFailed(address indexed component, bytes reason);

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the contract (genesis only)
    /// @dev Emits genesis block event with SYSTEM_CALLER as proposer
    function initialize() external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert AlreadyInitialized();
        }

        _initialized = true;

        // Initialize timestamp to 0 for genesis
        ITimestampWriter(SystemAddresses.TIMESTAMP).updateGlobalTime(SystemAddresses.SYSTEM_CALLER, 0);

        // Emit genesis block event
        emit BlockStarted(0, 0, SystemAddresses.SYSTEM_CALLER, 0);
    }

    // ========================================================================
    // BLOCK PROLOGUE
    // ========================================================================

    /// @notice Called by blockchain runtime at the start of each block
    /// @dev Performs the following in order:
    ///      1. Resolve proposer address from index (NIL block check)
    ///      2. Update global timestamp
    ///      3. Check and potentially start epoch transition
    ///      4. Emit BlockStarted event
    /// @param proposerIndex Index of the block proposer in the active validator set (NIL_PROPOSER_INDEX for NIL blocks)
    /// @param failedProposerIndices Indices of validators who failed to propose (unused for now)
    /// @param timestampMicros Block timestamp in microseconds
    function onBlockStart(
        uint64 proposerIndex,
        uint64[] calldata failedProposerIndices,
        uint64 timestampMicros
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Track proposal performance statistics (Aptos: stake::update_performance_statistics)
        // Performance scores must be updated before the epoch transition check,
        // as the transaction that triggers the transition is the last block in the previous epoch.
        IValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER)
            .updateStatistics(proposerIndex, failedProposerIndices);

        // 1. Resolve proposer address from index
        //    NIL blocks have proposerIndex == NIL_PROPOSER_INDEX (type(uint64).max)
        //    For NIL blocks, we use SYSTEM_CALLER as the proposer address
        address validatorAddress = _resolveProposer(proposerIndex);

        // 2. Update global timestamp
        //    - Normal blocks (validatorAddress != SYSTEM_CALLER): time must advance
        //    - NIL blocks (validatorAddress == SYSTEM_CALLER): time must stay the same
        ITimestampWriter(SystemAddresses.TIMESTAMP).updateGlobalTime(validatorAddress, timestampMicros);

        // 3. Check and potentially start epoch transition
        //    Reconfiguration handles all transition logic internally
        //    Returns true if DKG was started, but we don't need to act on this
        IReconfiguration(SystemAddresses.RECONFIGURATION).checkAndStartTransition();

        // 4. Get current epoch for event emission
        uint64 epoch = IReconfiguration(SystemAddresses.RECONFIGURATION).currentEpoch();

        // 5. Emit block started event
        emit BlockStarted(block.number, epoch, validatorAddress, timestampMicros);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Resolve proposer index to validator address (stake pool address)
    /// @dev NIL blocks have proposerIndex == NIL_PROPOSER_INDEX, which maps to SYSTEM_CALLER.
    ///      For valid indices, queries ValidatorManagement to get the stake pool address.
    ///      Follows Aptos pattern from block.move: proposer identified by index.
    /// @param proposerIndex Index of the proposer in the active validator set
    /// @return The resolved address (SYSTEM_CALLER for NIL blocks, stake pool address otherwise)
    function _resolveProposer(
        uint64 proposerIndex
    ) internal view returns (address) {
        if (proposerIndex == NIL_PROPOSER_INDEX) {
            // NIL block - no real proposer
            return SystemAddresses.SYSTEM_CALLER;
        }

        // Query ValidatorManagement for the validator at this index
        // Returns the stake pool address (validator identity)
        return
            IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorByIndex(proposerIndex).validator;
    }

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Contract has already been initialized
    error AlreadyInitialized();
}

