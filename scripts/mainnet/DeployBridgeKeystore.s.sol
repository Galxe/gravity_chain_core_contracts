// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GravityPortal } from "src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title ICreateX
/// @notice Minimal interface to the CreateX factory deployed at its canonical address on
///         Ethereum + 180+ EVM chains. Audited public good (https://github.com/pcaversaccio/createx).
interface ICreateX {
    function deployCreate3(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address);

    function computeCreate3Address(
        bytes32 salt,
        address deployer
    ) external pure returns (address);
}

/// @title DeployBridgeKeystore — Ethereum mainnet bridge-sender deploy via CreateX (CREATE3)
/// @notice Deploys GravityPortal + GBridgeSender to deterministic addresses via CreateX/CREATE3,
///         then hands BOTH to a multisig (Ownable2Step). After this script, the multisig only
///         needs to call `acceptOwnership()` on each contract to finalize.
/// @dev    NO private key is read by this script. Sign with an encrypted keystore (never plaintext):
///
///           forge script scripts/mainnet/DeployBridgeKeystore.s.sol:DeployBridgeKeystore \
///             --rpc-url $MAINNET_RPC_URL \
///             --account <keystore-name> --sender <deployer-addr> \
///             --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY --slow -vvv
///
///         Salt format (CreateX "guarded salt"):
///             [ deployer (20B) | flag (1B) | entropy (11B) ]
///         The first 20 bytes lock the salt to the deployer EOA — no other caller can ever land
///         at the same address. The 21st byte is the cross-chain flag:
///             0x00 = chain-agnostic — same address on every EVM chain (USED HERE).
///             0x01 = chain-specific — address mixes in `block.chainid`.
///         The 11-byte entropy is `keccak256("gravity.bridge.<role>.v1")[21:]`, so the addresses
///         are versionable and human-traceable from the salt alone.
///
///         Required env:
///           DEPLOYER_ADDRESS   - the keystore EOA address (must match --sender)
///         Optional env (defaults baked in):
///           MULTISIG_ADDRESS   - final owner; defaults to verified production Safe.
///           FEE_RECIPIENT_ADDRESS - portal fee recipient (default: MULTISIG_ADDRESS)
///           G_TOKEN_ADDRESS    - default: mainnet canonical G
///           BASE_FEE_WEI       - default: 50_000_000_000_000 (≈ $0.10 at ETH = $2000)
///           FEE_PER_BYTE_WEI   - default: 2_343_750_000_000 (≈ $0.15 / 32 B at ETH = $2000)
///           ALLOW_NON_MAINNET  - "1" to bypass the chainId==1 + CreateX-presence guards
///                                (fork tests / unit tests only)
contract DeployBridgeKeystore is Script {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Canonical CreateX factory address — same on Ethereum + 180+ EVM chains.
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    uint256 internal constant MAINNET_CHAIN_ID = 1;

    address internal constant DEFAULT_G_TOKEN = 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649;

    /// @notice Verified production multisig — the final owner of both contracts.
    /// @dev    Gnosis Safe v1.3.0, 3-of-6, on the canonical L1 singleton, also the on-chain owner
    ///         of the G token. Baked in so a fat-fingered env var cannot introduce a wrong owner.
    address internal constant DEFAULT_MULTISIG = 0xbD6e434dB90FD8AD4E28d85C133AD34cA6fbfB6D;

    /// @notice Default base fee: ≈ $0.10 at ETH = $2000.
    uint256 internal constant DEFAULT_BASE_FEE_WEI = 50_000_000_000_000;

    /// @notice Default fee per byte: ≈ $0.15 per 32 bytes at ETH = $2000.
    uint256 internal constant DEFAULT_FEE_PER_BYTE_WEI = 2_343_750_000_000;

    /// @notice Cross-chain flag byte for the CreateX guarded salt.
    /// @dev `0x00` = chain-agnostic — the same `(deployer, salt)` lands at the SAME address on
    ///      every EVM chain. (`0x01` would mix in `block.chainid`, giving a chain-specific address.)
    bytes1 internal constant CROSS_CHAIN_FLAG = 0x00;

    /// @notice Salt entropy labels — pin the v1 mainnet addresses. Changing these gives new addresses.
    bytes11 internal constant SALT_PORTAL_ENTROPY = bytes11(uint88(uint256(keccak256("gravity.bridge.portal.v1"))));
    bytes11 internal constant SALT_SENDER_ENTROPY = bytes11(uint88(uint256(keccak256("gravity.bridge.sender.v1"))));

    // ========================================================================
    // ENTRY POINT
    // ========================================================================

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
            require(multisig.code.length > 0, "DeployBridgeKeystore: multisig has no code (not a deployed Safe?)");
            require(CREATEX.code.length > 0, "DeployBridgeKeystore: CreateX not present at canonical address");
        }
        require(deployer != address(0), "DeployBridgeKeystore: DEPLOYER_ADDRESS unset");
        require(multisig != address(0), "DeployBridgeKeystore: MULTISIG_ADDRESS unset");
        require(deployer != multisig, "DeployBridgeKeystore: deployer and multisig must differ");
        require(feeRecipient != address(0), "DeployBridgeKeystore: feeRecipient invalid");
        require(gToken.code.length > 0, "DeployBridgeKeystore: G token has no code on this chain");
        require(feePerByte > 0, "DeployBridgeKeystore: feePerByte must be > 0");

        // --- guarded salts (deployer || flag || entropy) ---
        bytes32 saltP = bytes32(abi.encodePacked(deployer, CROSS_CHAIN_FLAG, SALT_PORTAL_ENTROPY));
        bytes32 saltS = bytes32(abi.encodePacked(deployer, CROSS_CHAIN_FLAG, SALT_SENDER_ENTROPY));

        // --- predict (deterministic; usable BEFORE broadcast) ---
        address portalAddr = _predictCreate3(deployer, saltP);
        address senderAddr = _predictCreate3(deployer, saltS);

        // --- banner ---
        console.log("=========================================================");
        console.log("    Gravity Bridge - Ethereum Mainnet (CreateX/CREATE3)");
        console.log("=========================================================");
        console.log("CreateX factory    :", CREATEX);
        console.log("chainId            :", block.chainid);
        console.log("deployer (temp)    :", deployer);
        console.log("multisig (final)   :", multisig);
        console.log("feeRecipient       :", feeRecipient);
        console.log("G token (ERC-20)   :", gToken);
        console.log("baseFee (wei)      :", baseFee);
        console.log("feePerByte (wei)   :", feePerByte);
        console.log("--- predicted addresses (same on every EVM chain) ---");
        console.log("GravityPortal      :", portalAddr);
        console.log("GBridgeSender      :", senderAddr);
        console.log("=========================================================");

        require(
            portalAddr.code.length == 0, "DeployBridgeKeystore: predicted Portal address already has code (collision)"
        );
        require(
            senderAddr.code.length == 0, "DeployBridgeKeystore: predicted Sender address already has code (collision)"
        );

        // --- broadcast ---
        vm.startBroadcast(deployer);

        // [1/2] GravityPortal via CREATE3
        bytes memory portalInit = abi.encodePacked(
            type(GravityPortal).creationCode, abi.encode(deployer, baseFee, feePerByte, feeRecipient)
        );
        address portal = ICreateX(CREATEX).deployCreate3(saltP, portalInit);
        require(portal == portalAddr, "DeployBridgeKeystore: Portal address mismatch (salt drift?)");
        console.log("[1/2] GravityPortal deployed :", portal);
        GravityPortal(portal).transferOwnership(multisig); // pending; multisig must acceptOwnership

        // [2/2] GBridgeSender via CREATE3 — Portal address is now baked into the initcode
        bytes memory senderInit =
            abi.encodePacked(type(GBridgeSender).creationCode, abi.encode(gToken, portal, deployer));
        address sender = ICreateX(CREATEX).deployCreate3(saltS, senderInit);
        require(sender == senderAddr, "DeployBridgeKeystore: Sender address mismatch (salt drift?)");
        console.log("[2/2] GBridgeSender deployed :", sender);
        GBridgeSender(sender).transferOwnership(multisig); // pending; multisig must acceptOwnership

        vm.stopBroadcast();

        // --- post-deploy invariants (revert = abort) ---
        require(GravityPortal(portal).owner() == deployer, "Portal: owner != deployer pre-accept");
        require(GravityPortal(portal).pendingOwner() == multisig, "Portal: pendingOwner != multisig");
        require(GravityPortal(portal).feeRecipient() == feeRecipient, "Portal: feeRecipient mismatch");
        require(GravityPortal(portal).baseFee() == baseFee, "Portal: baseFee mismatch");
        require(GravityPortal(portal).feePerByte() == feePerByte, "Portal: feePerByte mismatch");
        require(GravityPortal(portal).nonce() == 0, "Portal: nonce must start at 0");
        require(address(portal).balance == 0, "Portal: must hold no ETH at deploy");
        require(GBridgeSender(sender).owner() == deployer, "Sender: owner != deployer pre-accept");
        require(GBridgeSender(sender).pendingOwner() == multisig, "Sender: pendingOwner != multisig");
        require(GBridgeSender(sender).gToken() == gToken, "Sender: gToken immutable mismatch");
        require(GBridgeSender(sender).gravityPortal() == address(portal), "Sender: gravityPortal immutable mismatch");
        require(address(sender).balance == 0, "Sender: must hold no ETH at deploy");

        // --- JSON artifact ---
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "gravityPortal", portal);
        vm.serializeAddress(obj, "gBridgeSender", sender);
        vm.serializeAddress(obj, "multisig", multisig);
        vm.serializeAddress(obj, "feeRecipient", feeRecipient);
        vm.serializeAddress(obj, "gToken", gToken);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "createX", CREATEX);
        vm.serializeBytes32(obj, "saltPortal", saltP);
        vm.serializeBytes32(obj, "saltSender", saltS);
        vm.serializeUint(obj, "baseFeeWei", baseFee);
        string memory json = vm.serializeUint(obj, "feePerByteWei", feePerByte);
        vm.writeJson(json, "./deployments/mainnet.json");

        // --- final report ---
        console.log("---------------------------------------------------------");
        console.log("Deploy complete. BOTH contracts have pendingOwner = multisig.");
        console.log("The multisig MUST now call acceptOwnership() on each contract.");
        console.log("Give the Gravity chain team, for GBridgeReceiver genesis config:");
        console.log("  trustedBridge (GBridgeSender) :", sender);
        console.log("  trustedSourceId (chainId)     :", block.chainid);
        console.log("  GravityPortal                 :", portal);
        console.log("Artifact written: deployments/mainnet.json");
        console.log("---------------------------------------------------------");
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    /// @notice Predict the CREATE3 address for a CreateX deployment using our guarded-salt format.
    /// @dev Mirrors `CreateX._guard` for `(SenderBytes.MsgSender, RedeployProtectionFlag.False)`,
    ///      which is what the salt format above (deployer || 0x00 || entropy) produces:
    ///        guardedSalt = keccak256(abi.encodePacked(uint256(uint160(deployer)), salt))
    ///      Then asks CreateX for the canonical CREATE3 address from the post-guard salt.
    function _predictCreate3(
        address deployer_,
        bytes32 salt
    ) internal view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(deployer_)), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }

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
