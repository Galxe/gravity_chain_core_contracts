// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { VerifyBridgeMainnet } from "scripts/mainnet/VerifyBridgeMainnet.s.sol";

contract VerifyBridgeMainnetHarness is VerifyBridgeMainnet {
    function verifyOwnership(
        address currentOwner,
        address pendingOwner,
        address expectedOwner,
        address expectedDeployer
    ) external pure {
        Expected memory expected;
        expected.owner = expectedOwner;
        expected.deployer = expectedDeployer;

        _verifyOwnership("test", currentOwner, pendingOwner, expected);
    }
}

contract VerifyBridgeMainnetTest is Test {
    VerifyBridgeMainnetHarness internal verifier;

    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        verifier = new VerifyBridgeMainnetHarness();
    }

    function test_FinalizedOwnershipPassesWithoutExpectedDeployer() public view {
        verifier.verifyOwnership(multisig, address(0), multisig, address(0));
    }

    function test_PendingOwnershipPassesWithExpectedDeployer() public view {
        verifier.verifyOwnership(deployer, multisig, multisig, deployer);
    }

    function test_RevertWhen_PendingOwnershipHasNoExpectedDeployer() public {
        vm.expectRevert("ownership mismatch: test");
        verifier.verifyOwnership(attacker, multisig, multisig, address(0));
    }

    function test_RevertWhen_PendingOwnershipHasUnexpectedCurrentOwner() public {
        vm.expectRevert("ownership mismatch: test");
        verifier.verifyOwnership(attacker, multisig, multisig, deployer);
    }
}
