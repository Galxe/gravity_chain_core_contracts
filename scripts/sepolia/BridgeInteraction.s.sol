// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { IGravityPortal } from "src/oracle/evm/IGravityPortal.sol";
import { IGBridgeSender } from "src/oracle/evm/native_token_bridge/IGBridgeSender.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { PortalMessage } from "src/oracle/evm/PortalMessage.sol";

/// @title BridgeInteraction
/// @notice Interactive script to test bridge functionality on Sepolia and capture MessageSent events
/// @dev Reads amount and recipient from environment variables
contract BridgeInteraction is Script {
    // Contract addresses (deployed on Sepolia at block 10195203)
    address constant GRAVITY_PORTAL = 0x60fD4D8fB846D95CcDB1B0b81c5fed1e8b183375;
    address constant G_BRIDGE_SENDER = 0x79226649b3A20231e6b468a9E1AbBD23d3DFbbC6;

    function run() external {
        // Load from environment
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        uint256 amount = vm.envUint("AMOUNT");
        address recipient = vm.envAddress("RECIPIENT");

        address user = vm.addr(privateKey);
        IGravityPortal portal = IGravityPortal(GRAVITY_PORTAL);
        IGBridgeSender sender = IGBridgeSender(G_BRIDGE_SENDER);
        IERC20 gToken = IERC20(sender.gToken());

        console.log("=== Bridge Interaction on Sepolia ===");
        console.log("User:", user);
        console.log("GravityPortal:", GRAVITY_PORTAL);
        console.log("GBridgeSender:", G_BRIDGE_SENDER);
        console.log("G Token:", sender.gToken());
        console.log("");

        // Check user's G token balance
        uint256 balanceBefore = gToken.balanceOf(user);
        console.log("User G Token balance:", balanceBefore / 1e18, "tokens");

        if (balanceBefore < amount) {
            console.log("");
            console.log("ERROR: Insufficient G Token balance!");
            console.log("Balance:", balanceBefore / 1e18, "tokens");
            console.log("Required:", amount / 1e18, "tokens");
            return;
        }

        console.log("");
        console.log("Bridge Parameters:");
        console.log("  Amount:", amount / 1e18, "tokens");
        console.log("  Recipient:", recipient);
        console.log("");

        vm.startBroadcast(privateKey);

        // 1. Approve GBridgeSender
        gToken.approve(G_BRIDGE_SENDER, amount);
        console.log("[Step 1] Approved GBridgeSender to spend", amount / 1e18, "tokens");

        // 2. Calculate fee
        uint256 fee = sender.calculateBridgeFee(amount, recipient);
        console.log("[Step 2] Required fee:", fee, "wei");
        console.log("[Step 2]               ", fee / 1e18, "ETH");
        console.log("");

        // 3. Record current block before bridge call
        uint256 blockBefore = block.number;

        // 4. Start recording logs to capture events
        vm.recordLogs();

        // 5. Call bridgeToGravity
        uint128 nonce = sender.bridgeToGravity{ value: fee }(amount, recipient);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Bridge Transaction Result ===");
        console.log("Nonce returned:", uint256(nonce));
        console.log("Portal nonce is now:", uint256(portal.nonce()));
        console.log("Transaction block:", blockBefore + 1);
        console.log("");

        // 6. Get recorded logs and parse MessageSent event
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console.log("=== Event Details ===");
        for (uint256 i = 0; i < logs.length; i++) {
            // event MessageSent(uint128 indexed nonce, uint256 indexed block_number, bytes payload);
            bytes32 messageSentSig = keccak256("MessageSent(uint128,uint256,bytes)");
            if (logs[i].topics[0] == messageSentSig) {
                console.log("Event: MessageSent");
                console.log("Contract:", logs[i].emitter);

                // topics[1] is the indexed nonce
                uint128 eventNonce = uint128(uint256(logs[i].topics[1]));
                console.log("Indexed Nonce:", uint256(eventNonce));

                // topics[2] is the indexed block_number
                uint256 eventBlockNumber = uint256(logs[i].topics[2]);
                console.log("Indexed Block Number:", eventBlockNumber);

                // Decode payload from event data
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                console.log("Payload Length:", payload.length, "bytes");

                // Decode PortalMessage content
                (address msgSender, uint128 msgNonce, bytes memory message) = PortalMessage.decode(payload);
                console.log("");
                console.log("=== Decoded PortalMessage ===");
                console.log("Sender:", msgSender);
                console.log("Message Nonce:", uint256(msgNonce));
                console.log("Message Length:", message.length, "bytes");

                // Decode bridge message (amount, recipient)
                (uint256 bridgeAmount, address bridgeRecipient) = abi.decode(message, (uint256, address));
                console.log("");
                console.log("=== Decoded Bridge Message ===");
                console.log("Bridge Amount:", bridgeAmount / 1e18, "G tokens");
                console.log("Bridge Amount (wei):", bridgeAmount);
                console.log("Recipient:", bridgeRecipient);

                // Display raw payload in hex
                console.log("");
                console.log("=== Raw Payload (hex) ===");
                console.logBytes(payload);

                break;
            }

            // Also capture TokensLocked event from GBridgeSender
            // event TokensLocked(address indexed from, address indexed recipient, uint256 amount, uint128 indexed nonce);
            bytes32 tokensLockedSig = keccak256("TokensLocked(address,address,uint256,uint128)");
            if (logs[i].topics[0] == tokensLockedSig) {
                console.log("");
                console.log("Event: TokensLocked");
                console.log("Contract:", logs[i].emitter);
                console.log("From:", address(uint160(uint256(logs[i].topics[1]))));
                console.log("Recipient:", address(uint160(uint256(logs[i].topics[2]))));

                // Extract amount from data (first 32 bytes)
                uint256 lockedAmount = abi.decode(logs[i].data, (uint256));
                // Extract nonce from topics[3] (indexed)
                uint128 lockedNonce = uint128(uint256(logs[i].topics[3]));

                console.log("Amount Locked:", lockedAmount / 1e18, "tokens");
                console.log("Nonce:", uint256(lockedNonce));
            }
        }

        console.log("");
        console.log("=== BRIDGE TRANSACTION COMPLETED ===");
        console.log("The MessageSent event was emitted.");
        console.log("Validators should monitor this event and reach consensus");
        console.log("to bridge the message to Gravity chain.");
    }
}
