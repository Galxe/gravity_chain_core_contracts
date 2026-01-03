// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title Timestamp
/// @author Gravity Team
/// @notice On-chain time oracle with microsecond precision
/// @dev Updated by Block contract during block prologue. Supports NIL blocks.
///      - Normal blocks (proposer != SYSTEM_CALLER): time must strictly advance
///      - NIL blocks (proposer == SYSTEM_CALLER): time must stay the same
contract Timestamp {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Conversion factor from seconds to microseconds
    uint64 public constant MICRO_CONVERSION_FACTOR = 1_000_000;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Current Unix timestamp in microseconds
    uint64 public microseconds;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when global time is updated
    /// @param proposer Block proposer address
    /// @param oldTimestamp Previous timestamp (microseconds)
    /// @param newTimestamp New timestamp (microseconds)
    event GlobalTimeUpdated(address indexed proposer, uint64 oldTimestamp, uint64 newTimestamp);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get current time in microseconds
    /// @return Current timestamp in microseconds
    function nowMicroseconds() external view returns (uint64) {
        return microseconds;
    }

    /// @notice Get current time in seconds (convenience helper)
    /// @return Current timestamp in seconds
    function nowSeconds() external view returns (uint64) {
        return microseconds / MICRO_CONVERSION_FACTOR;
    }

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @notice Update the global time
    /// @dev Only callable by BLOCK contract.
    ///      - Normal blocks: timestamp must strictly advance (timestamp > current)
    ///      - NIL blocks: timestamp must equal current (timestamp == current)
    /// @param proposer The block proposer address (SYSTEM_CALLER for NIL blocks)
    /// @param timestamp New timestamp in microseconds
    function updateGlobalTime(
        address proposer,
        uint64 timestamp
    ) external {
        requireAllowed(SystemAddresses.BLOCK);

        uint64 current = microseconds;

        if (proposer == SystemAddresses.SYSTEM_CALLER) {
            // NIL block: time must stay the same
            if (timestamp != current) {
                revert Errors.TimestampMustEqual(timestamp, current);
            }
        } else {
            // Normal block: time must advance
            if (timestamp <= current) {
                revert Errors.TimestampMustAdvance(timestamp, current);
            }
            microseconds = timestamp;
        }

        emit GlobalTimeUpdated(proposer, current, timestamp);
    }
}

