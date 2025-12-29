// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./Counter.sol";

/// @title CounterV2
/// @notice A counter contract with decrement functionality
contract CounterV2 is Counter {
    function decrement() public {
        uint256 currentValue = getCount();
        if (currentValue > 0) {
            _count -= 1;
        }
    }

    function version() public pure override returns (string memory) {
        return "v2.0.0";
    }
}
