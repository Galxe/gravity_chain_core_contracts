// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title INativeMintWrapper
/// @author Gravity Team
/// @notice Interface for the NativeMintWrapper contract
/// @dev Wraps the native mint precompile with multi-caller access control.
///      Only authorized minters can call mint(). The owner manages the minter list.
interface INativeMintWrapper {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new minter is authorized
    /// @param minter The address that was granted minting rights
    event MinterAdded(address indexed minter);

    /// @notice Emitted when a minter's authorization is revoked
    /// @param minter The address that lost minting rights
    event MinterRemoved(address indexed minter);

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Caller is not an authorized minter
    /// @param caller The unauthorized caller address
    error UnauthorizedMinter(address caller);

    /// @notice Caller is not the owner
    /// @param caller The unauthorized caller address
    error OnlyOwner(address caller);

    /// @notice Native token mint via precompile failed
    /// @param recipient The intended recipient
    /// @param amount The amount that failed to mint
    error MintFailed(address recipient, uint256 amount);

    // ========================================================================
    // MINTER MANAGEMENT
    // ========================================================================

    /// @notice Add an authorized minter
    /// @dev Only callable by the owner
    /// @param minter The address to authorize
    function addMinter(address minter) external;

    /// @notice Remove an authorized minter
    /// @dev Only callable by the owner
    /// @param minter The address to deauthorize
    function removeMinter(address minter) external;

    // ========================================================================
    // MINT
    // ========================================================================

    /// @notice Mint native tokens to a recipient
    /// @dev Only callable by authorized minters
    /// @param recipient The address to receive the tokens
    /// @param amount The amount to mint (in wei)
    function mint(address recipient, uint256 amount) external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check if an address is an authorized minter
    /// @param account The address to check
    /// @return True if the address is an authorized minter
    function isMinter(address account) external view returns (bool);

    /// @notice Get the owner address
    /// @return The owner address
    function owner() external view returns (address);
}
