// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GravityPortal } from "src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title DeployBridge
/// @notice Deployment script for GravityPortal and GBridgeSender contracts on Sepolia
contract DeployBridge is Script {
    // ========================================================================
    // CONFIGURATION
    // ========================================================================

    /// @notice Owner address (set via environment variable or manually edit here)
    address constant OWNER = address(0);

    /// @notice G Token contract address (set after deployment or manually edit)
    address constant G_TOKEN = address(0);

    /// @notice Initial base fee: 0.00001 ETH = 10 gwei
    uint256 constant INITIAL_BASE_FEE = 0.00001 ether;

    /// @notice Initial fee per byte: 100 gwei
    uint256 constant INITIAL_FEE_PER_BYTE = 100 gwei;

    /// @notice Fee recipient address (set via environment variable or manually edit here)
    address constant FEE_RECIPIENT = address(0);

    // ========================================================================
    // RUN SCRIPT
    // ========================================================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Override config with environment variables if provided
        address owner = _getConfiguredOwner();
        address feeRecipient = _getConfiguredFeeRecipient();
        address gToken = _getConfiguredGToken();

        // Validate config
        require(owner != address(0), "Owner address not configured");
        require(feeRecipient != address(0), "Fee recipient address not configured");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying Bridge Contracts to Sepolia ===");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Owner:", owner);
        console.log("Fee Recipient:", feeRecipient);
        if (gToken == address(0)) {
            console.log("G Token: Not set - will skip GBridgeSender");
        } else {
            console.log("G Token:", gToken);
        }
        console.log("Base Fee:", INITIAL_BASE_FEE / 1e9, "gwei");
        console.log("Fee Per Byte:", INITIAL_FEE_PER_BYTE / 1e9, "gwei");

        // Deploy GravityPortal
        console.log("\n1. Deploying GravityPortal...");
        GravityPortal gravityPortal = new GravityPortal({
            initialOwner: owner,
            initialBaseFee: INITIAL_BASE_FEE,
            initialFeePerByte: INITIAL_FEE_PER_BYTE,
            initialFeeRecipient: feeRecipient
        });
        console.log("GravityPortal deployed at:", address(gravityPortal));

        // Deploy GBridgeSender (only if G Token is set)
        GBridgeSender gBridgeSender;
        if (gToken != address(0)) {
            console.log("\n2. Deploying GBridgeSender...");
            gBridgeSender = new GBridgeSender({
                gToken_: gToken,
                gravityPortal_: address(gravityPortal),
                owner_: owner
            });
            console.log("GBridgeSender deployed at:", address(gBridgeSender));
        } else {
            console.log("\n2. Skipping GBridgeSender deployment (G Token not set)");
            console.log("   Deploy GBridgeSender separately using DeployGBridgeSender script");
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("GravityPortal:", address(gravityPortal));
        if (gToken != address(0)) {
            console.log("GBridgeSender:", address(gBridgeSender));
        }

        // Output JSON for verification
        vm.serializeBool("deployment", "success", true);
        vm.serializeAddress("deployment", "gravityPortal", address(gravityPortal));
        if (gToken != address(0)) {
            vm.serializeAddress("deployment", "gBridgeSender", address(gBridgeSender));
        }
        string memory json = vm.serializeString("deployment", "network", "sepolia");
        console.log("\nDeployment JSON:", json);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Get configured owner address from env or constant
    function _getConfiguredOwner() internal view returns (address) {
        try vm.envAddress("OWNER_ADDRESS") returns (address owner) {
            return owner;
        } catch {
            return OWNER;
        }
    }

    /// @notice Get configured fee recipient address from env or constant
    function _getConfiguredFeeRecipient() internal view returns (address) {
        try vm.envAddress("FEE_RECIPIENT_ADDRESS") returns (address recipient) {
            return recipient;
        } catch {
            return FEE_RECIPIENT;
        }
    }

    /// @notice Get configured G Token address from env or constant
    function _getConfiguredGToken() internal view returns (address) {
        try vm.envAddress("G_TOKEN_ADDRESS") returns (address token) {
            return token;
        } catch {
            return G_TOKEN;
        }
    }
}
