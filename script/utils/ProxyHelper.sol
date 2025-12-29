// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Vm.sol";

/**
 * @title ProxyHelper
 * @notice Utility library to simplify proxy contract storage slot access
 * @dev Compatible with OpenZeppelin ERC1967 proxy contracts
 */
library ProxyHelper {
    // ERC1967 implementation slot location
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ERC1967 admin slot location
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Vm instance
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /**
     * @notice Get proxy contract implementation address (read directly from storage slot)
     * @param proxy Proxy contract address
     * @return implementationAddress Implementation contract address
     */
    function getProxyImplementation(
        address proxy
    ) internal view returns (address implementationAddress) {
        // Use vm.load to read directly from proxy contract storage slot
        bytes32 value = vm.load(proxy, IMPLEMENTATION_SLOT);
        implementationAddress = address(uint160(uint256(value)));
    }

    /**
     * @notice Get proxy contract admin address (read directly from storage slot)
     * @param proxy Proxy contract address
     * @return adminAddress Admin address
     */
    function getProxyAdmin(
        address proxy
    ) internal view returns (address adminAddress) {
        // Use vm.load to read directly from proxy contract storage slot
        bytes32 value = vm.load(proxy, ADMIN_SLOT);
        adminAddress = address(uint160(uint256(value)));
    }
}
