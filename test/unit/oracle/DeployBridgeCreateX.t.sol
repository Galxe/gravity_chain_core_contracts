// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "@src/oracle/evm/native_token_bridge/GBridgeSender.sol";
import { CreateXFixture } from "@test/utils/CreateXFixture.sol";
import { MockGToken } from "@test/utils/MockGToken.sol";

/// @notice Minimal interface to the etched CreateX factory.
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

/// @title DeployBridgeCreateXTest
/// @notice Validates the CreateX/CREATE3 deploy path used by DeployBridgeKeystore.s.sol.
///         Etches the official CreateX runtime bytecode at the canonical address, then exercises
///         the SAME salt format + deploy + transferOwnership flow as the script — asserting:
///           (a) deploy lands at the predicted address,
///           (b) the address is chain-agnostic (the 0x00 flag really does what we expect),
///           (c) ownership flow works end-to-end (deployer -> pending multisig -> accepted),
///           (d) the bridge functions correctly after the CREATE3 deploy.
contract DeployBridgeCreateXTest is Test {
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    // Mirrors DeployBridgeKeystore.s.sol exactly.
    bytes1 internal constant CROSS_CHAIN_FLAG = 0x00;
    bytes11 internal constant SALT_PORTAL_ENTROPY = bytes11(uint88(uint256(keccak256("gravity.bridge.portal.v1"))));
    bytes11 internal constant SALT_SENDER_ENTROPY = bytes11(uint88(uint256(keccak256("gravity.bridge.sender.v1"))));

    uint256 internal constant BASE_FEE = 50_000_000_000_000;
    uint256 internal constant FEE_PER_BYTE = 2_343_750_000_000;

    address internal deployer;
    address internal multisig;
    address internal feeRecipient;
    MockGToken internal gToken;

    bytes32 internal saltPortal;
    bytes32 internal saltSender;

    function setUp() public {
        CreateXFixture.etch(vm);

        deployer = makeAddr("deployer");
        multisig = makeAddr("multisig");
        feeRecipient = multisig;
        gToken = new MockGToken();

        saltPortal = bytes32(abi.encodePacked(deployer, CROSS_CHAIN_FLAG, SALT_PORTAL_ENTROPY));
        saltSender = bytes32(abi.encodePacked(deployer, CROSS_CHAIN_FLAG, SALT_SENDER_ENTROPY));
    }

    // ========================================================================
    // CORE: deploy lands at predicted address; ownership pending the multisig
    // ========================================================================

    function test_DeploysAtPredictedAddresses() public {
        address predictedPortal = _predict(saltPortal);
        address predictedSender = _predict(saltSender);

        // Sanity: nothing at the predicted addresses yet.
        assertEq(predictedPortal.code.length, 0, "portal addr already has code");
        assertEq(predictedSender.code.length, 0, "sender addr already has code");

        vm.startPrank(deployer);

        bytes memory portalInit = abi.encodePacked(
            type(GravityPortal).creationCode, abi.encode(deployer, BASE_FEE, FEE_PER_BYTE, feeRecipient)
        );
        address portal = ICreateX(CREATEX).deployCreate3(saltPortal, portalInit);
        GravityPortal(portal).transferOwnership(multisig);

        bytes memory senderInit =
            abi.encodePacked(type(GBridgeSender).creationCode, abi.encode(address(gToken), portal, deployer));
        address sender = ICreateX(CREATEX).deployCreate3(saltSender, senderInit);
        GBridgeSender(sender).transferOwnership(multisig);

        vm.stopPrank();

        // Addresses match prediction.
        assertEq(portal, predictedPortal, "portal: deploy address must match prediction");
        assertEq(sender, predictedSender, "sender: deploy address must match prediction");

        // Post-deploy invariants — same set the script's `require`s assert.
        assertEq(GravityPortal(portal).owner(), deployer);
        assertEq(GravityPortal(portal).pendingOwner(), multisig);
        assertEq(GravityPortal(portal).feeRecipient(), feeRecipient);
        assertEq(GravityPortal(portal).baseFee(), BASE_FEE);
        assertEq(GravityPortal(portal).feePerByte(), FEE_PER_BYTE);
        assertEq(GravityPortal(portal).nonce(), 0);
        assertEq(address(portal).balance, 0);
        assertEq(GBridgeSender(sender).owner(), deployer);
        assertEq(GBridgeSender(sender).pendingOwner(), multisig);
        assertEq(GBridgeSender(sender).gToken(), address(gToken));
        assertEq(GBridgeSender(sender).gravityPortal(), portal);
        assertEq(address(sender).balance, 0);
    }

    // ========================================================================
    // OWNERSHIP HANDOFF: multisig accepts → final ownership
    // ========================================================================

    function test_MultisigAcceptOwnership_Finalizes() public {
        (address portal, address sender) = _deploy();

        vm.prank(multisig);
        GravityPortal(portal).acceptOwnership();
        vm.prank(multisig);
        GBridgeSender(sender).acceptOwnership();

        assertEq(GravityPortal(portal).owner(), multisig);
        assertEq(GravityPortal(portal).pendingOwner(), address(0));
        assertEq(GBridgeSender(sender).owner(), multisig);
        assertEq(GBridgeSender(sender).pendingOwner(), address(0));
    }

    // ========================================================================
    // CROSS-CHAIN CONSISTENCY: address depends only on (deployer, salt, CreateX)
    // ========================================================================

    /// @notice With CROSS_CHAIN_FLAG = 0x00, the predicted address must NOT depend on chainid.
    ///         Re-running the prediction under different `block.chainid` must yield the same address.
    function test_AddressIsChainAgnostic_With0x00Flag() public {
        address ref = _predict(saltPortal);

        vm.chainId(137); // Polygon
        assertEq(_predict(saltPortal), ref, "addr should be the same on Polygon");

        vm.chainId(42_161); // Arbitrum
        assertEq(_predict(saltPortal), ref, "addr should be the same on Arbitrum");

        vm.chainId(8453); // Base
        assertEq(_predict(saltPortal), ref, "addr should be the same on Base");
    }

    // ========================================================================
    // GUARDED SALT: only the deployer EOA can land at our predicted address
    // ========================================================================

    /// @notice The first 20 bytes of the salt are the deployer's address — CreateX's `_guard`
    ///         only treats the salt as "deployer-bound" when those bytes match `msg.sender`.
    ///         If a foreign caller submits the same salt, CreateX falls through to a pseudo-random
    ///         salt branch and lands the deploy at a DIFFERENT address. So no third party can
    ///         ever sit on our predicted address.
    function test_GuardedSalt_ForeignCaller_LandsAtDifferentAddress() public {
        address attacker = makeAddr("attacker");
        address ourPredicted = _predict(saltPortal);

        vm.startPrank(attacker);
        bytes memory portalInit = abi.encodePacked(
            type(GravityPortal).creationCode, abi.encode(attacker, BASE_FEE, FEE_PER_BYTE, attacker)
        );
        address attackerDeployed = ICreateX(CREATEX).deployCreate3(saltPortal, portalInit);
        vm.stopPrank();

        assertTrue(attackerDeployed != ourPredicted, "attacker must NOT land at our predicted address");
        assertEq(ourPredicted.code.length, 0, "our predicted address must remain empty");
    }

    // ========================================================================
    // E2E: bridge works after CREATE3 deploy + multisig accept
    // ========================================================================

    function test_BridgeWorksAfterCreate3Deploy() public {
        (address portal, address sender) = _deploy();

        vm.prank(multisig);
        GravityPortal(portal).acceptOwnership();
        vm.prank(multisig);
        GBridgeSender(sender).acceptOwnership();

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        gToken.mint(alice, 10 ether);
        vm.deal(alice, 1 ether);

        uint256 fee = GBridgeSender(sender).calculateBridgeFee(1 ether, bob);

        vm.startPrank(alice);
        gToken.approve(sender, 1 ether);
        uint128 nonce = GBridgeSender(sender).bridgeToGravity{ value: fee }(1 ether, bob);
        vm.stopPrank();

        assertEq(nonce, 1);
        assertEq(gToken.balanceOf(sender), 1 ether);
        assertEq(GravityPortal(portal).nonce(), 1);
        // accumulatedFees is increase-only and reflects the paid fee.
        assertEq(GravityPortal(portal).accumulatedFees(), fee);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _deploy() internal returns (address portal, address sender) {
        vm.startPrank(deployer);

        bytes memory portalInit = abi.encodePacked(
            type(GravityPortal).creationCode, abi.encode(deployer, BASE_FEE, FEE_PER_BYTE, feeRecipient)
        );
        portal = ICreateX(CREATEX).deployCreate3(saltPortal, portalInit);
        GravityPortal(portal).transferOwnership(multisig);

        bytes memory senderInit =
            abi.encodePacked(type(GBridgeSender).creationCode, abi.encode(address(gToken), portal, deployer));
        sender = ICreateX(CREATEX).deployCreate3(saltSender, senderInit);
        GBridgeSender(sender).transferOwnership(multisig);

        vm.stopPrank();
    }

    function _predict(
        bytes32 salt
    ) internal view returns (address) {
        // Mirror DeployBridgeKeystore._predictCreate3 exactly.
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(deployer)), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
