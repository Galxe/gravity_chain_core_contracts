// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GravityPortal } from "src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title DeployBridgeKeystore — Ethereum mainnet bridge-sender deploy via an encrypted keystore
/// @notice Deploys GravityPortal + GBridgeSender, then hands BOTH to a multisig (Ownable2Step).
/// @dev    This script reads NO private key. Sign with an encrypted keystore (never plaintext):
///
///           forge script scripts/mainnet/DeployBridgeKeystore.s.sol:DeployBridgeKeystore \
///             --rpc-url $MAINNET_RPC_URL \
///             --account <keystore-name> --sender <deployer-addr> \
///             --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY --slow -vvv
///
///         The deployer is a TEMPORARY owner only: ownership of both contracts is
///         transferred to the multisig in the same broadcast (Ownable2Step — the
///         multisig must then call acceptOwnership() on EACH contract to finalize).
///
///         Required env:
///           DEPLOYER_ADDRESS   - the keystore EOA address (must match --sender)
///         Optional env:
///           MULTISIG_ADDRESS      - final owner (Safe) for BOTH contracts. Defaults to the
///                                   verified production Safe (DEFAULT_MULTISIG below); only
///                                   override for fork tests. MUST differ from the deployer.
///           FEE_RECIPIENT_ADDRESS - portal fee recipient (default: MULTISIG_ADDRESS)
///           G_TOKEN_ADDRESS       - default: mainnet canonical G
///           BASE_FEE_WEI          - default: 0
///           FEE_PER_BYTE_WEI      - default: 1_250_000 (≈ $0.10 / 32B at ETH=$2500; revisit!)
///           ALLOW_NON_MAINNET     - "1" to bypass the chainId==1 guard (fork tests only)
contract DeployBridgeKeystore is Script {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    address internal constant DEFAULT_G_TOKEN = 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649;

    /// @notice Verified production multisig — the final owner of both contracts.
    /// @dev    Gnosis Safe v1.3.0, 3-of-6, on the canonical L1 singleton
    ///         (0xd9db270c…ee709552). Verified on-chain to also be the owner of
    ///         the G token (DEFAULT_G_TOKEN). Baked in so the audit's #1 risk —
    ///         a wrong owner — cannot be introduced by a fat-fingered env var.
    address internal constant DEFAULT_MULTISIG = 0xbD6e434dB90FD8AD4E28d85C133AD34cA6fbfB6D;

    uint256 internal constant DEFAULT_BASE_FEE_WEI = 0;
    uint256 internal constant DEFAULT_FEE_PER_BYTE_WEI = 1_250_000;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address multisig = _envAddressOr("MULTISIG_ADDRESS", DEFAULT_MULTISIG);
        address feeRecipient = _envAddressOr("FEE_RECIPIENT_ADDRESS", multisig);
        address gToken = _envAddressOr("G_TOKEN_ADDRESS", DEFAULT_G_TOKEN);
        uint256 baseFee = _envUintOr("BASE_FEE_WEI", DEFAULT_BASE_FEE_WEI);
        uint256 feePerByte = _envUintOr("FEE_PER_BYTE_WEI", DEFAULT_FEE_PER_BYTE_WEI);

        // --- safety gates ---
        bool mainnet = !_envBoolOr("ALLOW_NON_MAINNET", false);
        if (mainnet) {
            require(block.chainid == MAINNET_CHAIN_ID, "DeployBridgeKeystore: not Ethereum mainnet (chainId != 1)");
        }
        require(deployer != address(0), "DeployBridgeKeystore: DEPLOYER_ADDRESS unset");
        require(multisig != address(0), "DeployBridgeKeystore: MULTISIG_ADDRESS unset");
        require(deployer != multisig, "DeployBridgeKeystore: deployer and multisig must differ");
        require(feeRecipient != address(0), "DeployBridgeKeystore: feeRecipient invalid");
        require(gToken.code.length > 0, "DeployBridgeKeystore: G token has no code on this chain");
        require(feePerByte > 0, "DeployBridgeKeystore: feePerByte must be > 0");
        // On mainnet (or a mainnet fork) the multisig MUST be a deployed contract — a
        // typo'd EOA passing as the owner would be unrecoverable. Skipped only when the
        // chainId guard is bypassed for pure-anvil tests.
        if (mainnet) {
            require(multisig.code.length > 0, "DeployBridgeKeystore: multisig has no code (not a deployed Safe?)");
        }

        // --- banner ---
        console.log("=========================================================");
        console.log("       Gravity Bridge - Ethereum Mainnet (keystore)");
        console.log("=========================================================");
        console.log("chainId            :", block.chainid);
        console.log("deployer (temp)    :", deployer);
        console.log("multisig (final)   :", multisig);
        console.log("feeRecipient       :", feeRecipient);
        console.log("G token (ERC-20)   :", gToken);
        console.log("baseFee (wei)      :", baseFee);
        console.log("feePerByte (wei)   :", feePerByte);
        console.log("=========================================================");

        // Address overload of startBroadcast: forge resolves the signer from
        // --account / --ledger. No private key is ever materialized in the script.
        vm.startBroadcast(deployer);

        console.log("[1/2] Deploying GravityPortal ...");
        GravityPortal portal = new GravityPortal({
            initialOwner: deployer,
            initialBaseFee: baseFee,
            initialFeePerByte: feePerByte,
            initialFeeRecipient: feeRecipient
        });
        console.log("      GravityPortal :", address(portal));
        portal.transferOwnership(multisig); // pending; multisig must acceptOwnership()

        console.log("[2/2] Deploying GBridgeSender ...");
        GBridgeSender sender = new GBridgeSender({ gToken_: gToken, gravityPortal_: address(portal), owner_: deployer });
        console.log("      GBridgeSender :", address(sender));
        sender.transferOwnership(multisig); // pending; multisig must acceptOwnership()

        vm.stopBroadcast();

        // --- post-deploy invariants (revert = abort) ---
        require(portal.owner() == deployer, "Portal: owner != deployer pre-accept");
        require(portal.pendingOwner() == multisig, "Portal: pendingOwner != multisig");
        require(portal.feeRecipient() == feeRecipient, "Portal: feeRecipient mismatch");
        require(portal.baseFee() == baseFee, "Portal: baseFee mismatch");
        require(portal.feePerByte() == feePerByte, "Portal: feePerByte mismatch");
        require(portal.nonce() == 0, "Portal: nonce must start at 0");
        require(address(portal).balance == 0, "Portal: must hold no ETH at deploy");
        require(sender.owner() == deployer, "Sender: owner != deployer pre-accept");
        require(sender.pendingOwner() == multisig, "Sender: pendingOwner != multisig");
        require(sender.gToken() == gToken, "Sender: gToken immutable mismatch");
        require(sender.gravityPortal() == address(portal), "Sender: gravityPortal immutable mismatch");
        require(address(sender).balance == 0, "Sender: must hold no ETH at deploy");

        // --- JSON artifact for downstream tooling / provenance ---
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "gravityPortal", address(portal));
        vm.serializeAddress(obj, "gBridgeSender", address(sender));
        vm.serializeAddress(obj, "multisig", multisig);
        vm.serializeAddress(obj, "feeRecipient", feeRecipient);
        vm.serializeAddress(obj, "gToken", gToken);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeUint(obj, "baseFeeWei", baseFee);
        string memory json = vm.serializeUint(obj, "feePerByteWei", feePerByte);
        vm.writeJson(json, "./deployments/mainnet.json");

        // --- final report ---
        console.log("---------------------------------------------------------");
        console.log("Deploy complete. BOTH contracts have pendingOwner = multisig.");
        console.log("The multisig MUST now call acceptOwnership() on each contract.");
        console.log("Give the Gravity chain team, for GBridgeReceiver genesis config:");
        console.log("  trustedBridge (GBridgeSender) :", address(sender));
        console.log("  trustedSourceId (chainId)     :", block.chainid);
        console.log("  GravityPortal                 :", address(portal));
        console.log("Artifact written: deployments/mainnet.json");
        console.log("---------------------------------------------------------");
    }

    // ========================================================================
    // ENV HELPERS
    // ========================================================================

    function _envAddressOr(
        string memory key,
        address fallback_
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallback_;
        }
    }

    function _envUintOr(
        string memory key,
        uint256 fallback_
    ) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallback_;
        }
    }

    function _envBoolOr(
        string memory key,
        bool fallback_
    ) internal view returns (bool) {
        try vm.envString(key) returns (string memory v) {
            return keccak256(bytes(v)) == keccak256(bytes("1"));
        } catch {
            return fallback_;
        }
    }
}
