// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title DeployGBridgeSender
/// @notice Deployment script for GBridgeSender contract on Sepolia
/// @notice Run this after deploying GravityPortal and G Token contract
contract DeployGBridgeSender is Script {
    // ========================================================================
    // CONFIGURATION
    // ========================================================================

    /// @notice G Token contract address (set via environment variable or manually edit here)
    address constant G_TOKEN = address(0);

    /// @notice GravityPortal contract address (set via environment variable or manually edit here)
    address constant GRAVITY_PORTAL = address(0);

    /// @notice Owner address (set via environment variable or manually edit here)
    address constant OWNER = address(0);

    // ========================================================================
    // RUN SCRIPT
    // ========================================================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Override config with environment variables if provided
        address gToken = _getConfiguredGToken();
        address gravityPortal = _getConfiguredGravityPortal();
        address owner = _getConfiguredOwner();

        // Validate config
        require(gToken != address(0), "G Token address not configured");
        require(gravityPortal != address(0), "GravityPortal address not configured");
        require(owner != address(0), "Owner address not configured");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying GBridgeSender to Sepolia ===");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Owner:", owner);
        console.log("G Token:", gToken);
        console.log("GravityPortal:", gravityPortal);

        // Deploy GBridgeSender
        GBridgeSender gBridgeSender = new GBridgeSender({
            gToken_: gToken,
            gravityPortal_: gravityPortal,
            owner_: owner
        });

        vm.stopBroadcast();

        console.log("\nGBridgeSender deployed at:", address(gBridgeSender));

        // Output JSON for verification
        vm.serializeBool("deployment", "success", true);
        vm.serializeAddress("deployment", "gBridgeSender", address(gBridgeSender));
        string memory json = vm.serializeString("deployment", "network", "sepolia");
        console.log("\nDeployment JSON:", json);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Get configured G Token address from env or constant
    function _getConfiguredGToken() internal view returns (address) {
        try vm.envAddress("G_TOKEN_ADDRESS") returns (address token) {
            return token;
        } catch {
            return G_TOKEN;
        }
    }

    /// @notice Get configured GravityPortal address from env or constant
    function _getConfiguredGravityPortal() internal view returns (address) {
        try vm.envAddress("GRAVITY_PORTAL_ADDRESS") returns (address portal) {
            return portal;
        } catch {
            return GRAVITY_PORTAL;
        }
    }

    /// @notice Get configured owner address from env or constant
    function _getConfiguredOwner() internal view returns (address) {
        try vm.envAddress("OWNER_ADDRESS") returns (address owner) {
            return owner;
        } catch {
            return OWNER;
        }
    }
}
