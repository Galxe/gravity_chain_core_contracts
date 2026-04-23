// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GravityPortal } from "src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title DeployBridge — Ethereum Mainnet Sender Ceremony
/// @notice One-shot deployment of the bridge sender (GravityPortal + GBridgeSender) to Ethereum mainnet.
///         This is the Ethereum-side counterpart to GBridgeReceiver on Gravity chain.
/// @dev Deployer EOA is set as temporary owner; ownership is immediately handed to
///      the multisig via Ownable2Step.transferOwnership(). The multisig must then
///      call acceptOwnership() on BOTH contracts to finalize the handover.
///
///      Required env vars:
///        PRIVATE_KEY         - deployer EOA private key (temporary owner)
///        MULTISIG_ADDRESS    - final owner (Safe multisig) for both contracts
///
///      Optional env vars:
///        FEE_RECIPIENT_ADDRESS - GravityPortal fee recipient (default: MULTISIG_ADDRESS)
///        INITIAL_BASE_FEE      - GravityPortal base fee in wei (default: 0.00001 ether)
///        INITIAL_FEE_PER_BYTE  - GravityPortal fee per byte in wei (default: 100 gwei)
///        ALLOW_NON_MAINNET     - set to "1" to bypass chainid check (fork tests only)
contract DeployBridge is Script {
    // ========================================================================
    // MAINNET CONSTANTS
    // ========================================================================

    /// @notice Gravity (G) ERC20 token on Ethereum mainnet (verified: name="Gravity", symbol="G", decimals=18)
    address constant G_TOKEN_MAINNET = 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649;

    /// @notice Ethereum mainnet chain id
    uint256 constant ETHEREUM_MAINNET_CHAINID = 1;

    /// @notice Default initial base fee for GravityPortal (owner can change later)
    uint256 constant DEFAULT_BASE_FEE = 0.00001 ether;

    /// @notice Default initial fee per byte for GravityPortal (owner can change later)
    uint256 constant DEFAULT_FEE_PER_BYTE = 100 gwei;

    // ========================================================================
    // RUN
    // ========================================================================

    function run() external {
        // --- Chain id guard ---
        bool allowNonMainnet;
        try vm.envString("ALLOW_NON_MAINNET") returns (string memory v) {
            allowNonMainnet = keccak256(bytes(v)) == keccak256(bytes("1"));
        } catch {
            allowNonMainnet = false;
        }
        if (!allowNonMainnet) {
            require(block.chainid == ETHEREUM_MAINNET_CHAINID, "Not Ethereum mainnet (set ALLOW_NON_MAINNET=1 for fork tests)");
        }

        // --- Resolve config ---
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address feeRecipient = _envAddressOr("FEE_RECIPIENT_ADDRESS", multisig);
        uint256 baseFee = _envUintOr("INITIAL_BASE_FEE", DEFAULT_BASE_FEE);
        uint256 feePerByte = _envUintOr("INITIAL_FEE_PER_BYTE", DEFAULT_FEE_PER_BYTE);

        // --- Validate ---
        require(multisig != address(0), "MULTISIG_ADDRESS not set");
        require(feeRecipient != address(0), "FEE_RECIPIENT_ADDRESS invalid");
        require(deployer != multisig, "Deployer and multisig must differ (multisig cannot broadcast)");

        // --- Pre-flight log ---
        console.log("=== Gravity Bridge Sender - Ethereum Mainnet Deployment ===");
        console.log("Chain id            :", block.chainid);
        console.log("Deployer (temp owner):", deployer);
        console.log("Multisig (final owner):", multisig);
        console.log("Fee recipient       :", feeRecipient);
        console.log("G token             :", G_TOKEN_MAINNET);
        console.log("Initial baseFee (wei)  :", baseFee);
        console.log("Initial feePerByte (wei):", feePerByte);
        console.log("Deployer balance (wei) :", deployer.balance);

        // --- Broadcast: 4 txs ---
        vm.startBroadcast(deployerPk);

        // 1. Deploy GravityPortal with EOA as temporary owner, multisig as feeRecipient.
        //    feeRecipient is safe to set to multisig now because it is NOT owner-gated to change.
        GravityPortal portal = new GravityPortal({
            initialOwner: deployer,
            initialBaseFee: baseFee,
            initialFeePerByte: feePerByte,
            initialFeeRecipient: feeRecipient
        });
        console.log("GravityPortal deployed:", address(portal));

        // 2. Hand off Portal ownership to multisig (pending; multisig must acceptOwnership).
        portal.transferOwnership(multisig);

        // 3. Deploy GBridgeSender wired to the freshly deployed Portal and the mainnet G token.
        GBridgeSender sender = new GBridgeSender({
            gToken_: G_TOKEN_MAINNET,
            gravityPortal_: address(portal),
            owner_: deployer
        });
        console.log("GBridgeSender deployed:", address(sender));

        // 4. Hand off Sender ownership to multisig.
        sender.transferOwnership(multisig);

        vm.stopBroadcast();

        // --- Post-deploy invariants ---
        require(portal.owner() == deployer, "Portal owner unexpectedly not deployer post-transfer");
        require(portal.pendingOwner() == multisig, "Portal pendingOwner != multisig");
        require(sender.owner() == deployer, "Sender owner unexpectedly not deployer post-transfer");
        require(sender.pendingOwner() == multisig, "Sender pendingOwner != multisig");
        require(sender.gToken() == G_TOKEN_MAINNET, "Sender gToken mismatch");
        require(sender.gravityPortal() == address(portal), "Sender portal mismatch");
        require(portal.feeRecipient() == feeRecipient, "Portal feeRecipient mismatch");

        // --- Summary ---
        console.log("\n=== Deployment Complete ===");
        console.log("GravityPortal :", address(portal));
        console.log("GBridgeSender :", address(sender));
        console.log("Both pendingOwner = multisig. Multisig must now call acceptOwnership() on each.");

        // --- JSON out ---
        vm.serializeAddress("deployment", "gravityPortal", address(portal));
        vm.serializeAddress("deployment", "gBridgeSender", address(sender));
        vm.serializeAddress("deployment", "multisig", multisig);
        vm.serializeAddress("deployment", "feeRecipient", feeRecipient);
        vm.serializeAddress("deployment", "gToken", G_TOKEN_MAINNET);
        vm.serializeUint("deployment", "chainId", block.chainid);
        string memory json = vm.serializeString("deployment", "network", "ethereum-mainnet");
        console.log("\nDeployment JSON:", json);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _envAddressOr(string memory key, address fallbackValue) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }

    function _envUintOr(string memory key, uint256 fallbackValue) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }
}
