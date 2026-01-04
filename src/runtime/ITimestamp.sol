// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ITimestamp
/// @author Gravity Team
/// @notice Read-only interface for Timestamp contract
/// @dev Used by contracts that need to read current time (e.g., DKG, Governance)
interface ITimestamp {
    /// @notice Get current time in microseconds
    /// @return Current timestamp in microseconds
    function nowMicroseconds() external view returns (uint64);

    /// @notice Get current time in seconds (convenience helper)
    /// @return Current timestamp in seconds
    function nowSeconds() external view returns (uint64);

    /// @notice Conversion factor from seconds to microseconds
    function MICRO_CONVERSION_FACTOR() external view returns (uint64);
}

