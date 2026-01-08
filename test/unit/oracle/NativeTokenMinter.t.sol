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
    address public router;
    address public trustedBridge;
    address public alice;
    address public bob;

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
        uint256 nonce = 42;
        bytes memory message = abi.encode(amount, alice);
        bytes32 dataHash = keccak256(abi.encode(trustedBridge, nonce, message));

        // Mock the precompile behavior by directly updating the mock's storage
        // In a real test, the precompile would be called
        vm.prank(router);
        vm.expectEmit(true, true, true, true);
        emit INativeTokenMinter.NativeMinted(alice, amount, nonce);
        minter.handleMessage(dataHash, trustedBridge, nonce, message);

        assertTrue(minter.isProcessed(nonce));
    }

    function test_HandleMessage_RevertWhenNotRouter() public {
        bytes memory message = abi.encode(uint256(100), alice);
        bytes32 dataHash = keccak256(message);

        vm.prank(alice);
        vm.expectRevert(INativeTokenMinter.OnlyRouter.selector);
        minter.handleMessage(dataHash, trustedBridge, 0, message);
    }

    function test_HandleMessage_RevertWhenInvalidSender() public {
        address fakeBridge = makeAddr("fakeBridge");
        bytes memory message = abi.encode(uint256(100), alice);
        bytes32 dataHash = keccak256(message);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.InvalidSender.selector, fakeBridge, trustedBridge));
        minter.handleMessage(dataHash, fakeBridge, 0, message);
    }

    function test_HandleMessage_RevertWhenAlreadyProcessed() public {
        uint256 amount = 100 ether;
        uint256 nonce = 42;
        bytes memory message = abi.encode(amount, alice);
        bytes32 dataHash = keccak256(message);

        // First call succeeds
        vm.prank(router);
        minter.handleMessage(dataHash, trustedBridge, nonce, message);

        // Second call with same nonce fails
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.AlreadyProcessed.selector, nonce));
        minter.handleMessage(dataHash, trustedBridge, nonce, message);
    }

    function test_HandleMessage_RevertWhenNotInitialized() public {
        NativeTokenMinter newMinter = new NativeTokenMinter(trustedBridge);
        bytes memory message = abi.encode(uint256(100), alice);
        bytes32 dataHash = keccak256(message);

        vm.prank(router);
        vm.expectRevert(INativeTokenMinter.MinterNotInitialized.selector);
        newMinter.handleMessage(dataHash, trustedBridge, 0, message);
    }

    function test_HandleMessage_DifferentNonces() public {
        uint256 amount = 100 ether;

        for (uint256 i = 0; i < 5; i++) {
            bytes memory message = abi.encode(amount, alice);
            bytes32 dataHash = keccak256(abi.encode(trustedBridge, i, message));

            vm.prank(router);
            minter.handleMessage(dataHash, trustedBridge, i, message);

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
        bytes32 dataHash = keccak256(message);

        vm.prank(router);
        minter.handleMessage(dataHash, trustedBridge, 123, message);

        assertTrue(minter.isProcessed(123));
    }

    function test_TrustedBridge() public view {
        assertEq(minter.trustedBridge(), trustedBridge);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_HandleMessage(
        uint256 amount,
        address recipient,
        uint256 nonce
    ) public {
        vm.assume(recipient != address(0));
        vm.assume(!minter.isProcessed(nonce));

        bytes memory message = abi.encode(amount, recipient);
        bytes32 dataHash = keccak256(abi.encode(trustedBridge, nonce, message));

        vm.prank(router);
        minter.handleMessage(dataHash, trustedBridge, nonce, message);

        assertTrue(minter.isProcessed(nonce));
    }

    function testFuzz_ReplayProtection(
        uint256 nonce
    ) public {
        bytes memory message = abi.encode(uint256(100), alice);
        bytes32 dataHash = keccak256(message);

        // First call succeeds
        vm.prank(router);
        minter.handleMessage(dataHash, trustedBridge, nonce, message);

        // Second call fails
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(INativeTokenMinter.AlreadyProcessed.selector, nonce));
        minter.handleMessage(dataHash, trustedBridge, nonce, message);
    }
}

