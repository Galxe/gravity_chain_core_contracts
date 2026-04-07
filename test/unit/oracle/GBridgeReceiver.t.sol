// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GBridgeReceiver } from "@src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";
import { IGBridgeReceiver, INativeMintPrecompile } from "@src/oracle/evm/native_token_bridge/IGBridgeReceiver.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { NotAllowed } from "@src/foundation/SystemAccessControl.sol";
import { Errors } from "@src/foundation/Errors.sol";

/// @title MockNativeMintPrecompile
/// @notice Mock precompile for testing native token minting
contract MockNativeMintPrecompile is INativeMintPrecompile {
    mapping(address => uint256) public balances;
    uint256 public totalMinted;

    function mint(
        address recipient,
        uint256 amount
    ) external override {
        balances[recipient] += amount;
        totalMinted += amount;
    }
}

/// @title GBridgeReceiverTest
/// @notice Unit tests for GBridgeReceiver contract
contract GBridgeReceiverTest is Test {
    GBridgeReceiver public receiver;
    MockNativeMintPrecompile public mockPrecompile;

    address public nativeOracle;
    address public trustedBridge;
    address public alice;
    address public bob;

    uint32 public constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint256 public constant ETHEREUM_SOURCE_ID = 1;

    function setUp() public {
        nativeOracle = SystemAddresses.NATIVE_ORACLE;
        trustedBridge = makeAddr("gBridgeSender");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Mock the precompile call to always succeed
        // GBridgeReceiver uses low-level call:
        // NATIVE_MINT_PRECOMPILE.call(abi.encodePacked(uint8(0x01), recipient, amount))
        // We mock any call to this address to return (true, "")
        bytes memory emptyData = "";
        bytes memory successReturn = "";
        vm.mockCall(SystemAddresses.NATIVE_MINT_PRECOMPILE, emptyData, successReturn);

        // Deploy receiver with trusted bridge
        receiver = new GBridgeReceiver(trustedBridge, ETHEREUM_SOURCE_ID);
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    /// @notice Create an oracle payload from portal message components
    function _createOraclePayload(
        address sender,
        uint128 messageNonce,
        uint256 amount,
        address recipient
    ) internal pure returns (bytes memory) {
        bytes memory message = abi.encode(amount, recipient);
        return PortalMessage.encode(sender, messageNonce, message);
    }

    // ========================================================================
    // CONSTRUCTOR TESTS
    // ========================================================================

    function test_Constructor() public view {
        assertEq(receiver.trustedBridge(), trustedBridge);
    }

    function test_Constructor_RevertWhenZeroTrustedBridge() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new GBridgeReceiver(address(0), ETHEREUM_SOURCE_ID);
    }

    // ========================================================================
    // ORACLE EVENT HANDLER TESTS
    // ========================================================================

    function test_OnOracleEvent() public {
        uint256 amount = 100 ether;
        uint128 messageNonce = 42;
        uint128 oracleNonce = 1000;
        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, amount, alice);

        vm.prank(nativeOracle);
        vm.expectEmit(true, true, true, true);
        emit IGBridgeReceiver.NativeMinted(alice, amount, messageNonce);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);
    }

    function test_OnOracleEvent_RevertWhenNotNativeOracle() public {
        bytes memory payload = _createOraclePayload(trustedBridge, 0, 100, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, alice, SystemAddresses.NATIVE_ORACLE));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenInvalidSender() public {
        address fakeBridge = makeAddr("fakeBridge");
        bytes memory payload = _createOraclePayload(fakeBridge, 0, 100, alice);

        vm.prank(nativeOracle);
        vm.expectRevert(abi.encodeWithSelector(IGBridgeReceiver.InvalidSender.selector, fakeBridge, trustedBridge));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenInvalidSourceChain() public {
        uint256 wrongSourceId = 56; // BSC instead of Ethereum
        bytes memory payload = _createOraclePayload(trustedBridge, 1, 100 ether, alice);

        vm.prank(nativeOracle);
        vm.expectRevert(
            abi.encodeWithSelector(IGBridgeReceiver.InvalidSourceChain.selector, wrongSourceId, ETHEREUM_SOURCE_ID)
        );
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, wrongSourceId, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenZeroAmount() public {
        bytes memory payload = _createOraclePayload(trustedBridge, 1, 0, alice);

        vm.prank(nativeOracle);
        vm.expectRevert(Errors.ZeroAmount.selector);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenZeroRecipient() public {
        bytes memory payload = _createOraclePayload(trustedBridge, 1, 100 ether, address(0));

        vm.prank(nativeOracle);
        vm.expectRevert(Errors.ZeroAddress.selector);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_DifferentNonces() public {
        uint256 amount = 100 ether;

        for (uint128 i = 0; i < 5; i++) {
            bytes memory payload = _createOraclePayload(trustedBridge, i, amount, alice);
            uint128 oracleNonce = 1000 + i;

            vm.prank(nativeOracle);
            receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);
        }
    }

    // ========================================================================
    // VIEW TESTS
    // ========================================================================

    function test_TrustedBridge() public view {
        assertEq(receiver.trustedBridge(), trustedBridge);
    }

    function test_TrustedSourceId() public view {
        assertEq(receiver.trustedSourceId(), ETHEREUM_SOURCE_ID);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_OnOracleEvent(
        uint256 amount,
        address recipient,
        uint128 messageNonce
    ) public {
        vm.assume(recipient != address(0));
        vm.assume(amount > 0);

        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, amount, recipient);
        uint128 oracleNonce = 1000;

        vm.prank(nativeOracle);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);
    }
}
