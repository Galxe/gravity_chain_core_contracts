// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

contract FeeOnTransferToken is ERC20 {
    uint256 private constant FEE_BPS = 100;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    bool public feeEnabled = true;

    constructor() ERC20("Fee Token", "FEE") { }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setFeeEnabled(
        bool enabled
    ) external {
        feeEnabled = enabled;
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (!feeEnabled || from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount * FEE_BPS / BPS_DENOMINATOR;
        super._update(from, address(0), fee);
        super._update(from, to, amount - fee);
    }
}
