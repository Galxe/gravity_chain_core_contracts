// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "@src/oracle/evm/native_token_bridge/GBridgeSender.sol";
import { MockGToken } from "@test/utils/MockGToken.sol";

/// @title DeployBridgeLocal
/// @notice Deploys MockGToken, GravityPortal, and GBridgeSender on local Anvil testnet
/// @dev Run with: forge script script/DeployBridgeLocal.s.sol:DeployBridgeLocal --rpc-url http://localhost:8545 --broadcast
contract DeployBridgeLocal is Script {
    uint256 public constant BASE_FEE = 0.001 ether;
    uint256 public constant FEE_PER_BYTE = 100;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Bridge Contracts ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock G Token
        MockGToken gToken = new MockGToken();
        console.log("MockGToken deployed at:", address(gToken));

        // 2. Deploy GravityPortal
        GravityPortal portal = new GravityPortal(deployer, BASE_FEE, FEE_PER_BYTE, deployer);
        console.log("GravityPortal deployed at:", address(portal));

        // 3. Deploy GBridgeSender
        GBridgeSender sender = new GBridgeSender(address(gToken), address(portal), deployer);
        console.log("GBridgeSender deployed at:", address(sender));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
    }
}
