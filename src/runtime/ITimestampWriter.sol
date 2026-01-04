// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ITimestampWriter
/// @author Gravity Team
/// @notice Write interface for Timestamp contract
/// @dev Used by Blocker contract to update global time during block prologue
interface ITimestampWriter {
    /// @notice Update the global time
    /// @dev Only callable by BLOCK contract.
    ///      - Normal blocks: timestamp must strictly advance (timestamp > current)
    ///      - NIL blocks: timestamp must equal current (timestamp == current)
    /// @param proposer The block proposer address (SYSTEM_CALLER for NIL blocks)
    /// @param timestamp New timestamp in microseconds
    function updateGlobalTime(
        address proposer,
        uint64 timestamp
    ) external;
}

