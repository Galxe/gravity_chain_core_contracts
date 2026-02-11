// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title SystemAddresses
/// @author Gravity Team
/// @notice Compile-time constants for Gravity system addresses
/// @dev Import this library to get zero-cost address access (inlined by compiler).
///      Address ranges:
///        - 0x1625F0xxx: Consensus engine contracts/caller
///        - 0x1625F1xxx: Runtime configurations
///        - 0x1625F2xxx: Staking & validator
///        - 0x1625F3xxx: Governance
///        - 0x1625F4xxx: Oracle
///        - 0x1625F5xxx: Precompiles
///      Adding new addresses requires a hardfork.
library SystemAddresses {
    // ==================== Consensus Engine (0x1625F0xxx) ====================

    /// @notice VM/runtime system caller address
    /// @dev Used for block prologue, NIL blocks, and other system-initiated calls
    address internal constant SYSTEM_CALLER = address(0x0000000000000000000000000001625F0000);

    /// @notice Genesis initialization contract
    /// @dev Only active during chain initialization
    address internal constant GENESIS = address(0x0000000000000000000000000001625F0001);

    // ==================== Runtime Configurations (0x1625F1xxx) ====================

    /// @notice On-chain timestamp oracle
    /// @dev Provides microsecond-precision time, updated in block prologue
    address internal constant TIMESTAMP = address(0x0000000000000000000000000001625F1000);

    /// @notice Staking configuration contract
    /// @dev Stores staking parameters (lockup duration, minimum stake, etc.)
    address internal constant STAKE_CONFIG = address(0x0000000000000000000000000001625F1001);

    /// @notice Validator configuration contract
    /// @dev Stores validator parameters (minimum/maximum bond, unbonding delay, etc.)
    address internal constant VALIDATOR_CONFIG = address(0x0000000000000000000000000001625F1002);

    /// @notice Randomness configuration contract
    /// @dev Stores DKG threshold parameters for on-chain randomness
    address internal constant RANDOMNESS_CONFIG = address(0x0000000000000000000000000001625F1003);

    /// @notice Governance configuration contract
    /// @dev Stores governance parameters (voting threshold, proposal stake, etc.)
    address internal constant GOVERNANCE_CONFIG = address(0x0000000000000000000000000001625F1004);

    /// @notice Epoch configuration contract
    /// @dev Stores epoch interval duration
    address internal constant EPOCH_CONFIG = address(0x0000000000000000000000000001625F1005);

    /// @notice Version configuration contract
    /// @dev Stores protocol major version (monotonically increasing)
    address internal constant VERSION_CONFIG = address(0x0000000000000000000000000001625F1006);

    /// @notice Consensus configuration contract
    /// @dev Stores consensus parameters as opaque bytes (BCS-serialized)
    address internal constant CONSENSUS_CONFIG = address(0x0000000000000000000000000001625F1007);

    /// @notice Execution configuration contract
    /// @dev Stores VM execution parameters as opaque bytes (BCS-serialized)
    address internal constant EXECUTION_CONFIG = address(0x0000000000000000000000000001625F1008);

    /// @notice Oracle task configuration contract
    /// @dev Stores configuration for continuous oracle tasks that validators monitor
    address internal constant ORACLE_TASK_CONFIG = address(0x0000000000000000000000000001625F1009);

    /// @notice On-demand oracle task configuration contract
    /// @dev Defines which on-demand request types the consensus engine supports
    address internal constant ON_DEMAND_ORACLE_TASK_CONFIG = address(0x0000000000000000000000000001625F100A);

    // ==================== Staking & Validator (0x1625F2xxx) ====================

    /// @notice Governance staking contract
    /// @dev Anyone can stake tokens to participate in governance voting
    address internal constant STAKING = address(0x0000000000000000000000000001625F2000);

    /// @notice Validator set management contract
    /// @dev Manages validator registration, bonding, and set transitions
    address internal constant VALIDATOR_MANAGER = address(0x0000000000000000000000000001625F2001);

    /// @notice DKG (Distributed Key Generation) contract
    /// @dev Manages DKG session lifecycle for epoch transitions
    address internal constant DKG = address(0x0000000000000000000000000001625F2002);

    /// @notice Reconfiguration contract
    /// @dev Handles epoch transitions and reconfiguration
    address internal constant RECONFIGURATION = address(0x0000000000000000000000000001625F2003);

    /// @notice Block prologue/epilogue handler
    /// @dev Called by VM at start/end of each block
    address internal constant BLOCK = address(0x0000000000000000000000000001625F2004);

    /// @notice Validator performance tracker
    /// @dev Tracks successful/failed proposals per validator per epoch (Aptos: ValidatorPerformance)
    address internal constant PERFORMANCE_TRACKER = address(0x0000000000000000000000000001625F2005);

    // ==================== Governance (0x1625F3xxx) ====================

    /// @notice Governance contract
    /// @dev Handles proposals, voting, and execution of governance decisions
    address internal constant GOVERNANCE = address(0x0000000000000000000000000001625F3000);

    // ==================== Oracle (0x1625F4xxx) ====================

    /// @notice Native Oracle contract
    /// @dev Stores verified data from external sources (blockchains, JWK providers, DNS).
    ///      Supports hash-only mode (storage-efficient) and data mode (direct access).
    ///      Data is recorded by consensus engine via SYSTEM_CALLER.
    address internal constant NATIVE_ORACLE = address(0x0000000000000000000000000001625F4000);

    /// @notice JWK (JSON Web Key) manager
    /// @dev Manages JWKs for keyless account authentication
    address internal constant JWK_MANAGER = address(0x0000000000000000000000000001625F4001);

    /// @notice Oracle request queue contract
    /// @dev Accepts user-initiated on-demand oracle requests with fee payment
    address internal constant ORACLE_REQUEST_QUEUE = address(0x0000000000000000000000000001625F4002);

    // ==================== Precompiles (0x1625F5xxx) ====================

    /// @notice Native mint precompile
    /// @dev Callable by authorized system contracts to mint native G tokens
    address internal constant NATIVE_MINT_PRECOMPILE = address(0x0000000000000000000000000001625F5000);
}
