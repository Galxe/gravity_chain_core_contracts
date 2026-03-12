// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeMintWrapper } from "./INativeMintWrapper.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { Errors } from "@src/foundation/Errors.sol";
import { requireAllowed } from "@src/foundation/SystemAccessControl.sol";

/// @title NativeMintWrapper
/// @author Gravity Team
/// @notice Wraps the native mint precompile with multi-caller access control
/// @dev Deployed at a fixed system address (0x1625F4003). Only authorized minters
///      can call mint(). The Genesis contract initializes owner and initial minters.
///      This contract is the sole AUTHORIZED_CALLER in reth's mint precompile,
///      allowing multiple contracts (e.g., bridge receivers) to mint through it.
contract NativeMintWrapper is INativeMintWrapper {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Owner who can manage the minter list
    address private _owner;

    /// @notice Authorized minters
    mapping(address => bool) private _minters;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    modifier onlyOwner() {
        if (msg.sender != _owner) {
            revert OnlyOwner(msg.sender);
        }
        _;
    }

    modifier onlyMinter() {
        if (!_minters[msg.sender]) {
            revert UnauthorizedMinter(msg.sender);
        }
        _;
    }

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the wrapper with owner and initial minters
    /// @dev Called by Genesis during chain initialization. Can only be called once.
    ///      Constructor is not used because system contracts are deployed via
    ///      bytecode injection (BSC-style), not via CREATE.
    /// @param owner_ The owner address (manages minter list)
    /// @param initialMinters The initial set of authorized minters
    function initialize(
        address owner_,
        address[] calldata initialMinters
    ) external {
        requireAllowed(SystemAddresses.GENESIS);
        if (_initialized) revert Errors.AlreadyInitialized();
        if (owner_ == address(0)) revert Errors.ZeroAddress();

        _owner = owner_;
        _initialized = true;

        for (uint256 i = 0; i < initialMinters.length; i++) {
            if (initialMinters[i] == address(0)) revert Errors.ZeroAddress();
            _minters[initialMinters[i]] = true;
            emit MinterAdded(initialMinters[i]);
        }
    }

    // ========================================================================
    // MINTER MANAGEMENT
    // ========================================================================

    /// @inheritdoc INativeMintWrapper
    function addMinter(
        address minter
    ) external onlyOwner {
        if (minter == address(0)) revert Errors.ZeroAddress();
        _minters[minter] = true;
        emit MinterAdded(minter);
    }

    /// @inheritdoc INativeMintWrapper
    function removeMinter(
        address minter
    ) external onlyOwner {
        _minters[minter] = false;
        emit MinterRemoved(minter);
    }

    // ========================================================================
    // MINT
    // ========================================================================

    /// @inheritdoc INativeMintWrapper
    function mint(
        address recipient,
        uint256 amount
    ) external onlyMinter {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();

        bytes memory callData = abi.encodePacked(uint8(0x01), recipient, amount);
        (bool success,) = SystemAddresses.NATIVE_MINT_PRECOMPILE.call(callData);
        if (!success) {
            revert MintFailed(recipient, amount);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc INativeMintWrapper
    function isMinter(
        address account
    ) external view returns (bool) {
        return _minters[account];
    }

    /// @inheritdoc INativeMintWrapper
    function owner() external view returns (address) {
        return _owner;
    }
}
