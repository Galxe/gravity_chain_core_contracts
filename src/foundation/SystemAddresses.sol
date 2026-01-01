// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title SystemAddresses
/// @author Gravity Team
/// @notice Compile-time constants for Gravity system addresses
/// @dev Import this library to get zero-cost address access (inlined by compiler).
///      All addresses use the 0x1625F2xxx pattern reserved at genesis.
///      Adding new addresses requires a hardfork.
library SystemAddresses {
    /// @notice VM/runtime system caller address
    /// @dev Used for block prologue, NIL blocks, and other system-initiated calls
    address internal constant SYSTEM_CALLER = address(0x0000000000000000000000000001625F2000);

    /// @notice Genesis initialization contract
    /// @dev Only active during chain initialization
    address internal constant GENESIS = address(0x0000000000000000000000000001625F2008);

    /// @notice Epoch lifecycle manager
    /// @dev Handles epoch transitions and reconfiguration
    address internal constant EPOCH_MANAGER = address(0x0000000000000000000000000001625F2010);

    /// @notice Staking configuration contract
    /// @dev Stores staking parameters (lockup duration, minimum stake, etc.)
    address internal constant STAKE_CONFIG = address(0x0000000000000000000000000001625F2011);

    /// @notice Validator set management contract
    /// @dev Manages validator registration, bonding, and set transitions
    address internal constant VALIDATOR_MANAGER = address(0x0000000000000000000000000001625F2013);

    /// @notice Block prologue/epilogue handler
    /// @dev Called by VM at start/end of each block
    address internal constant BLOCK = address(0x0000000000000000000000000001625F2016);

    /// @notice On-chain timestamp oracle
    /// @dev Provides microsecond-precision time, updated in block prologue
    address internal constant TIMESTAMP = address(0x0000000000000000000000000001625F2017);

    /// @notice JWK (JSON Web Key) manager
    /// @dev Manages JWKs for keyless account authentication
    address internal constant JWK_MANAGER = address(0x0000000000000000000000000001625F2018);

    /// @notice Timelock controller for governance
    /// @dev Enforces time delays on governance proposals
    address internal constant TIMELOCK = address(0x0000000000000000000000000001625F201F);

    /// @notice Hash oracle contract
    /// @dev Provides hash verification services
    address internal constant HASH_ORACLE = address(0x0000000000000000000000000001625F2023);
}

