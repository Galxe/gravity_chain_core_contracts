// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    requireAllowed,
    requireAllowedAny,
    NotAllowed,
    NotAllowedAny
} from "../../../src/foundation/SystemAccessControl.sol";
import {SystemAddresses} from "../../../src/foundation/SystemAddresses.sol";

/// @title SystemAccessControlTest
/// @notice Unit tests for SystemAccessControl free functions
contract SystemAccessControlTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");

    // ========================================================================
    // requireAllowed(address) - single address
    // ========================================================================

    function test_RequireAllowed_SingleAddress_Success() public {
        vm.prank(alice);
        this.externalRequireAllowedSingle(alice);
        // Should not revert
    }

    function test_RequireAllowed_SingleAddress_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob, alice));
        this.externalRequireAllowedSingle(alice);
    }

    function test_RequireAllowed_SingleAddress_SystemCaller() public {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        this.externalRequireAllowedSingle(SystemAddresses.SYSTEM_CALLER);
        // Should not revert
    }

    // ========================================================================
    // requireAllowed(address, address) - two addresses
    // ========================================================================

    function test_RequireAllowed_TwoAddresses_FirstAllowed() public {
        vm.prank(alice);
        this.externalRequireAllowedTwo(alice, bob);
        // Should not revert
    }

    function test_RequireAllowed_TwoAddresses_SecondAllowed() public {
        vm.prank(bob);
        this.externalRequireAllowedTwo(alice, bob);
        // Should not revert
    }

    function test_RequireAllowed_TwoAddresses_Reverts() public {
        vm.prank(charlie);

        address[] memory expected = new address[](2);
        expected[0] = alice;
        expected[1] = bob;

        vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, charlie, expected));
        this.externalRequireAllowedTwo(alice, bob);
    }

    // ========================================================================
    // requireAllowed(address, address, address) - three addresses
    // ========================================================================

    function test_RequireAllowed_ThreeAddresses_FirstAllowed() public {
        vm.prank(alice);
        this.externalRequireAllowedThree(alice, bob, charlie);
    }

    function test_RequireAllowed_ThreeAddresses_SecondAllowed() public {
        vm.prank(bob);
        this.externalRequireAllowedThree(alice, bob, charlie);
    }

    function test_RequireAllowed_ThreeAddresses_ThirdAllowed() public {
        vm.prank(charlie);
        this.externalRequireAllowedThree(alice, bob, charlie);
    }

    function test_RequireAllowed_ThreeAddresses_Reverts() public {
        vm.prank(dave);

        address[] memory expected = new address[](3);
        expected[0] = alice;
        expected[1] = bob;
        expected[2] = charlie;

        vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, dave, expected));
        this.externalRequireAllowedThree(alice, bob, charlie);
    }

    // ========================================================================
    // requireAllowed(address, address, address, address) - four addresses
    // ========================================================================

    function test_RequireAllowed_FourAddresses_FirstAllowed() public {
        vm.prank(alice);
        this.externalRequireAllowedFour(alice, bob, charlie, dave);
    }

    function test_RequireAllowed_FourAddresses_SecondAllowed() public {
        vm.prank(bob);
        this.externalRequireAllowedFour(alice, bob, charlie, dave);
    }

    function test_RequireAllowed_FourAddresses_ThirdAllowed() public {
        vm.prank(charlie);
        this.externalRequireAllowedFour(alice, bob, charlie, dave);
    }

    function test_RequireAllowed_FourAddresses_FourthAllowed() public {
        vm.prank(dave);
        this.externalRequireAllowedFour(alice, bob, charlie, dave);
    }

    function test_RequireAllowed_FourAddresses_Reverts() public {
        vm.prank(eve);

        address[] memory expected = new address[](4);
        expected[0] = alice;
        expected[1] = bob;
        expected[2] = charlie;
        expected[3] = dave;

        vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, eve, expected));
        this.externalRequireAllowedFour(alice, bob, charlie, dave);
    }

    // ========================================================================
    // requireAllowedAny(address[]) - dynamic array
    // ========================================================================

    function test_RequireAllowedAny_EmptyArray_Reverts() public {
        address[] memory allowed = new address[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, alice, allowed));
        this.externalRequireAllowedAny(allowed);
    }

    function test_RequireAllowedAny_SingleElement_Success() public {
        address[] memory allowed = new address[](1);
        allowed[0] = alice;

        vm.prank(alice);
        this.externalRequireAllowedAny(allowed);
    }

    function test_RequireAllowedAny_SingleElement_Reverts() public {
        address[] memory allowed = new address[](1);
        allowed[0] = alice;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, bob, allowed));
        this.externalRequireAllowedAny(allowed);
    }

    function test_RequireAllowedAny_MultipleElements_FirstMatch() public {
        address[] memory allowed = new address[](3);
        allowed[0] = alice;
        allowed[1] = bob;
        allowed[2] = charlie;

        vm.prank(alice);
        this.externalRequireAllowedAny(allowed);
    }

    function test_RequireAllowedAny_MultipleElements_LastMatch() public {
        address[] memory allowed = new address[](3);
        allowed[0] = alice;
        allowed[1] = bob;
        allowed[2] = charlie;

        vm.prank(charlie);
        this.externalRequireAllowedAny(allowed);
    }

    function test_RequireAllowedAny_MultipleElements_NoMatch() public {
        address[] memory allowed = new address[](3);
        allowed[0] = alice;
        allowed[1] = bob;
        allowed[2] = charlie;

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, dave, allowed));
        this.externalRequireAllowedAny(allowed);
    }

    // ========================================================================
    // Fuzz Tests
    // ========================================================================

    function testFuzz_RequireAllowed_SingleAddress(address caller, address allowed) public {
        vm.prank(caller);
        if (caller == allowed) {
            this.externalRequireAllowedSingle(allowed);
        } else {
            vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, caller, allowed));
            this.externalRequireAllowedSingle(allowed);
        }
    }

    function testFuzz_RequireAllowed_TwoAddresses(address caller, address a1, address a2) public {
        vm.prank(caller);
        if (caller == a1 || caller == a2) {
            this.externalRequireAllowedTwo(a1, a2);
        } else {
            address[] memory expected = new address[](2);
            expected[0] = a1;
            expected[1] = a2;
            vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, caller, expected));
            this.externalRequireAllowedTwo(a1, a2);
        }
    }

    function testFuzz_RequireAllowedAny_RandomArray(address caller, uint8 arraySize, uint256 seed) public {
        // Bound array size to reasonable range
        arraySize = uint8(bound(arraySize, 1, 10));

        address[] memory allowed = new address[](arraySize);
        bool callerInArray = false;

        for (uint256 i = 0; i < arraySize; i++) {
            allowed[i] = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            if (allowed[i] == caller) {
                callerInArray = true;
            }
        }

        vm.prank(caller);
        if (callerInArray) {
            this.externalRequireAllowedAny(allowed);
        } else {
            vm.expectRevert(abi.encodeWithSelector(NotAllowedAny.selector, caller, allowed));
            this.externalRequireAllowedAny(allowed);
        }
    }

    // ========================================================================
    // Error Message Tests
    // ========================================================================

    function test_NotAllowed_ErrorContainsCorrectAddresses() public {
        vm.prank(bob);
        try this.externalRequireAllowedSingle(alice) {
            revert("Should have reverted");
        } catch (bytes memory reason) {
            // Decode the error
            bytes4 selector = bytes4(reason);
            assertEq(selector, NotAllowed.selector, "Wrong error selector");

            // Verify error contains correct addresses
            (address errorCaller, address errorAllowed) = abi.decode(_removeSelector(reason), (address, address));
            assertEq(errorCaller, bob, "Error should contain caller");
            assertEq(errorAllowed, alice, "Error should contain allowed");
        }
    }

    function test_NotAllowedAny_ErrorContainsCorrectAddresses() public {
        address[] memory allowed = new address[](2);
        allowed[0] = alice;
        allowed[1] = bob;

        vm.prank(charlie);
        try this.externalRequireAllowedAny(allowed) {
            revert("Should have reverted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertEq(selector, NotAllowedAny.selector, "Wrong error selector");
        }
    }

    // ========================================================================
    // Helper Functions (external wrappers for testing free functions)
    // ========================================================================

    function externalRequireAllowedSingle(address allowed) external view {
        requireAllowed(allowed);
    }

    function externalRequireAllowedTwo(address a1, address a2) external view {
        requireAllowed(a1, a2);
    }

    function externalRequireAllowedThree(address a1, address a2, address a3) external view {
        requireAllowed(a1, a2, a3);
    }

    function externalRequireAllowedFour(address a1, address a2, address a3, address a4) external view {
        requireAllowed(a1, a2, a3, a4);
    }

    function externalRequireAllowedAny(address[] memory allowed) external view {
        requireAllowedAny(allowed);
    }

    function _removeSelector(bytes memory data) internal pure returns (bytes memory) {
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; i++) {
            result[i - 4] = data[i];
        }
        return result;
    }
}

