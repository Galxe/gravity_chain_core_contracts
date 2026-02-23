// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GBridgeReceiver } from "@src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";
import { IGBridgeReceiver, INativeMintPrecompile } from "@src/oracle/evm/native_token_bridge/IGBridgeReceiver.sol";
import { BlockchainEventHandler } from "@src/oracle/evm/BlockchainEventHandler.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
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

        // Deploy receiver with trusted bridge and source chain ID
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

        assertTrue(receiver.isProcessed(messageNonce));
    }

    function test_OnOracleEvent_RevertWhenNotNativeOracle() public {
        bytes memory payload = _createOraclePayload(trustedBridge, 0, 100, alice);

        vm.prank(alice);
        vm.expectRevert(BlockchainEventHandler.OnlyNativeOracle.selector);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenInvalidSender() public {
        address fakeBridge = makeAddr("fakeBridge");
        bytes memory payload = _createOraclePayload(fakeBridge, 0, 100, alice);

        vm.prank(nativeOracle);
        vm.expectRevert(abi.encodeWithSelector(IGBridgeReceiver.InvalidSender.selector, fakeBridge, trustedBridge));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenAlreadyProcessed() public {
        uint256 amount = 100 ether;
        uint128 messageNonce = 42;
        uint128 oracleNonce = 1000;
        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, amount, alice);

        // First call succeeds
        vm.prank(nativeOracle);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        // Second call with same message nonce fails
        vm.prank(nativeOracle);
        vm.expectRevert(abi.encodeWithSelector(IGBridgeReceiver.AlreadyProcessed.selector, messageNonce));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce + 1, payload);
    }

    function test_OnOracleEvent_DifferentNonces() public {
        uint256 amount = 100 ether;

        for (uint128 i = 0; i < 5; i++) {
            bytes memory payload = _createOraclePayload(trustedBridge, i, amount, alice);
            uint128 oracleNonce = 1000 + i;

            vm.prank(nativeOracle);
            receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

            assertTrue(receiver.isProcessed(i));
        }
    }

    // ========================================================================
    // VIEW TESTS
    // ========================================================================

    function test_IsProcessed_False() public view {
        assertFalse(receiver.isProcessed(999));
    }

    function test_IsProcessed_True() public {
        bytes memory payload = _createOraclePayload(trustedBridge, 123, 100, alice);

        vm.prank(nativeOracle);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        assertTrue(receiver.isProcessed(123));
    }

    function test_TrustedBridge() public view {
        assertEq(receiver.trustedBridge(), trustedBridge);
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
        vm.assume(!receiver.isProcessed(messageNonce));

        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, amount, recipient);
        uint128 oracleNonce = 1000;

        vm.prank(nativeOracle);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        assertTrue(receiver.isProcessed(messageNonce));
    }

    function testFuzz_ReplayProtection(
        uint128 messageNonce
    ) public {
        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, 100, alice);
        uint128 oracleNonce = 1000;

        // First call succeeds
        vm.prank(nativeOracle);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        // Second call fails
        vm.prank(nativeOracle);
        vm.expectRevert(abi.encodeWithSelector(IGBridgeReceiver.AlreadyProcessed.selector, messageNonce));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce + 1, payload);
    }
}

