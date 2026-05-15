// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GravityPortal } from "src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title VerifyBridgeMainnet
/// @notice Read-only verifier: confirms that the GravityPortal and GBridgeSender
///         on Ethereum mainnet match what we built locally AND that their
///         constructor args / ownership are the ones we intended.
///
/// @dev Run against mainnet with a normal RPC; no --broadcast. The script:
///        1. Hard-gates chainId == 1.
///        2. Reads expected values from .env.mainnet (owner, G token, fees).
///        3. Reads deployed addresses from deployments/mainnet.json
///           (or env: GRAVITY_PORTAL_ADDRESS / GBRIDGE_SENDER_ADDRESS).
///        4. Verifies constructor args + ownership by reading public getters on
///           the deployed contracts (Portal: owner / pendingOwner / feeRecipient /
///           baseFee / feePerByte; Sender: owner / pendingOwner / gToken /
///           gravityPortal — the last two are `immutable`, so getter == arg).
///        5. Verifies the runtime bytecode is byte-for-byte identical to
///           what we get by deploying the *same* contracts locally. Metadata
///           suffix is stripped before comparison so IPFS-hash differences
///           between build environments do not produce a false negative.
///
/// @dev    OWNERSHIP MODELS — both deploy paths in scripts/mainnet/ are supported:
///
///         (a) Single-EOA path (DeployBridgeMainnet.s.sol, deploy_mainnet.sh):
///             the EOA is the permanent owner and the portal feeRecipient.
///             Set GRAVITY_CORE_CONTRACT_EOA_OWNER; leave MULTISIG_ADDRESS unset.
///
///         (b) Keystore + multisig-handoff path (DeployBridgeKeystore.s.sol):
///             ownership of both contracts is transferred to a multisig via
///             Ownable2Step. Set MULTISIG_ADDRESS (the final owner) and,
///             optionally, DEPLOYER_ADDRESS (the temporary owner during handoff)
///             and FEE_RECIPIENT_ADDRESS. The verifier accepts either:
///               - FINALIZED : owner == multisig && pendingOwner == 0
///               - PENDING   : pendingOwner == multisig (acceptOwnership() not
///                             yet called) — reported as a loud WARNING, not a
///                             failure, so the verifier can run between deploy
///                             and the multisig accepting.
///
/// @dev    Any revert = VERIFICATION FAILED. Exit code will be non-zero.
contract VerifyBridgeMainnet is Script {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    address internal constant DEFAULT_G_TOKEN = 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649;

    /// @notice Verified production multisig — the expected final owner.
    /// @dev    Gnosis Safe v1.3.0, 3-of-6, also the on-chain owner of DEFAULT_G_TOKEN.
    ///         Must stay in sync with DeployBridgeKeystore.DEFAULT_MULTISIG.
    address internal constant DEFAULT_MULTISIG = 0xbD6e434dB90FD8AD4E28d85C133AD34cA6fbfB6D;

    // Fee defaults — kept in sync with DeployBridgeKeystore. With no fee env vars
    // set, the USD derivation below yields feePerByte = 2_343_750_000_000 wei
    // (15 * 1e16 / (32 * 2000)), matching DeployBridgeKeystore.DEFAULT_FEE_PER_BYTE_WEI.
    uint256 internal constant DEFAULT_ETH_PRICE_USD = 2000;
    uint256 internal constant DEFAULT_USD_CENTS_PER_32_BYTES = 15;
    uint256 internal constant DEFAULT_BASE_FEE_WEI = 50_000_000_000_000; // ≈ $0.10 at ETH = $2000

    struct Expected {
        address owner; // intended FINAL owner (multisig, or the EOA in path (a))
        address deployer; // temporary owner during an Ownable2Step handoff (path (b)); 0 if unknown
        address feeRecipient; // portal fee recipient (defaults to `owner`)
        address gToken;
        uint256 baseFee;
        uint256 feePerByte;
    }

    struct Deployed {
        address portal;
        address sender;
    }

    // ========================================================================
    // ENTRY
    // ========================================================================

    function run() external {
        require(block.chainid == MAINNET_CHAIN_ID, "VerifyBridgeMainnet: not on Ethereum mainnet (chainId must be 1)");

        Expected memory exp = _loadExpected();
        Deployed memory dep = _loadDeployed();

        _banner(exp, dep);

        _verifyPortalState(dep.portal, exp);
        _verifySenderState(dep.sender, dep.portal, exp);

        _verifyPortalBytecode(dep.portal, exp);
        _verifySenderBytecode(dep.sender, dep.portal, exp);

        console.log("");
        console.log("=========================================================");
        console.log("  ALL MAINNET CHECKS PASSED                              ");
        console.log("=========================================================");
    }

    // ========================================================================
    // CONFIG LOADERS
    // ========================================================================

    function _loadExpected() internal view returns (Expected memory e) {
        // Final intended owner: an explicit MULTISIG_ADDRESS, else the single-EOA
        // owner (back-compat with deploy_mainnet.sh), else the verified production
        // Safe baked in as DEFAULT_MULTISIG.
        e.owner = _envAddressOr("MULTISIG_ADDRESS", _envAddressOr("GRAVITY_CORE_CONTRACT_EOA_OWNER", DEFAULT_MULTISIG));
        // Temporary owner during an Ownable2Step handoff (keystore path only).
        e.deployer = _envAddressOr("DEPLOYER_ADDRESS", address(0));
        // Portal fee recipient: explicit env, else defaults to the final owner.
        e.feeRecipient = _envAddressOr("FEE_RECIPIENT_ADDRESS", e.owner);
        e.gToken = _envAddressOr("G_TOKEN_ADDRESS", DEFAULT_G_TOKEN);
        e.baseFee = _envUintOr("BASE_FEE_WEI", DEFAULT_BASE_FEE_WEI);

        // feePerByte: an explicit FEE_PER_BYTE_WEI (keystore path) takes
        // precedence; otherwise derive it from the USD target (EOA path).
        uint256 explicitFeePerByte = _envUintOr("FEE_PER_BYTE_WEI", 0);
        if (explicitFeePerByte > 0) {
            e.feePerByte = explicitFeePerByte;
        } else {
            uint256 ethPriceUsd = _envUintOr("ETH_PRICE_USD", DEFAULT_ETH_PRICE_USD);
            uint256 centsPer32B = _envUintOr("USD_CENTS_PER_32_BYTES", DEFAULT_USD_CENTS_PER_32_BYTES);
            e.feePerByte = (centsPer32B * 1e16) / (32 * ethPriceUsd);
        }

        require(e.owner != address(0), "expected owner unset (set MULTISIG_ADDRESS or GRAVITY_CORE_CONTRACT_EOA_OWNER)");
        require(e.feeRecipient != address(0), "feeRecipient unset");
        require(e.gToken != address(0), "gToken unset");
        require(e.gToken.code.length > 0, "gToken has no code on mainnet");
        require(e.feePerByte > 0, "feePerByte computed as 0");
    }

    function _loadDeployed() internal view returns (Deployed memory d) {
        d.portal = _envAddressOr("GRAVITY_PORTAL_ADDRESS", address(0));
        d.sender = _envAddressOr("GBRIDGE_SENDER_ADDRESS", address(0));

        if (d.portal == address(0) || d.sender == address(0)) {
            // Fall back to the deploy artifact.
            string memory json = vm.readFile("./deployments/mainnet.json");
            if (d.portal == address(0)) {
                d.portal = abi.decode(vm.parseJson(json, ".gravityPortal"), (address));
            }
            if (d.sender == address(0)) {
                d.sender = abi.decode(vm.parseJson(json, ".gBridgeSender"), (address));
            }
        }

        require(d.portal != address(0), "GravityPortal address unresolved");
        require(d.sender != address(0), "GBridgeSender address unresolved");
        require(d.portal.code.length > 0, "GravityPortal has no code at expected address");
        require(d.sender.code.length > 0, "GBridgeSender has no code at expected address");
    }

    // ========================================================================
    // STATE VERIFICATION (= constructor-arg + ownership verification)
    // ========================================================================

    function _verifyPortalState(
        address portalAddr,
        Expected memory e
    ) internal view {
        console.log("[1/4] GravityPortal state ...");
        GravityPortal portal = GravityPortal(portalAddr);

        _verifyOwnership("GravityPortal", portal.owner(), portal.pendingOwner(), e);
        _checkAddr("Portal.feeRecipient", portal.feeRecipient(), e.feeRecipient);
        _checkUint("Portal.baseFee", portal.baseFee(), e.baseFee);
        _checkUint("Portal.feePerByte", portal.feePerByte(), e.feePerByte);
        // Nonce may have advanced if the bridge has been used; informational only.
        console.log("   Portal.nonce (info) :", portal.nonce());
        console.log("   [ok]");
    }

    function _verifySenderState(
        address senderAddr,
        address portalAddr,
        Expected memory e
    ) internal view {
        console.log("[2/4] GBridgeSender state ...");
        GBridgeSender sender = GBridgeSender(senderAddr);

        _verifyOwnership("GBridgeSender", sender.owner(), sender.pendingOwner(), e);
        // These two are `immutable`: the getter value == the constructor arg.
        _checkAddr("Sender.gToken (immutable)", sender.gToken(), e.gToken);
        _checkAddr("Sender.gravityPortal (immutable)", sender.gravityPortal(), portalAddr);
        console.log("   [ok]");
    }

    /// @notice Verify an Ownable2Step contract's owner against the intended final owner.
    /// @dev Accepts two valid states; reverts on anything else:
    ///        - FINALIZED : owner == e.owner && pendingOwner == 0
    ///        - PENDING   : pendingOwner == e.owner  (handoff initiated, not yet
    ///                      accepted; loud WARNING but not a failure). When
    ///                      DEPLOYER_ADDRESS is provided, the current owner must
    ///                      additionally equal it for the PENDING state to hold.
    function _verifyOwnership(
        string memory label,
        address currentOwner,
        address pendingOwner,
        Expected memory e
    ) internal pure {
        if (currentOwner == e.owner && pendingOwner == address(0)) {
            // FINALIZED — nothing to print; the caller's [ok] line covers it.
            return;
        }
        bool pendingToFinalOwner = pendingOwner == e.owner;
        bool deployerOk = e.deployer == address(0) || currentOwner == e.deployer;
        if (pendingToFinalOwner && deployerOk) {
            // PENDING — handoff initiated but acceptOwnership() not yet called.
            console.log("   WARNING:", label, "ownership handoff is PENDING");
            console.log("            current owner :", currentOwner);
            console.log("            pendingOwner  :", pendingOwner, "(intended final owner)");
            console.log("            -> the multisig must still call acceptOwnership()");
            return;
        }
        console.log("   ", label, "current owner :", currentOwner);
        console.log("   ", label, "pendingOwner  :", pendingOwner);
        console.log("   ", label, "expected owner:", e.owner);
        revert(string.concat("ownership mismatch: ", label));
    }

    // ========================================================================
    // BYTECODE VERIFICATION
    // ========================================================================

    function _verifyPortalBytecode(
        address portalAddr,
        Expected memory e
    ) internal {
        console.log("[3/4] GravityPortal bytecode ...");
        // Re-deploy locally and compare runtime code. GravityPortal has no
        // `immutable`s, so the runtime code is independent of constructor args;
        // we pass the expected args anyway to be explicit about intent.
        GravityPortal local = new GravityPortal({
            initialOwner: e.owner,
            initialBaseFee: e.baseFee,
            initialFeePerByte: e.feePerByte,
            initialFeeRecipient: e.feeRecipient
        });
        _compareCode(address(local), portalAddr, "GravityPortal");
        console.log("   [ok]");
    }

    function _verifySenderBytecode(
        address senderAddr,
        address portalAddr,
        Expected memory e
    ) internal {
        console.log("[4/4] GBridgeSender bytecode ...");
        // GBridgeSender has 2 immutables (gToken, gravityPortal). Re-deploying
        // locally with the same args produces the same immutable bake-in, so a
        // plain byte-for-byte comparison works. `owner_` is plain storage (not
        // immutable), so it does not affect the runtime code — any non-zero
        // address works here; we use the expected final owner.
        GBridgeSender local = new GBridgeSender({ gToken_: e.gToken, gravityPortal_: portalAddr, owner_: e.owner });
        _compareCode(address(local), senderAddr, "GBridgeSender");
        console.log("   [ok]");
    }

    // ========================================================================
    // BYTECODE HELPERS
    // ========================================================================

    function _compareCode(
        address local,
        address onchain,
        string memory name
    ) internal view {
        bytes memory a = local.code;
        bytes memory b = onchain.code;

        bytes32 hA = keccak256(a);
        bytes32 hB = keccak256(b);

        if (hA == hB) {
            console.log("   strict match (incl. metadata):", name);
            return;
        }

        bytes memory aS = _stripMetadata(a);
        bytes memory bS = _stripMetadata(b);

        if (keccak256(aS) == keccak256(bS)) {
            console.log("   semantic match (metadata suffix differs):", name);
            return;
        }

        console.log("   LOCAL   keccak256 :", vm.toString(hA));
        console.log("   ONCHAIN keccak256 :", vm.toString(hB));
        console.log("   LOCAL   length    :", a.length);
        console.log("   ONCHAIN length    :", b.length);
        revert(string.concat("bytecode mismatch for ", name));
    }

    /// @notice Strip Solidity's trailing CBOR metadata.
    /// @dev Layout: [ ... runtime ... ][CBOR metadata blob][2 bytes big-endian length of blob].
    function _stripMetadata(
        bytes memory code
    ) internal pure returns (bytes memory) {
        if (code.length < 2) return code;
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        uint256 suffix = metaLen + 2;
        if (suffix >= code.length) return code;
        uint256 newLen = code.length - suffix;
        bytes memory out = new bytes(newLen);
        for (uint256 i = 0; i < newLen; i++) {
            out[i] = code[i];
        }
        return out;
    }

    // ========================================================================
    // ASSERT HELPERS
    // ========================================================================

    function _checkAddr(
        string memory label,
        address got,
        address want
    ) internal pure {
        if (got != want) {
            revert(string.concat("mismatch: ", label));
        }
    }

    function _checkUint(
        string memory label,
        uint256 got,
        uint256 want
    ) internal pure {
        if (got != want) {
            revert(string.concat("mismatch: ", label));
        }
    }

    // ========================================================================
    // BANNER
    // ========================================================================

    function _banner(
        Expected memory e,
        Deployed memory d
    ) internal view {
        console.log("=========================================================");
        console.log("       Gravity Bridge - Mainnet Deployment Verifier       ");
        console.log("=========================================================");
        console.log("chainId                      :", block.chainid);
        console.log("GravityPortal (on-chain)     :", d.portal);
        console.log("GBridgeSender (on-chain)     :", d.sender);
        console.log("expected final owner         :", e.owner);
        if (e.deployer != address(0)) {
            console.log("expected deployer (temp)     :", e.deployer);
        }
        console.log("expected feeRecipient        :", e.feeRecipient);
        console.log("expected G token             :", e.gToken);
        console.log("expected baseFee wei         :", e.baseFee);
        console.log("expected feePerByte wei      :", e.feePerByte);
        console.log("=========================================================");
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
}
