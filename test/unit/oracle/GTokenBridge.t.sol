// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GTokenBridge, IERC20 } from "../../../src/oracle/GTokenBridge.sol";
import { IGTokenBridge } from "../../../src/oracle/IGTokenBridge.sol";
import { GravityPortal } from "../../../src/oracle/GravityPortal.sol";
import { IGravityPortal } from "../../../src/oracle/IGravityPortal.sol";

/// @title MockERC20
/// @notice Mock ERC20 token for testing
contract MockERC20 {
    string public name = "Mock G Token";
    string public symbol = "G";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

/// @title GTokenBridgeTest
/// @notice Unit tests for GTokenBridge contract (deployed on Ethereum)
contract GTokenBridgeTest is Test {
    GTokenBridge public bridge;
    GravityPortal public portal;
    MockERC20 public gToken;

    address public owner;
    address public feeRecipient;
    address public alice;
    address public bob;

    uint256 public constant INITIAL_BASE_FEE = 0.001 ether;
    uint256 public constant INITIAL_FEE_PER_BYTE = 100 wei;
    uint256 public constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy mock G token
        gToken = new MockERC20();

        // Deploy portal
        portal = new GravityPortal(
            owner,
            INITIAL_BASE_FEE,
            INITIAL_FEE_PER_BYTE,
            feeRecipient
        );

        // Deploy bridge
        bridge = new GTokenBridge(address(gToken), address(portal));

        // Mint tokens to alice
        gToken.mint(alice, INITIAL_BALANCE);

        // Fund alice with ETH for fees
        vm.deal(alice, 100 ether);
    }

    // ========================================================================
    // CONSTRUCTOR TESTS
    // ========================================================================

    function test_Constructor() public view {
        assertEq(bridge.gToken(), address(gToken));
        assertEq(bridge.gravityPortal(), address(portal));
    }

    function test_Constructor_RevertWhenZeroGToken() public {
        vm.expectRevert(IGTokenBridge.ZeroRecipient.selector);
        new GTokenBridge(address(0), address(portal));
    }

    function test_Constructor_RevertWhenZeroPortal() public {
        vm.expectRevert(IGTokenBridge.ZeroRecipient.selector);
        new GTokenBridge(address(gToken), address(0));
    }

    // ========================================================================
    // BRIDGE TESTS
    // ========================================================================

    function test_BridgeToGravity() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);

        // Approve bridge to spend tokens
        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);

        // Bridge
        uint256 nonce = bridge.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();

        // Verify
        assertEq(nonce, 0);
        assertEq(gToken.balanceOf(alice), INITIAL_BALANCE - amount);
        assertEq(gToken.balanceOf(address(bridge)), amount);
        assertEq(portal.nonce(), 1);
    }

    function test_BridgeToGravity_EmitsEvent() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);

        vm.expectEmit(true, true, true, true);
        emit IGTokenBridge.TokensLocked(alice, bob, amount, 0);
        bridge.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();
    }

    function test_BridgeToGravity_RevertWhenZeroAmount() public {
        uint256 fee = bridge.calculateBridgeFee(0, bob);

        vm.prank(alice);
        vm.expectRevert(IGTokenBridge.ZeroAmount.selector);
        bridge.bridgeToGravity{ value: fee }(0, bob);
    }

    function test_BridgeToGravity_RevertWhenZeroRecipient() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, address(0));

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);

        vm.expectRevert(IGTokenBridge.ZeroRecipient.selector);
        bridge.bridgeToGravity{ value: fee }(amount, address(0));
        vm.stopPrank();
    }

    function test_BridgeToGravity_RevertWhenInsufficientAllowance() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);

        // Don't approve - should revert
        vm.prank(alice);
        vm.expectRevert(); // Mock ERC20 reverts with custom message
        bridge.bridgeToGravity{ value: fee }(amount, bob);
    }

    function test_BridgeToGravity_RevertWhenInsufficientBalance() public {
        uint256 amount = INITIAL_BALANCE + 1; // More than alice has
        uint256 fee = bridge.calculateBridgeFee(amount, bob);

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);

        vm.expectRevert(); // Mock ERC20 reverts with custom message
        bridge.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();
    }

    function test_BridgeToGravity_RevertWhenInsufficientFee() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);

        // Send less than required fee
        vm.expectRevert();
        bridge.bridgeToGravity{ value: fee - 1 }(amount, bob);
        vm.stopPrank();
    }

    function test_BridgeToGravity_MultipleBridges() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount * 3);

        assertEq(bridge.bridgeToGravity{ value: fee }(amount, bob), 0);
        assertEq(bridge.bridgeToGravity{ value: fee }(amount, bob), 1);
        assertEq(bridge.bridgeToGravity{ value: fee }(amount, bob), 2);
        vm.stopPrank();

        assertEq(gToken.balanceOf(address(bridge)), amount * 3);
        assertEq(portal.nonce(), 3);
    }

    // ========================================================================
    // FEE CALCULATION TESTS
    // ========================================================================

    function test_CalculateBridgeFee() public view {
        uint256 amount = 100 ether;
        address recipient = bob;

        uint256 fee = bridge.calculateBridgeFee(amount, recipient);

        // Message is abi.encode(amount, recipient) = 64 bytes
        uint256 expectedFee = portal.calculateFee(64);
        assertEq(fee, expectedFee);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_BridgeToGravity(uint256 amount, address recipient) public {
        amount = bound(amount, 1, INITIAL_BALANCE);
        vm.assume(recipient != address(0));

        uint256 fee = bridge.calculateBridgeFee(amount, recipient);

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);
        uint256 nonce = bridge.bridgeToGravity{ value: fee }(amount, recipient);
        vm.stopPrank();

        assertEq(nonce, 0);
        assertEq(gToken.balanceOf(alice), INITIAL_BALANCE - amount);
        assertEq(gToken.balanceOf(address(bridge)), amount);
    }
}

