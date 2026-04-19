// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MockGToken } from "test/utils/MockGToken.sol";

/// @title SetupEthereumTestnet
/// @notice Deploys MockGToken on the Ethereum-side anvil so the mainnet
///         deploy script has a valid ERC-20 at G_TOKEN_ADDRESS.
///
/// @dev    Mints 1_000_000 G to the deployer for downstream tests.
///         Writes `deployments/testnet_ethereum.json` with the token address.
contract SetupEthereumTestnet is Script {
    function run() external returns (address token) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console.log("=========================================================");
        console.log("    Ethereum-side Testnet Setup (MockGToken)             ");
        console.log("=========================================================");
        console.log("chainId   :", block.chainid);
        console.log("deployer  :", deployer);

        vm.startBroadcast(deployerPk);
        MockGToken g = new MockGToken();
        g.mint(deployer, 1_000_000 ether);
        vm.stopBroadcast();

        token = address(g);

        require(token.code.length > 0, "MockGToken has no code after deploy");
        require(g.balanceOf(deployer) == 1_000_000 ether, "MockGToken: mint mismatch");

        console.log("MockGToken :", token);

        string memory obj = "ethereum";
        vm.serializeUint(obj, "chainId", block.chainid);
        string memory json = vm.serializeAddress(obj, "gToken", token);
        vm.writeJson(json, "./deployments/testnet_ethereum.json");
        console.log("Artifact written: deployments/testnet_ethereum.json");
    }
}
