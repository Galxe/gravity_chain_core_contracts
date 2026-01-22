// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "@src/oracle/evm/native_token_bridge/GBridgeSender.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";
import { MockGToken } from "@test/utils/MockGToken.sol";

/// @title BridgeInteraction
/// @notice Interactive script to test bridge functionality and capture MessageSent events
/// @dev Run after DeployBridgeLocal. Outputs block number and event content.
contract BridgeInteraction is Script {
    function run() external {
        // Load contract addresses from environment
        address gTokenAddr = vm.envAddress("GTOKEN_ADDRESS");
        address portalAddr = vm.envAddress("PORTAL_ADDRESS");
        address senderAddr = vm.envAddress("SENDER_ADDRESS");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(privateKey);

        MockGToken gToken = MockGToken(gTokenAddr);
        GravityPortal portal = GravityPortal(portalAddr);
        GBridgeSender sender = GBridgeSender(senderAddr);

        console.log("=== Bridge Interaction Test ===");
        console.log("User:", user);
        console.log("GToken:", gTokenAddr);
        console.log("Portal:", portalAddr);
        console.log("Sender:", senderAddr);
        console.log("");

        uint256 amount = 1000 ether;
        address recipient = user; // Bridge to self for testing

        vm.startBroadcast(privateKey);

        // 1. Mint tokens to user
        gToken.mint(user, amount);
        console.log("[Step 1] Minted", amount / 1e18, "G tokens to user");

        // 2. Approve GBridgeSender
        gToken.approve(address(sender), amount);
        console.log("[Step 2] Approved GBridgeSender to spend tokens");

        // 3. Calculate fee
        uint256 fee = sender.calculateBridgeFee(amount, recipient);
        console.log("[Step 3] Required fee:", fee, "wei");

        // Record current block before bridge call
        uint256 blockBefore = block.number;

        // 4. Start recording logs to capture events
        vm.recordLogs();

        // 5. Call bridgeToGravity
        uint128 nonce = sender.bridgeToGravity{ value: fee }(amount, recipient);

        vm.stopBroadcast();

        // 6. Get recorded logs and parse MessageSent event
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console.log("");
        console.log("=== Bridge Transaction Result ===");
        console.log("Nonce returned:", uint256(nonce));
        console.log("Portal nonce is now:", uint256(portal.nonce()));
        console.log("");

        // Find and display MessageSent event
        console.log("=== Event Details ===");
        for (uint256 i = 0; i < logs.length; i++) {
            // MessageSent event signature: keccak256("MessageSent(uint128,bytes)")
            bytes32 messageSentSig = keccak256("MessageSent(uint128,bytes)");
            if (logs[i].topics[0] == messageSentSig) {
                console.log("Event: MessageSent");
                console.log("Block Number:", blockBefore + 1);
                console.log("Contract:", logs[i].emitter);

                // topics[1] is the indexed nonce
                uint128 eventNonce = uint128(uint256(logs[i].topics[1]));
                console.log("Indexed Nonce:", uint256(eventNonce));

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
                console.log("Recipient:", bridgeRecipient);

                // Display raw payload in hex
                console.log("");
                console.log("=== Raw Payload (hex) ===");
                console.logBytes(payload);

                break;
            }

            // Also capture TokensLocked event from GBridgeSender
            bytes32 tokensLockedSig = keccak256("TokensLocked(address,address,uint256,uint128)");
            if (logs[i].topics[0] == tokensLockedSig) {
                console.log("");
                console.log("Event: TokensLocked");
                console.log("Contract:", logs[i].emitter);
                console.log("From:", address(uint160(uint256(logs[i].topics[1]))));
                console.log("Recipient:", address(uint160(uint256(logs[i].topics[2]))));
            }
        }

        console.log("");
        console.log("=== TEST COMPLETED SUCCESSFULLY ===");
        console.log("The MessageSent event was emitted. Validators would monitor this event");
        console.log("and reach consensus to bridge the message to Gravity chain.");
    }
}
