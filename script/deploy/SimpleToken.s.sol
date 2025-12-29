// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { SimpleToken } from "../../src/SimpleToken.sol";

/**
 * @title SimpleTokenDeploy
 * @dev Deployment script for SimpleToken on Tenderly Virtual TestNets
 * This script is optimized for CI/CD workflows with automatic verification
 */
contract SimpleTokenDeploy is Script {
    SimpleToken public token;

    function setUp() public { }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SimpleToken with demo parameters
        token = new SimpleToken(
            "Tenderly Demo Token", // name
            "TDT", // symbol
            18, // decimals
            1000000 // total supply (1M tokens)
        );

        console2.log("SimpleToken deployed to:", address(token));
        console2.log("Token name:", token.name());
        console2.log("Token symbol:", token.symbol());
        console2.log("Total supply:", token.totalSupply());
        console2.log("Deployer balance:", token.balanceOf(vm.addr(deployerPrivateKey)));

        vm.stopBroadcast();

        // Verification info for Tenderly
        console2.log("=== Deployment Summary ===");
        console2.log("Contract: SimpleToken");
        console2.log("Address:", address(token));
        console2.log("Chain ID:", block.chainid);
        console2.log("Block Number:", block.number);
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
    }
}
