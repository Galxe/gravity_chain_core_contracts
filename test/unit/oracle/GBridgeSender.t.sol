// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GBridgeSender } from "@src/oracle/evm/native_token_bridge/GBridgeSender.sol";
import { IGBridgeSender } from "@src/oracle/evm/native_token_bridge/IGBridgeSender.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { IGravityPortal } from "@src/oracle/evm/IGravityPortal.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";

/// @title MockERC20Permit
/// @notice Mock ERC20 token with permit support for testing
contract MockERC20Permit {
    string public name = "Mock G Token";
    string public symbol = "G";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    // EIP-712 domain separator
    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "Permit expired");

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recoveredAddress = ecrecover(digest, v, r, s);

        require(recoveredAddress != address(0) && recoveredAddress == owner, "Invalid signature");
        allowance[owner][spender] = value;
    }
}

/// @title GBridgeSenderTest
/// @notice Unit tests for GBridgeSender contract (deployed on Ethereum)
contract GBridgeSenderTest is Test {
    GBridgeSender public bridge;
    GravityPortal public portal;
    MockERC20Permit public gToken;

    address public owner;
    address public feeRecipient;
    address public alice;
    uint256 public alicePrivateKey;
    address public bob;

    uint256 public constant INITIAL_BASE_FEE = 0.001 ether;
    uint256 public constant INITIAL_FEE_PER_BYTE = 100 wei;
    uint256 public constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        alicePrivateKey = 0x1234;
        alice = vm.addr(alicePrivateKey);
        bob = makeAddr("bob");

        // Deploy mock G token with permit support
        gToken = new MockERC20Permit();

        // Deploy portal
        portal = new GravityPortal(owner, INITIAL_BASE_FEE, INITIAL_FEE_PER_BYTE, feeRecipient);

        // Deploy bridge with owner
        bridge = new GBridgeSender(address(gToken), address(portal), owner);

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
        assertEq(bridge.owner(), owner);
    }

    function test_Constructor_RevertWhenZeroGToken() public {
        vm.expectRevert(IGBridgeSender.ZeroAddress.selector);
        new GBridgeSender(address(0), address(portal), owner);
    }

    function test_Constructor_RevertWhenZeroPortal() public {
        vm.expectRevert(IGBridgeSender.ZeroAddress.selector);
        new GBridgeSender(address(gToken), address(0), owner);
    }

    // ========================================================================
    // OWNABLE2STEP TESTS
    // ========================================================================

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        // Owner initiates transfer
        vm.prank(owner);
        bridge.transferOwnership(newOwner);

        // Ownership not transferred yet
        assertEq(bridge.owner(), owner);
        assertEq(bridge.pendingOwner(), newOwner);

        // New owner accepts
        vm.prank(newOwner);
        bridge.acceptOwnership();

        // Ownership transferred
        assertEq(bridge.owner(), newOwner);
        assertEq(bridge.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        bridge.transferOwnership(bob);
    }

    function test_AcceptOwnership_RevertWhenNotPendingOwner() public {
        vm.prank(owner);
        bridge.transferOwnership(bob);

        vm.prank(alice);
        vm.expectRevert();
        bridge.acceptOwnership();
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
        uint128 nonce = bridge.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();

        // Verify
        assertEq(nonce, 1);
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
        emit IGBridgeSender.TokensLocked(alice, bob, amount, 1);
        bridge.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();
    }

    function test_BridgeToGravity_RevertWhenZeroAmount() public {
        uint256 fee = bridge.calculateBridgeFee(0, bob);

        vm.prank(alice);
        vm.expectRevert(IGBridgeSender.ZeroAmount.selector);
        bridge.bridgeToGravity{ value: fee }(0, bob);
    }

    function test_BridgeToGravity_RevertWhenZeroRecipient() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, address(0));

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);

        vm.expectRevert(IGBridgeSender.ZeroRecipient.selector);
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

        assertEq(bridge.bridgeToGravity{ value: fee }(amount, bob), 1);
        assertEq(bridge.bridgeToGravity{ value: fee }(amount, bob), 2);
        assertEq(bridge.bridgeToGravity{ value: fee }(amount, bob), 3);
        vm.stopPrank();

        assertEq(gToken.balanceOf(address(bridge)), amount * 3);
        assertEq(portal.nonce(), 3);
    }

    // ========================================================================
    // BRIDGE WITH PERMIT TESTS
    // ========================================================================

    function test_BridgeToGravityWithPermit() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        uint256 deadline = block.timestamp + 1 hours;

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(gToken.PERMIT_TYPEHASH(), alice, address(bridge), amount, gToken.nonces(alice), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gToken.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        // Bridge with permit (no prior approval needed)
        vm.deal(alice, fee);
        vm.prank(alice);
        uint128 nonce = bridge.bridgeToGravityWithPermit{ value: fee }(amount, bob, deadline, v, r, s);

        // Verify
        assertEq(nonce, 1);
        assertEq(gToken.balanceOf(alice), INITIAL_BALANCE - amount);
        assertEq(gToken.balanceOf(address(bridge)), amount);
    }

    function test_BridgeToGravityWithPermit_EmitsEvent() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(gToken.PERMIT_TYPEHASH(), alice, address(bridge), amount, gToken.nonces(alice), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gToken.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        vm.deal(alice, fee);
        vm.prank(alice);

        vm.expectEmit(true, true, true, true);
        emit IGBridgeSender.TokensLocked(alice, bob, amount, 1);
        bridge.bridgeToGravityWithPermit{ value: fee }(amount, bob, deadline, v, r, s);
    }

    function test_BridgeToGravityWithPermit_RevertWhenExpired() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        uint256 deadline = block.timestamp - 1; // Expired

        bytes32 structHash = keccak256(
            abi.encode(gToken.PERMIT_TYPEHASH(), alice, address(bridge), amount, gToken.nonces(alice), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gToken.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert("Permit expired");
        bridge.bridgeToGravityWithPermit{ value: fee }(amount, bob, deadline, v, r, s);
    }

    function test_BridgeToGravityWithPermit_RevertWhenInvalidSignature() public {
        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        uint256 deadline = block.timestamp + 1 hours;

        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x9999, keccak256("wrong"));

        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert("Invalid signature");
        bridge.bridgeToGravityWithPermit{ value: fee }(amount, bob, deadline, v, r, s);
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

    function testFuzz_BridgeToGravity(
        uint256 amount,
        address recipient
    ) public {
        amount = bound(amount, 1, INITIAL_BALANCE);
        vm.assume(recipient != address(0));

        uint256 fee = bridge.calculateBridgeFee(amount, recipient);

        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);
        uint128 nonce = bridge.bridgeToGravity{ value: fee }(amount, recipient);
        vm.stopPrank();

        assertEq(nonce, 1);
        assertEq(gToken.balanceOf(alice), INITIAL_BALANCE - amount);
        assertEq(gToken.balanceOf(address(bridge)), amount);
    }

    // ========================================================================
    // HARDENING HELPERS
    // ========================================================================

    /// @dev Lock `amount` of G into the bridge so there is something to withdraw.
    function _lock(
        uint256 amount
    ) internal {
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);
        bridge.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();
    }

    // ========================================================================
    // HARDENING: PAUSABLE (M-1)
    // ========================================================================

    function test_Pause_BlocksBridge() public {
        vm.prank(owner);
        bridge.pause();
        assertTrue(bridge.paused());

        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();
    }

    function test_Pause_BlocksBridgeWithPermit() public {
        vm.prank(owner);
        bridge.pause();

        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(gToken.PERMIT_TYPEHASH(), alice, address(bridge), amount, gToken.nonces(alice), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gToken.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        vm.deal(alice, fee);
        vm.prank(alice);
        // Pause must be enforced before the permit nonce is consumed.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.bridgeToGravityWithPermit{ value: fee }(amount, bob, deadline, v, r, s);
    }

    function test_Unpause_RestoresBridge() public {
        vm.prank(owner);
        bridge.pause();
        vm.prank(owner);
        bridge.unpause();
        assertFalse(bridge.paused());

        uint256 amount = 100 ether;
        uint256 fee = bridge.calculateBridgeFee(amount, bob);
        vm.startPrank(alice);
        gToken.approve(address(bridge), amount);
        assertEq(bridge.bridgeToGravity{ value: fee }(amount, bob), 1);
        vm.stopPrank();
    }

    function test_Pause_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bridge.pause();
    }

    // ========================================================================
    // HARDENING: EMERGENCY-WITHDRAW 7-DAY TIMELOCK (C-1)
    // ========================================================================

    function test_RequestEmergencyWithdraw_SetsState() public {
        _lock(100 ether);
        uint256 expectedAt = block.timestamp + bridge.TIMELOCK_DELAY();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IGBridgeSender.EmergencyWithdrawRequested(bob, 100 ether, expectedAt);
        bridge.requestEmergencyWithdraw(bob, 100 ether);

        assertEq(bridge.pendingWithdrawRecipient(), bob);
        assertEq(bridge.pendingWithdrawAmount(), 100 ether);
        assertEq(bridge.pendingWithdrawExecutableAt(), expectedAt);
    }

    function test_RequestEmergencyWithdraw_RevertWhenAlreadyPending() public {
        _lock(100 ether);
        vm.startPrank(owner);
        bridge.requestEmergencyWithdraw(bob, 50 ether);
        vm.expectRevert(IGBridgeSender.WithdrawalAlreadyPending.selector);
        bridge.requestEmergencyWithdraw(bob, 50 ether);
        vm.stopPrank();
    }

    function test_RequestEmergencyWithdraw_RevertWhenZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(IGBridgeSender.ZeroRecipient.selector);
        bridge.requestEmergencyWithdraw(address(0), 1 ether);
    }

    function test_RequestEmergencyWithdraw_RevertWhenZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(IGBridgeSender.ZeroAmount.selector);
        bridge.requestEmergencyWithdraw(bob, 0);
    }

    function test_RequestEmergencyWithdraw_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bridge.requestEmergencyWithdraw(bob, 1 ether);
    }

    function test_CancelEmergencyWithdraw() public {
        _lock(100 ether);
        vm.startPrank(owner);
        bridge.requestEmergencyWithdraw(bob, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit IGBridgeSender.EmergencyWithdrawCancelled();
        bridge.cancelEmergencyWithdraw();
        vm.stopPrank();

        assertEq(bridge.pendingWithdrawExecutableAt(), 0);
        assertEq(bridge.pendingWithdrawRecipient(), address(0));
        assertEq(bridge.pendingWithdrawAmount(), 0);
    }

    function test_CancelEmergencyWithdraw_RevertWhenNonePending() public {
        vm.prank(owner);
        vm.expectRevert(IGBridgeSender.NoWithdrawalPending.selector);
        bridge.cancelEmergencyWithdraw();
    }

    function test_ExecuteEmergencyWithdraw_RevertBeforeTimelock() public {
        _lock(100 ether);
        vm.startPrank(owner);
        bridge.requestEmergencyWithdraw(bob, 100 ether);

        uint256 executableAt = bridge.pendingWithdrawExecutableAt();
        vm.warp(executableAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IGBridgeSender.TimelockNotElapsed.selector, executableAt, block.timestamp)
        );
        bridge.executeEmergencyWithdraw();
        vm.stopPrank();
    }

    function test_ExecuteEmergencyWithdraw_AfterTimelock() public {
        _lock(100 ether);
        vm.startPrank(owner);
        bridge.requestEmergencyWithdraw(bob, 100 ether);
        vm.warp(bridge.pendingWithdrawExecutableAt());

        vm.expectEmit(true, true, true, true);
        emit IGBridgeSender.EmergencyWithdraw(bob, 100 ether);
        bridge.executeEmergencyWithdraw();

        // Request state is cleared; a second execute reverts.
        vm.expectRevert(IGBridgeSender.NoWithdrawalPending.selector);
        bridge.executeEmergencyWithdraw();
        vm.stopPrank();

        assertEq(gToken.balanceOf(bob), 100 ether);
        assertEq(gToken.balanceOf(address(bridge)), 0);
        assertEq(bridge.pendingWithdrawExecutableAt(), 0);
    }

    function test_ExecuteEmergencyWithdraw_RevertWhenNonePending() public {
        vm.prank(owner);
        vm.expectRevert(IGBridgeSender.NoWithdrawalPending.selector);
        bridge.executeEmergencyWithdraw();
    }

    function test_EmergencyWithdraw_NewRequestAllowedAfterCancel() public {
        _lock(100 ether);
        vm.startPrank(owner);
        bridge.requestEmergencyWithdraw(bob, 40 ether);
        bridge.cancelEmergencyWithdraw();
        // A fresh request is allowed once the prior one is cleared.
        bridge.requestEmergencyWithdraw(alice, 60 ether);
        vm.warp(bridge.pendingWithdrawExecutableAt());
        bridge.executeEmergencyWithdraw();
        vm.stopPrank();

        assertEq(gToken.balanceOf(alice), INITIAL_BALANCE - 100 ether + 60 ether);
        assertEq(gToken.balanceOf(address(bridge)), 40 ether);
    }

    // ========================================================================
    // HARDENING: recoverERC20 G-TOKEN GUARD (I-1)
    // ========================================================================

    function test_RecoverERC20_RevertForGToken() public {
        _lock(100 ether);
        vm.prank(owner);
        vm.expectRevert(IGBridgeSender.CannotRecoverGToken.selector);
        bridge.recoverERC20(address(gToken), owner, 100 ether);
    }

    function test_RecoverERC20_WorksForOtherToken() public {
        // An unrelated token accidentally sent to the bridge can still be rescued.
        MockERC20Permit other = new MockERC20Permit();
        other.mint(address(bridge), 5 ether);

        vm.prank(owner);
        bridge.recoverERC20(address(other), bob, 5 ether);
        assertEq(other.balanceOf(bob), 5 ether);
    }
}

