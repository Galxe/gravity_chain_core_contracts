// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";

/// @notice Interface for Timestamp contract
interface ITimestampBlocker {
    function updateGlobalTime(
        address proposer,
        uint64 timestamp
    ) external;
}

/// @notice Interface for Reconfiguration contract
interface IReconfigurationBlocker {
    function checkAndStartTransition() external returns (bool);
    function currentEpoch() external view returns (uint64);
}

/// @title Blocker
/// @author Gravity Team
/// @notice Block prologue entry point for the Gravity blockchain
/// @dev Called by VM runtime at the start of each block to update on-chain state.
///      Coordinates timestamp updates and epoch transition checks.
contract Blocker {
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
        ITimestampBlocker(SystemAddresses.TIMESTAMP).updateGlobalTime(SystemAddresses.SYSTEM_CALLER, 0);

        // Emit genesis block event
        emit BlockStarted(0, 0, SystemAddresses.SYSTEM_CALLER, 0);
    }

    // ========================================================================
    // BLOCK PROLOGUE
    // ========================================================================

    /// @notice Called by blockchain runtime at the start of each block
    /// @dev Performs the following in order:
    ///      1. Resolve proposer address (NIL block check)
    ///      2. Update global timestamp
    ///      3. Check and potentially start epoch transition
    ///      4. Emit BlockStarted event
    /// @param proposer The block proposer's consensus public key (32 bytes, bytes32(0) for NIL blocks)
    /// @param failedProposers Consensus pubkeys of validators who failed to propose (unused for now)
    /// @param timestampMicros Block timestamp in microseconds
    function onBlockStart(
        bytes32 proposer,
        bytes32[] calldata failedProposers,
        uint64 timestampMicros
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        // Silence unused variable warning - failedProposers will be used when ValidatorPerformanceTracker is implemented
        failedProposers;

        // 1. Resolve proposer address
        //    NIL blocks (no real proposer) have proposer == bytes32(0)
        //    For NIL blocks, we use SYSTEM_CALLER as the proposer address
        address validatorAddress = _resolveProposer(proposer);

        // 2. Update global timestamp
        //    - Normal blocks (validatorAddress != SYSTEM_CALLER): time must advance
        //    - NIL blocks (validatorAddress == SYSTEM_CALLER): time must stay the same
        ITimestampBlocker(SystemAddresses.TIMESTAMP).updateGlobalTime(validatorAddress, timestampMicros);

        // 3. Check and potentially start epoch transition
        //    Reconfiguration handles all transition logic internally
        //    Returns true if DKG was started, but we don't need to act on this
        IReconfigurationBlocker(SystemAddresses.EPOCH_MANAGER).checkAndStartTransition();

        // 4. Get current epoch for event emission
        uint64 epoch = IReconfigurationBlocker(SystemAddresses.EPOCH_MANAGER).currentEpoch();

        // 5. Emit block started event
        emit BlockStarted(block.number, epoch, validatorAddress, timestampMicros);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Resolve proposer consensus key to validator address
    /// @dev NIL blocks have proposer == bytes32(0), which maps to SYSTEM_CALLER
    /// @param proposer The proposer's consensus public key
    /// @return The resolved address (SYSTEM_CALLER for NIL blocks)
    function _resolveProposer(
        bytes32 proposer
    ) internal pure returns (address) {
        if (proposer == bytes32(0)) {
            // NIL block - no real proposer
            return SystemAddresses.SYSTEM_CALLER;
        }

        // For non-NIL blocks, we could look up the validator by consensus key
        // via ValidatorManagement.getValidatorByConsensusAddress(proposer)
        // For now, we convert the proposer key to an address directly
        // This is a placeholder - in production, this should query ValidatorManagement
        return address(uint160(uint256(proposer)));
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

