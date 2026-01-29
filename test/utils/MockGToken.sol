// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

/// @title MockGToken
/// @notice Mock G Token for testing bridge functionality on local testnet
/// @dev ERC20 with public mint function and ERC20Permit for gasless approvals
contract MockGToken is ERC20, ERC20Permit {
    constructor() ERC20("Mock G Token", "G") ERC20Permit("Mock G Token") { }

    /// @notice Mint tokens to any address (for testing only)
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}
