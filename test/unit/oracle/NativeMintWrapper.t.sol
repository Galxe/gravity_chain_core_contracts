// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeMintWrapper } from "@src/oracle/evm/native_token_bridge/NativeMintWrapper.sol";
import { INativeMintWrapper } from "@src/oracle/evm/native_token_bridge/INativeMintWrapper.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { NotAllowed } from "@src/foundation/SystemAccessControl.sol";
import { Errors } from "@src/foundation/Errors.sol";

/// @title NativeMintWrapperTest
/// @notice Unit tests for NativeMintWrapper contract
contract NativeMintWrapperTest is Test {
    NativeMintWrapper public wrapper;

    address public owner;
    address public minterA;
    address public minterB;
    address public alice;

    function setUp() public {
        owner = makeAddr("owner");
        minterA = makeAddr("minterA");
        minterB = makeAddr("minterB");
        alice = makeAddr("alice");

        // Deploy wrapper (simulates bytecode injection)
        wrapper = new NativeMintWrapper();

        // Mock the precompile call to always succeed
        bytes memory emptyData = "";
        bytes memory successReturn = "";
        vm.mockCall(SystemAddresses.NATIVE_MINT_PRECOMPILE, emptyData, successReturn);

        // Initialize as Genesis (matching system contract pattern)
        address[] memory initialMinters = new address[](1);
        initialMinters[0] = minterA;

        vm.prank(SystemAddresses.GENESIS);
        wrapper.initialize(owner, initialMinters);
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public view {
        assertEq(wrapper.owner(), owner);
        assertTrue(wrapper.isMinter(minterA));
    }

    function test_Initialize_RevertWhenNotGenesis() public {
        NativeMintWrapper wrapper2 = new NativeMintWrapper();
        address[] memory minters = new address[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, alice, SystemAddresses.GENESIS));
        wrapper2.initialize(owner, minters);
    }

    function test_Initialize_RevertWhenAlreadyInitialized() public {
        address[] memory minters = new address[](0);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        wrapper.initialize(owner, minters);
    }

    function test_Initialize_RevertWhenZeroOwner() public {
        NativeMintWrapper wrapper2 = new NativeMintWrapper();
        address[] memory minters = new address[](0);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.ZeroAddress.selector);
        wrapper2.initialize(address(0), minters);
    }

    function test_Initialize_MultipleMinters() public {
        NativeMintWrapper wrapper2 = new NativeMintWrapper();
        address[] memory minters = new address[](2);
        minters[0] = minterA;
        minters[1] = minterB;

        vm.prank(SystemAddresses.GENESIS);
        wrapper2.initialize(owner, minters);

        assertTrue(wrapper2.isMinter(minterA));
        assertTrue(wrapper2.isMinter(minterB));
    }

    // ========================================================================
    // ADD MINTER TESTS
    // ========================================================================

    function test_AddMinter() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit INativeMintWrapper.MinterAdded(minterB);
        wrapper.addMinter(minterB);

        assertTrue(wrapper.isMinter(minterB));
    }

    function test_AddMinter_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INativeMintWrapper.OnlyOwner.selector, alice));
        wrapper.addMinter(minterB);
    }

    function test_AddMinter_RevertWhenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        wrapper.addMinter(address(0));
    }

    // ========================================================================
    // REMOVE MINTER TESTS
    // ========================================================================

    function test_RemoveMinter() public {
        assertTrue(wrapper.isMinter(minterA));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit INativeMintWrapper.MinterRemoved(minterA);
        wrapper.removeMinter(minterA);

        assertFalse(wrapper.isMinter(minterA));
    }

    function test_RemoveMinter_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INativeMintWrapper.OnlyOwner.selector, alice));
        wrapper.removeMinter(minterA);
    }

    // ========================================================================
    // MINT TESTS
    // ========================================================================

    function test_Mint_Success() public {
        vm.prank(minterA);
        wrapper.mint(alice, 100 ether);
    }

    function test_Mint_RevertWhenUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INativeMintWrapper.UnauthorizedMinter.selector, alice));
        wrapper.mint(alice, 100 ether);
    }

    function test_Mint_RevertWhenZeroRecipient() public {
        vm.prank(minterA);
        vm.expectRevert(Errors.ZeroAddress.selector);
        wrapper.mint(address(0), 100 ether);
    }

    function test_Mint_RevertWhenZeroAmount() public {
        vm.prank(minterA);
        vm.expectRevert(Errors.ZeroAmount.selector);
        wrapper.mint(alice, 0);
    }

    function test_Mint_RevertAfterMinterRemoved() public {
        // Mint succeeds
        vm.prank(minterA);
        wrapper.mint(alice, 100 ether);

        // Remove minter
        vm.prank(owner);
        wrapper.removeMinter(minterA);

        // Mint fails
        vm.prank(minterA);
        vm.expectRevert(abi.encodeWithSelector(INativeMintWrapper.UnauthorizedMinter.selector, minterA));
        wrapper.mint(alice, 100 ether);
    }

    // ========================================================================
    // MULTI MINTER TESTS
    // ========================================================================

    function test_MultipleMinters() public {
        vm.prank(owner);
        wrapper.addMinter(minterB);

        // Both minters can mint
        vm.prank(minterA);
        wrapper.mint(alice, 50 ether);

        vm.prank(minterB);
        wrapper.mint(alice, 75 ether);
    }

    // ========================================================================
    // VIEW TESTS
    // ========================================================================

    function test_IsMinter_False() public view {
        assertFalse(wrapper.isMinter(alice));
    }

    function test_IsMinter_True() public view {
        assertTrue(wrapper.isMinter(minterA));
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_AddAndMint(
        address minter,
        address recipient,
        uint256 amount
    ) public {
        vm.assume(minter != address(0));
        vm.assume(recipient != address(0));
        vm.assume(amount > 0);

        vm.prank(owner);
        wrapper.addMinter(minter);

        vm.prank(minter);
        wrapper.mint(recipient, amount);
    }
}
