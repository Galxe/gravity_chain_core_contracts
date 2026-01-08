// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeTokenMinter } from "@src/oracle/evm/native_token_bridge/NativeTokenMinter.sol";
import { INativeTokenMinter, INativeMintPrecompile } from "@src/oracle/evm/native_token_bridge/INativeTokenMinter.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { Errors } from "@src/foundation/Errors.sol";

/// @title MockNativeMintPrecompile
/// @notice Mock precompile for testing native token minting
contract MockNativeMintPrecompile is INativeMintPrecompile {
    mapping(address => uint256) public balances;
    uint256 public totalMinted;
    bool public shouldFail;

    function mint(address recipient, uint256 amount) external override {
        if (shouldFail) {
            revert("MockPrecompile: mint failed");
        }
        balances[recipient] += amount;
        totalMinted += amount;
    }

    function setFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }
}

/// @title NativeTokenMinterTest
/// @notice Unit tests for NativeTokenMinter contract
contract NativeTokenMinterTest is Test {
    NativeTokenMinter public minter;
    MockNativeMintPrecompile public mockPrecompile;

    address public genesis;
    address public router;
    address public trustedBridge;
    address public alice;
    address public bob;

    uint32 public constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint256 public constant ETHEREUM_SOURCE_ID = 1;

    function setUp() public {
        genesis = SystemAddresses.GENESIS;
        router = SystemAddresses.BLOCKCHAIN_EVENT_ROUTER;
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
    // HANDLE MESSAGE TESTS
    // ========================================================================

    function test_HandleMessage() public {
        uint256 amount = 100 ether;
        uint256 eventNonce = 42;
        uint128 oracleNonce = 1000;
        bytes memory message = abi.encode(amount, alice);

        // Mock the precompile behavior by directly updating the mock's storage
        // In a real test, the precompile would be called
        vm.prank(router);
        vm.expectEmit(true, true, true, true);
        emit INativeTokenMinter.NativeMinted(alice, amount, eventNonce);
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, trustedBridge, eventNonce, message);

        assertTrue(minter.isProcessed(eventNonce));
    }

    function test_HandleMessage_RevertWhenNotRouter() public {
        bytes memory message = abi.encode(uint256(100), alice);

        vm.prank(alice);
        vm.expectRevert(INativeTokenMinter.OnlyRouter.selector);
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, trustedBridge, 0, message);
    }

    function test_HandleMessage_RevertWhenInvalidSender() public {
        address fakeBridge = makeAddr("fakeBridge");
        bytes memory message = abi.encode(uint256(100), alice);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.InvalidSender.selector, fakeBridge, trustedBridge));
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, fakeBridge, 0, message);
    }

    function test_HandleMessage_RevertWhenAlreadyProcessed() public {
        uint256 amount = 100 ether;
        uint256 eventNonce = 42;
        uint128 oracleNonce = 1000;
        bytes memory message = abi.encode(amount, alice);

        // First call succeeds
        vm.prank(router);
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, trustedBridge, eventNonce, message);

        // Second call with same nonce fails
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.AlreadyProcessed.selector, eventNonce));
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce + 1, trustedBridge, eventNonce, message);
    }

    function test_HandleMessage_RevertWhenNotInitialized() public {
        NativeTokenMinter newMinter = new NativeTokenMinter(trustedBridge);
        bytes memory message = abi.encode(uint256(100), alice);

        vm.prank(router);
        vm.expectRevert(INativeTokenMinter.MinterNotInitialized.selector);
        newMinter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, trustedBridge, 0, message);
    }

    function test_HandleMessage_DifferentNonces() public {
        uint256 amount = 100 ether;

        for (uint256 i = 0; i < 5; i++) {
            bytes memory message = abi.encode(amount, alice);
            uint128 oracleNonce = uint128(1000 + i);

            vm.prank(router);
            minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, trustedBridge, i, message);

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
        bytes memory message = abi.encode(uint256(100), alice);

        vm.prank(router);
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, trustedBridge, 123, message);

        assertTrue(minter.isProcessed(123));
    }

    function test_TrustedBridge() public view {
        assertEq(minter.trustedBridge(), trustedBridge);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_HandleMessage(uint256 amount, address recipient, uint256 eventNonce) public {
        vm.assume(recipient != address(0));
        vm.assume(!minter.isProcessed(eventNonce));

        bytes memory message = abi.encode(amount, recipient);
        uint128 oracleNonce = 1000;

        vm.prank(router);
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, trustedBridge, eventNonce, message);

        assertTrue(minter.isProcessed(eventNonce));
    }

    function testFuzz_ReplayProtection(uint256 eventNonce) public {
        bytes memory message = abi.encode(uint256(100), alice);
        uint128 oracleNonce = 1000;

        // First call succeeds
        vm.prank(router);
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, trustedBridge, eventNonce, message);

        // Second call fails
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.AlreadyProcessed.selector, eventNonce));
        minter.handleMessage(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce + 1, trustedBridge, eventNonce, message);
    }
}
