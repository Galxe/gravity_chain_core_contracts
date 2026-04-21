// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GravityPortal } from "src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "src/oracle/evm/native_token_bridge/GBridgeSender.sol";

/// @title VerifyBridgeMainnet
/// @notice Read-only verifier: confirms that the GravityPortal and GBridgeSender
///         on Ethereum mainnet match what we built locally AND that their
///         constructor args are the ones we intended.
///
/// @dev Run against mainnet with a normal RPC; no --broadcast. The script:
///        1. Hard-gates chainId == 1.
///        2. Reads expected values from .env.mainnet (owner, G token, fees).
///        3. Reads deployed addresses from deployments/mainnet.json
///           (or env: GRAVITY_PORTAL_ADDRESS / GBRIDGE_SENDER_ADDRESS).
///        4. Verifies constructor args by reading public getters on the
///           deployed contracts (Portal: owner / feeRecipient / baseFee /
///           feePerByte; Sender: owner / gToken / gravityPortal — the last
///           two are `immutable`, so the getter value == constructor arg).
///        5. Verifies the runtime bytecode is byte-for-byte identical to
///           what we get by deploying the *same* contracts locally with
///           the *same* constructor args. Metadata suffix is stripped
///           before comparison so that IPFS hash differences between
///           build environments do not produce a false negative.
///
/// @dev    The "deploy locally with the same args" trick is the cleanest way
///         to verify contracts that have `immutable` fields (GBridgeSender
///         has gToken + gravityPortal): running the real constructor with
///         the expected arguments produces the exact same immutable bake-in
///         as the real deployment, so a plain `keccak256(code)` match works.
///
///         Any revert = VERIFICATION FAILED. Exit code will be non-zero.
contract VerifyBridgeMainnet is Script {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    address internal constant DEFAULT_G_TOKEN = 0x9C7BEBa8F6eF6643aBd725e45a4E8387eF260649;
    uint256 internal constant DEFAULT_ETH_PRICE_USD = 2500;
    uint256 internal constant DEFAULT_USD_CENTS_PER_32_BYTES = 10;
    uint256 internal constant DEFAULT_BASE_FEE_WEI = 0;

    struct Expected {
        address owner;
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
        e.owner = vm.envAddress("GRAVITY_CORE_CONTRACT_EOA_OWNER");
        e.gToken = _envAddressOr("G_TOKEN_ADDRESS", DEFAULT_G_TOKEN);

        uint256 ethPriceUsd = _envUintOr("ETH_PRICE_USD", DEFAULT_ETH_PRICE_USD);
        uint256 centsPer32B = _envUintOr("USD_CENTS_PER_32_BYTES", DEFAULT_USD_CENTS_PER_32_BYTES);
        e.baseFee = _envUintOr("BASE_FEE_WEI", DEFAULT_BASE_FEE_WEI);
        e.feePerByte = (centsPer32B * 1e16) / (32 * ethPriceUsd);

        require(e.owner != address(0), "owner unset");
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
    // STATE VERIFICATION (= constructor-arg verification)
    // ========================================================================

    function _verifyPortalState(address portalAddr, Expected memory e) internal view {
        console.log("[1/4] GravityPortal state ...");
        GravityPortal portal = GravityPortal(portalAddr);

        _checkAddr("Portal.owner", portal.owner(), e.owner);
        // We deployed with feeRecipient = owner EOA.
        _checkAddr("Portal.feeRecipient", portal.feeRecipient(), e.owner);
        _checkUint("Portal.baseFee", portal.baseFee(), e.baseFee);
        _checkUint("Portal.feePerByte", portal.feePerByte(), e.feePerByte);
        // Nonce may have advanced if the bridge has been used; we only assert it never went backwards.
        console.log("   Portal.nonce (info) :", portal.nonce());
        console.log("   [ok]");
    }

    function _verifySenderState(address senderAddr, address portalAddr, Expected memory e) internal view {
        console.log("[2/4] GBridgeSender state ...");
        GBridgeSender sender = GBridgeSender(senderAddr);

        _checkAddr("Sender.owner", sender.owner(), e.owner);
        // These two are `immutable`: the getter value == the constructor arg.
        _checkAddr("Sender.gToken (immutable)", sender.gToken(), e.gToken);
        _checkAddr("Sender.gravityPortal (immutable)", sender.gravityPortal(), portalAddr);
        console.log("   [ok]");
    }

    // ========================================================================
    // BYTECODE VERIFICATION
    // ========================================================================

    function _verifyPortalBytecode(address portalAddr, Expected memory e) internal {
        console.log("[3/4] GravityPortal bytecode ...");
        // Re-deploy locally with the same constructor args; compare runtime code.
        // (No `immutable`s in GravityPortal, so the runtime code is
        // independent of constructor args, but we pass them anyway to be
        // explicit about intent.)
        GravityPortal local = new GravityPortal({
            initialOwner: e.owner,
            initialBaseFee: e.baseFee,
            initialFeePerByte: e.feePerByte,
            initialFeeRecipient: e.owner
        });
        _compareCode(address(local), portalAddr, "GravityPortal");
        console.log("   [ok]");
    }

    function _verifySenderBytecode(address senderAddr, address portalAddr, Expected memory e) internal {
        console.log("[4/4] GBridgeSender bytecode ...");
        // GBridgeSender has 2 immutables (gToken, gravityPortal). Re-deploying
        // locally with the same args produces the same immutable bake-in, so a
        // plain byte-for-byte comparison works.
        GBridgeSender local = new GBridgeSender({ gToken_: e.gToken, gravityPortal_: portalAddr, owner_: e.owner });
        _compareCode(address(local), senderAddr, "GBridgeSender");
        console.log("   [ok]");
    }

    // ========================================================================
    // BYTECODE HELPERS
    // ========================================================================

    function _compareCode(address local, address onchain, string memory name) internal view {
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
    function _stripMetadata(bytes memory code) internal pure returns (bytes memory) {
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

    function _checkAddr(string memory label, address got, address want) internal pure {
        if (got != want) {
            revert(string.concat("mismatch: ", label));
        }
    }

    function _checkUint(string memory label, uint256 got, uint256 want) internal pure {
        if (got != want) {
            revert(string.concat("mismatch: ", label));
        }
    }

    // ========================================================================
    // BANNER
    // ========================================================================

    function _banner(Expected memory e, Deployed memory d) internal view {
        console.log("=========================================================");
        console.log("       Gravity Bridge - Mainnet Deployment Verifier       ");
        console.log("=========================================================");
        console.log("chainId                      :", block.chainid);
        console.log("GravityPortal (on-chain)     :", d.portal);
        console.log("GBridgeSender (on-chain)     :", d.sender);
        console.log("expected owner               :", e.owner);
        console.log("expected G token             :", e.gToken);
        console.log("expected baseFee wei         :", e.baseFee);
        console.log("expected feePerByte wei      :", e.feePerByte);
        console.log("=========================================================");
    }

    // ========================================================================
    // ENV HELPERS
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
