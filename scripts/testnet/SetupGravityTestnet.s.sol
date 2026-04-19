// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GBridgeReceiver } from "src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";

/// @title SetupGravityTestnet
/// @notice Deploys GBridgeReceiver on a local Gravity-shaped anvil node
///         so that verify_deployment.sh can exercise the Gravity-side
///         verification against a fully populated chain.
///
/// @dev    Inputs (env):
///           GBRIDGE_SENDER_ADDRESS   — address of GBridgeSender that was just
///                                      deployed on the Ethereum-side anvil.
///                                      Becomes `trustedBridge` immutable.
///           TRUSTED_SOURCE_CHAIN_ID  — chainId of the Ethereum-side anvil
///                                      (default 1 — we run the Ethereum
///                                      anvil with --chain-id 1 to mimic
///                                      mainnet).
///           DEPLOYER_PRIVATE_KEY     — any anvil default key is fine; the
///                                      receiver is ownerless.
///
///         Output: `deployments/testnet_gravity.json`
///           { "chainId": ..., "gBridgeReceiver": 0x..., "trustedBridge": 0x..., "trustedSourceId": ... }
contract SetupGravityTestnet is Script {
    function run() external returns (address receiverAddr) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address trustedBridge = vm.envAddress("GBRIDGE_SENDER_ADDRESS");
        uint256 trustedSourceId = _envUintOr("TRUSTED_SOURCE_CHAIN_ID", 1);

        require(trustedBridge != address(0), "SetupGravityTestnet: GBRIDGE_SENDER_ADDRESS unset");

        console.log("=========================================================");
        console.log("     Gravity-side Testnet Setup (GBridgeReceiver)        ");
        console.log("=========================================================");
        console.log("Gravity chainId      :", block.chainid);
        console.log("trustedBridge        :", trustedBridge);
        console.log("trustedSourceId      :", trustedSourceId);
        console.log("=========================================================");

        vm.startBroadcast(deployerPk);
        GBridgeReceiver receiver = new GBridgeReceiver(trustedBridge, trustedSourceId);
        vm.stopBroadcast();

        receiverAddr = address(receiver);

        require(receiver.trustedBridge() == trustedBridge, "Receiver: trustedBridge mismatch");
        require(receiver.trustedSourceId() == trustedSourceId, "Receiver: trustedSourceId mismatch");

        console.log("GBridgeReceiver      :", receiverAddr);

        string memory obj = "receiver";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "gBridgeReceiver", receiverAddr);
        vm.serializeAddress(obj, "trustedBridge", trustedBridge);
        string memory json = vm.serializeUint(obj, "trustedSourceId", trustedSourceId);
        vm.writeJson(json, "./deployments/testnet_gravity.json");
        console.log("Artifact written: deployments/testnet_gravity.json");
    }

    function _envUintOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallback_;
        }
    }
}
