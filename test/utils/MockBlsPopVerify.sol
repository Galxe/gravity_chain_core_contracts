// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Mock BLS PoP verification precompile for testing
/// @dev Always returns success (uint256(1)) for any input.
///      Deploy at SystemAddresses.BLS_POP_VERIFY_PRECOMPILE via vm.etch().
contract MockBlsPopVerify {
    fallback() external {
        // Return ABI-encoded uint256(1) — matches real precompile "valid" output
        bytes memory result = abi.encode(uint256(1));
        assembly {
            return(add(result, 32), 32)
        }
    }
}
