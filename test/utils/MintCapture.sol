// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Captures calls made to NATIVE_MINT_PRECOMPILE so tests can
///         assert the receiver handed the right (recipient, amount) to it.
/// @dev Receiver calls the precompile with packed calldata:
///        uint8(0x01) || recipient (20B) || amount (32B) = 53 bytes.
///      We decode that manually in a fallback to avoid needing a selector.
contract MintCapture {
    struct Call {
        uint8 op;
        address recipient;
        uint256 amount;
    }

    Call[] public calls;
    bool public shouldRevert;

    function setShouldRevert(
        bool v
    ) external {
        shouldRevert = v;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function lastCall() external view returns (Call memory) {
        require(calls.length > 0, "MintCapture: no calls");
        return calls[calls.length - 1];
    }

    fallback() external {
        if (shouldRevert) revert("mint failed");
        require(msg.data.length == 53, "MintCapture: unexpected calldata length");

        uint8 op = uint8(msg.data[0]);
        address recipient;
        uint256 amount;
        assembly {
            recipient := shr(96, calldataload(1))
            amount := calldataload(21)
        }
        calls.push(Call({ op: op, recipient: recipient, amount: amount }));
    }
}
