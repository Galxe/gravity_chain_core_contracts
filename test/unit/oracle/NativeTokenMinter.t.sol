// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeTokenMinter } from "@src/oracle/evm/native_token_bridge/NativeTokenMinter.sol";
import { INativeTokenMinter, INativeMintPrecompile } from "@src/oracle/evm/native_token_bridge/INativeTokenMinter.sol";
import { BlockchainEventHandler } from "@src/oracle/evm/BlockchainEventHandler.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { Errors } from "@src/foundation/Errors.sol";

/// @title MockNativeMintPrecompile
/// @notice Mock precompile for testing native token minting
contract MockNativeMintPrecompile is INativeMintPrecompile {
    mapping(address => uint256) public balances;
    uint256 public totalMinted;
    bool public shouldFail;

    function mint(
        address recipient,
        uint256 amount
    ) external override {
        if (shouldFail) {
            revert("MockPrecompile: mint failed");
        }
        balances[recipient] += amount;
        totalMinted += amount;
    }

    function setFail(
        bool _shouldFail
    ) external {
        shouldFail = _shouldFail;
    }
}

/// @title NativeTokenMinterTest
/// @notice Unit tests for NativeTokenMinter contract
contract NativeTokenMinterTest is Test {
    NativeTokenMinter public minter;
    MockNativeMintPrecompile public mockPrecompile;

    address public genesis;
    address public nativeOracle;
    address public trustedBridge;
    address public alice;
    address public bob;

    uint32 public constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint256 public constant ETHEREUM_SOURCE_ID = 1;

    function setUp() public {
        genesis = SystemAddresses.GENESIS;
        nativeOracle = SystemAddresses.NATIVE_ORACLE;
        trustedBridge = makeAddr("gTokenBridge");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy mock precompile at the expected address
        mockPrecompile = new MockNativeMintPrecompile();
        vm.etch(address(0x0000000000000000000000000001625F2100), address(mockPrecompile).code);

        // Deploy minter with trusted bridge
        minter = new NativeTokenMinter(trustedBridge);

        // Initialize minter
        vm.prank(genesis);
        minter.initialize();
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
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public view {
        assertTrue(minter.isInitialized());
        assertEq(minter.trustedBridge(), trustedBridge);
    }

    function test_Initialize_RevertWhenNotGenesis() public {
        NativeTokenMinter newMinter = new NativeTokenMinter(trustedBridge);

        vm.prank(alice);
        vm.expectRevert();
        newMinter.initialize();
    }

    function test_Initialize_RevertWhenAlreadyInitialized() public {
        vm.prank(genesis);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        minter.initialize();
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
        emit INativeTokenMinter.NativeMinted(alice, amount, messageNonce);
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        assertTrue(minter.isProcessed(messageNonce));
    }

    function test_OnOracleEvent_RevertWhenNotNativeOracle() public {
        bytes memory payload = _createOraclePayload(trustedBridge, 0, 100, alice);

        vm.prank(alice);
        vm.expectRevert(BlockchainEventHandler.OnlyNativeOracle.selector);
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenInvalidSender() public {
        address fakeBridge = makeAddr("fakeBridge");
        bytes memory payload = _createOraclePayload(fakeBridge, 0, 100, alice);

        vm.prank(nativeOracle);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.InvalidSender.selector, fakeBridge, trustedBridge));
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_RevertWhenAlreadyProcessed() public {
        uint256 amount = 100 ether;
        uint128 messageNonce = 42;
        uint128 oracleNonce = 1000;
        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, amount, alice);

        // First call succeeds
        vm.prank(nativeOracle);
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        // Second call with same message nonce fails
        vm.prank(nativeOracle);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.AlreadyProcessed.selector, messageNonce));
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce + 1, payload);
    }

    function test_OnOracleEvent_RevertWhenNotInitialized() public {
        NativeTokenMinter newMinter = new NativeTokenMinter(trustedBridge);
        bytes memory payload = _createOraclePayload(trustedBridge, 0, 100, alice);

        vm.prank(nativeOracle);
        vm.expectRevert(INativeTokenMinter.MinterNotInitialized.selector);
        newMinter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);
    }

    function test_OnOracleEvent_DifferentNonces() public {
        uint256 amount = 100 ether;

        for (uint128 i = 0; i < 5; i++) {
            bytes memory payload = _createOraclePayload(trustedBridge, i, amount, alice);
            uint128 oracleNonce = 1000 + i;

            vm.prank(nativeOracle);
            minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

            assertTrue(minter.isProcessed(i));
        }
    }

    // ========================================================================
    // VIEW TESTS
    // ========================================================================

    function test_IsProcessed_False() public view {
        assertFalse(minter.isProcessed(999));
    }

    function test_IsProcessed_True() public {
        bytes memory payload = _createOraclePayload(trustedBridge, 123, 100, alice);

        vm.prank(nativeOracle);
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, payload);

        assertTrue(minter.isProcessed(123));
    }

    function test_TrustedBridge() public view {
        assertEq(minter.trustedBridge(), trustedBridge);
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
        vm.assume(!minter.isProcessed(messageNonce));

        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, amount, recipient);
        uint128 oracleNonce = 1000;

        vm.prank(nativeOracle);
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        assertTrue(minter.isProcessed(messageNonce));
    }

    function testFuzz_ReplayProtection(
        uint128 messageNonce
    ) public {
        bytes memory payload = _createOraclePayload(trustedBridge, messageNonce, 100, alice);
        uint128 oracleNonce = 1000;

        // First call succeeds
        vm.prank(nativeOracle);
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        // Second call fails
        vm.prank(nativeOracle);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.AlreadyProcessed.selector, messageNonce));
        minter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce + 1, payload);
    }
}
