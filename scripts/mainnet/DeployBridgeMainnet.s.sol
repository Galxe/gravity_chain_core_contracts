// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GravityPortal } from "src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title DeployBridgeMainnet
/// @notice Deploys GravityPortal + GBridgeSender to Ethereum mainnet (chainId 1).
/// @dev    Single-EOA deployment. The EOA is the deployer, the Portal owner,
///         the Portal feeRecipient, and the Sender owner. All three roles
///         are a parameter: GRAVITY_CORE_CONTRACT_EOA_OWNER (its private key
///         is supplied separately as a secret env var).
///
///         Fee math (see §3 below):
///           feePerByte_wei = USD_CENTS_PER_32_BYTES * 1e16 / (32 * ETH_PRICE_USD)
///           baseFee_wei    = BASE_FEE_WEI (default 0)
///
///         At defaults (ETH=$2500, $0.10 / 32 bytes) this yields
///         feePerByte = 1.25e12 wei (~0.00125 gwei-millionths per byte).
///         A 64-byte user message (payload = 100 B) costs 1.25e14 wei ≈ $0.3125.
contract DeployBridgeMainnet is Script {
    // ========================================================================
    // 1. HARD-CODED DEFAULTS (override via env)
    // ========================================================================

    /// @notice Ethereum mainnet chain id. Script aborts on any other chain.
    uint256 internal constant MAINNET_CHAIN_ID = 1;

    /// @notice Canonical G ERC-20 on Ethereum mainnet (18 decimals).
    address internal constant DEFAULT_G_TOKEN = 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649;

    /// @notice Default ETH price in whole USD used for fee calibration.
    uint256 internal constant DEFAULT_ETH_PRICE_USD = 2500;

    /// @notice Default fee target in USD cents charged per 32 bytes of payload.
    uint256 internal constant DEFAULT_USD_CENTS_PER_32_BYTES = 10; // $0.10

    /// @notice Default base fee in wei (0 = purely payload-length-priced).
    uint256 internal constant DEFAULT_BASE_FEE_WEI = 0;

    // ========================================================================
    // 2. ENTRY POINT
    // ========================================================================

    struct Deployment {
        address gravityPortal;
        address gBridgeSender;
    }

    function run() external returns (Deployment memory out) {
        // --- 2.1 load config ---
        uint256 deployerPk = vm.envUint("GRAVITY_CORE_CONTRACT_EOA_OWNER_PRIVATE_KEY");
        address ownerEoa = vm.envAddress("GRAVITY_CORE_CONTRACT_EOA_OWNER");
        address gToken = _envAddressOr("G_TOKEN_ADDRESS", DEFAULT_G_TOKEN);
        uint256 ethPriceUsd = _envUintOr("ETH_PRICE_USD", DEFAULT_ETH_PRICE_USD);
        uint256 centsPer32B = _envUintOr("USD_CENTS_PER_32_BYTES", DEFAULT_USD_CENTS_PER_32_BYTES);
        uint256 baseFeeWei = _envUintOr("BASE_FEE_WEI", DEFAULT_BASE_FEE_WEI);

        // --- 2.2 hard safety gates ---
        require(block.chainid == MAINNET_CHAIN_ID, "DeployBridgeMainnet: not on Ethereum mainnet (chainId must be 1)");
        require(ownerEoa != address(0), "DeployBridgeMainnet: GRAVITY_CORE_CONTRACT_EOA_OWNER unset");
        require(gToken != address(0), "DeployBridgeMainnet: G_TOKEN_ADDRESS unset");
        require(gToken.code.length > 0, "DeployBridgeMainnet: G token address has no code on mainnet");
        require(ethPriceUsd > 0, "DeployBridgeMainnet: ETH_PRICE_USD must be > 0");
        require(centsPer32B > 0, "DeployBridgeMainnet: USD_CENTS_PER_32_BYTES must be > 0");

        // Cross-check: the private key MUST resolve to the provided owner address.
        // Catches every class of "wrong key pasted" mistake before a single tx is sent.
        require(
            vm.addr(deployerPk) == ownerEoa,
            "DeployBridgeMainnet: private key does not match GRAVITY_CORE_CONTRACT_EOA_OWNER"
        );

        // --- 2.3 compute fee params ---
        // feePerByte = centsPer32B * 1e16 / (32 * ethPriceUsd)
        //            = USD_CENTS_PER_32_BYTES * 10^16 / (32 * ETH_PRICE_USD) wei
        // Derivation: $X per 32 B at $P / ETH
        //   wei/byte = X * 1e18 / (32 * P)
        //   with X in cents: (cents/100) * 1e18 / (32 * P) = cents * 1e16 / (32 * P)
        uint256 feePerByte = (centsPer32B * 1e16) / (32 * ethPriceUsd);
        require(feePerByte > 0, "DeployBridgeMainnet: feePerByte rounded to zero; raise cents or lower ETH price");

        // --- 2.4 banner ---
        console.log("=========================================================");
        console.log("       Gravity Bridge - Ethereum Mainnet Deployment");
        console.log("=========================================================");
        console.log("chainId                :", block.chainid);
        console.log("Deployer / owner / FR  :", ownerEoa);
        console.log("G token (ERC-20)       :", gToken);
        console.log("ETH price (USD)        :", ethPriceUsd);
        console.log("Target: cents / 32 B   :", centsPer32B);
        console.log("baseFee (wei)          :", baseFeeWei);
        console.log("feePerByte (wei)       :", feePerByte);
        console.log("  -> cost of 32 B msg  :");
        console.log("     payload bytes     :", uint256(36 + 32));
        console.log("     total wei         :", baseFeeWei + (36 + 32) * feePerByte);
        console.log("=========================================================");

        // --- 2.5 broadcast ---
        vm.startBroadcast(deployerPk);

        console.log("[1/2] Deploying GravityPortal ...");
        GravityPortal portal = new GravityPortal({
            initialOwner: ownerEoa,
            initialBaseFee: baseFeeWei,
            initialFeePerByte: feePerByte,
            initialFeeRecipient: ownerEoa
        });
        console.log("      GravityPortal   :", address(portal));

        console.log("[2/2] Deploying GBridgeSender ...");
        GBridgeSender sender = new GBridgeSender({ gToken_: gToken, gravityPortal_: address(portal), owner_: ownerEoa });
        console.log("      GBridgeSender   :", address(sender));

        vm.stopBroadcast();

        // --- 2.6 post-deploy invariant checks (must pass or we abort) ---
        _assertPortal(portal, ownerEoa, baseFeeWei, feePerByte);
        _assertSender(sender, address(portal), gToken, ownerEoa);

        // --- 2.7 final report ---
        console.log("---------------------------------------------------------");
        console.log("Deployment complete. Give these addresses to Gravity team");
        console.log("for GBridgeReceiver genesis config:");
        console.log("  trustedBridge (GBridgeSender) :", address(sender));
        console.log("  trustedSourceId (chainId)     :", block.chainid);
        console.log("  GravityPortal                 :", address(portal));
        console.log("---------------------------------------------------------");

        out = Deployment({ gravityPortal: address(portal), gBridgeSender: address(sender) });

        // Persist a JSON artifact for downstream tooling / provenance.
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "gravityPortal", address(portal));
        vm.serializeAddress(obj, "gBridgeSender", address(sender));
        vm.serializeAddress(obj, "gToken", gToken);
        vm.serializeAddress(obj, "owner", ownerEoa);
        vm.serializeUint(obj, "baseFeeWei", baseFeeWei);
        vm.serializeUint(obj, "feePerByteWei", feePerByte);
        vm.serializeUint(obj, "ethPriceUsd", ethPriceUsd);
        string memory json = vm.serializeUint(obj, "usdCentsPer32Bytes", centsPer32B);
        vm.writeJson(json, "./deployments/mainnet.json");
        console.log("Artifact written: deployments/mainnet.json");
    }

    // ========================================================================
    // 3. POST-DEPLOY INVARIANT CHECKS
    // ========================================================================

    function _assertPortal(GravityPortal portal, address owner_, uint256 baseFee_, uint256 feePerByte_) internal view {
        require(portal.owner() == owner_, "Portal: owner mismatch");
        require(portal.feeRecipient() == owner_, "Portal: feeRecipient mismatch");
        require(portal.baseFee() == baseFee_, "Portal: baseFee mismatch");
        require(portal.feePerByte() == feePerByte_, "Portal: feePerByte mismatch");
        require(portal.nonce() == 0, "Portal: nonce must start at 0");
        require(address(portal).balance == 0, "Portal: must hold no ETH at deploy");
    }

    function _assertSender(GBridgeSender sender, address portal_, address gToken_, address owner_) internal view {
        require(sender.owner() == owner_, "Sender: owner mismatch");
        require(sender.gravityPortal() == portal_, "Sender: gravityPortal immutable mismatch");
        require(sender.gToken() == gToken_, "Sender: gToken immutable mismatch");
        require(address(sender).balance == 0, "Sender: must hold no ETH at deploy");
    }

    // ========================================================================
    // 4. ENV HELPERS
    // ========================================================================

    function _envAddressOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallback_;
        }
    }

    function _envUintOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallback_;
        }
    }
}
