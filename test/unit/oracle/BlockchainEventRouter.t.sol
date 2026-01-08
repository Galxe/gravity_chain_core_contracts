// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { BlockchainEventRouter } from "@src/oracle/evm/BlockchainEventRouter.sol";
import { IBlockchainEventRouter, IMessageHandler } from "@src/oracle/evm/IBlockchainEventRouter.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { Errors } from "@src/foundation/Errors.sol";

/// @title MockMessageHandler
/// @notice Mock handler for testing
contract MockMessageHandler is IMessageHandler {
    uint32 public lastSourceType;
    uint256 public lastSourceId;
    uint128 public lastOracleNonce;
    address public lastSender;
    uint256 public lastEventNonce;
    bytes public lastMessage;
    uint256 public callCount;
    bool public shouldRevert;
    bool public shouldConsumeAllGas;

    function handleMessage(
        uint32 sourceType,
        uint256 sourceId,
        uint128 oracleNonce,
        address sender,
        uint256 eventNonce,
        bytes calldata message
    ) external override {
        if (shouldRevert) {
            revert("MockHandler: intentional revert");
        }
        if (shouldConsumeAllGas) {
            while (true) { }
        }

        lastSourceType = sourceType;
        lastSourceId = sourceId;
        lastOracleNonce = oracleNonce;
        lastSender = sender;
        lastEventNonce = eventNonce;
        lastMessage = message;
        callCount++;
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setConsumeAllGas(bool _shouldConsumeAllGas) external {
        shouldConsumeAllGas = _shouldConsumeAllGas;
    }
}

/// @title BlockchainEventRouterTest
/// @notice Unit tests for BlockchainEventRouter contract
contract BlockchainEventRouterTest is Test {
    BlockchainEventRouter public router;
    MockMessageHandler public mockHandler;

    address public genesis;
    address public governance;
    address public nativeOracle;
    address public gTokenBridge;
    address public alice;

    uint32 public constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint256 public constant ETHEREUM_SOURCE_ID = 1;

    function setUp() public {
        genesis = SystemAddresses.GENESIS;
        governance = SystemAddresses.GOVERNANCE;
        nativeOracle = SystemAddresses.NATIVE_ORACLE;
        gTokenBridge = makeAddr("gTokenBridge");
        alice = makeAddr("alice");

        // Deploy router
        router = new BlockchainEventRouter();

        // Deploy mock handler
        mockHandler = new MockMessageHandler();

        // Initialize router
        vm.prank(genesis);
        router.initialize();
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public view {
        assertTrue(router.isInitialized());
    }

    function test_Initialize_RevertWhenNotGenesis() public {
        BlockchainEventRouter newRouter = new BlockchainEventRouter();

        vm.prank(alice);
        vm.expectRevert();
        newRouter.initialize();
    }

    function test_Initialize_RevertWhenAlreadyInitialized() public {
        vm.prank(genesis);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        router.initialize();
    }

    // ========================================================================
    // HANDLER REGISTRATION TESTS
    // ========================================================================

    function test_RegisterHandler() public {
        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit IBlockchainEventRouter.HandlerRegistered(gTokenBridge, address(mockHandler));
        router.registerHandler(gTokenBridge, address(mockHandler));

        assertEq(router.getHandler(gTokenBridge), address(mockHandler));
    }

    function test_RegisterHandler_RevertWhenNotGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        router.registerHandler(gTokenBridge, address(mockHandler));
    }

    function test_RegisterHandler_RevertWhenNotInitialized() public {
        BlockchainEventRouter newRouter = new BlockchainEventRouter();

        vm.prank(governance);
        vm.expectRevert(IBlockchainEventRouter.RouterNotInitialized.selector);
        newRouter.registerHandler(gTokenBridge, address(mockHandler));
    }

    function test_UnregisterHandler() public {
        // First register
        vm.prank(governance);
        router.registerHandler(gTokenBridge, address(mockHandler));

        // Then unregister
        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit IBlockchainEventRouter.HandlerUnregistered(gTokenBridge);
        router.unregisterHandler(gTokenBridge);

        assertEq(router.getHandler(gTokenBridge), address(0));
    }

    function test_UnregisterHandler_RevertWhenNotGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        router.unregisterHandler(gTokenBridge);
    }

    // ========================================================================
    // ORACLE CALLBACK TESTS
    // ========================================================================

    function test_OnOracleEvent_RoutesToHandler() public {
        // Register handler
        vm.prank(governance);
        router.registerHandler(gTokenBridge, address(mockHandler));

        // Create payload: (sender, eventNonce, message)
        bytes memory message = abi.encode(uint256(100), alice);
        bytes memory payload = abi.encode(gTokenBridge, uint256(42), message);
        uint128 oracleNonce = 1000;

        // Call from NativeOracle
        vm.prank(nativeOracle);
        vm.expectEmit(true, true, true, true);
        emit IBlockchainEventRouter.MessageRouted(
            SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, gTokenBridge, address(mockHandler)
        );
        router.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        // Verify handler received the message
        assertEq(mockHandler.lastSourceType(), SOURCE_TYPE_BLOCKCHAIN);
        assertEq(mockHandler.lastSourceId(), ETHEREUM_SOURCE_ID);
        assertEq(mockHandler.lastOracleNonce(), oracleNonce);
        assertEq(mockHandler.lastSender(), gTokenBridge);
        assertEq(mockHandler.lastEventNonce(), 42);
        assertEq(mockHandler.callCount(), 1);
    }

    function test_OnOracleEvent_RevertWhenNotOracle() public {
        vm.prank(alice);
        vm.expectRevert(IBlockchainEventRouter.OnlyNativeOracle.selector);
        router.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, hex"");
    }

    function test_OnOracleEvent_NoHandlerRegistered() public {
        // Don't register any handler
        bytes memory payload = abi.encode(gTokenBridge, uint256(42), hex"1234");
        uint128 oracleNonce = 1000;

        vm.prank(nativeOracle);
        vm.expectEmit(true, true, true, false);
        emit IBlockchainEventRouter.RoutingFailed(
            SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, gTokenBridge, abi.encodePacked("No handler registered")
        );
        router.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);
    }

    function test_OnOracleEvent_HandlerReverts() public {
        // Register handler that reverts
        vm.prank(governance);
        router.registerHandler(gTokenBridge, address(mockHandler));
        mockHandler.setRevert(true);

        bytes memory payload = abi.encode(gTokenBridge, uint256(42), hex"1234");
        uint128 oracleNonce = 1000;

        // Should emit RoutingFailed but not revert
        vm.prank(nativeOracle);
        vm.expectEmit(true, true, true, false);
        emit IBlockchainEventRouter.RoutingFailed(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, gTokenBridge, hex"");
        router.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        // Handler was not successfully called
        assertEq(mockHandler.callCount(), 0);
    }

    function test_OnOracleEvent_HandlerOutOfGas() public {
        // Register handler that consumes all gas
        vm.prank(governance);
        router.registerHandler(gTokenBridge, address(mockHandler));
        mockHandler.setConsumeAllGas(true);

        bytes memory payload = abi.encode(gTokenBridge, uint256(42), hex"1234");
        uint128 oracleNonce = 1000;

        // Should emit RoutingFailed but not revert
        vm.prank(nativeOracle);
        vm.expectEmit(true, true, true, false);
        emit IBlockchainEventRouter.RoutingFailed(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, gTokenBridge, hex"");
        router.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);
    }

    function test_OnOracleEvent_RevertWhenNotInitialized() public {
        BlockchainEventRouter newRouter = new BlockchainEventRouter();

        vm.prank(nativeOracle);
        vm.expectRevert(IBlockchainEventRouter.RouterNotInitialized.selector);
        newRouter.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1000, hex"");
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_RegisterMultipleHandlers(address[5] calldata senders, address[5] calldata handlers) public {
        for (uint256 i = 0; i < 5; i++) {
            if (handlers[i] != address(0)) {
                vm.prank(governance);
                router.registerHandler(senders[i], handlers[i]);
                assertEq(router.getHandler(senders[i]), handlers[i]);
            }
        }
    }

    function testFuzz_OnOracleEvent(address sender, uint256 eventNonce, bytes calldata message) public {
        // Register handler
        vm.prank(governance);
        router.registerHandler(sender, address(mockHandler));

        bytes memory payload = abi.encode(sender, eventNonce, message);
        uint128 oracleNonce = 1000;

        vm.prank(nativeOracle);
        router.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, oracleNonce, payload);

        assertEq(mockHandler.lastSender(), sender);
        assertEq(mockHandler.lastEventNonce(), eventNonce);
        assertEq(mockHandler.callCount(), 1);
    }
}
