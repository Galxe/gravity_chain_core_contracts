// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ValidatorConsensusInfo } from "src/foundation/Types.sol";
import { LocalBattleStaking, LocalBattleValidatorManagement } from "script/debate/LocalBattleInfrastructure.sol";

contract LocalBattleInfrastructureTest is Test {
    address private constant OWNER = address(0xA11CE);
    address private constant OUTSIDER = address(0xBAD);

    LocalBattleStaking private staking;
    LocalBattleValidatorManagement private validatorManagement;

    function setUp() public {
        staking = new LocalBattleStaking(OWNER);
        validatorManagement = new LocalBattleValidatorManagement(OWNER, 42);
    }

    function test_CreateFourValidatorJury() public {
        for (uint256 i; i < 4; ++i) {
            address voter = address(uint160(0x100 + i));
            vm.prank(OWNER);
            address pool = staking.createPool(voter);
            vm.prank(OWNER);
            validatorManagement.addValidator(pool, (i + 1) * 100 ether);

            assertTrue(staking.isPool(pool));
            assertEq(staking.getPoolVoter(pool), voter);
            assertTrue(validatorManagement.isActiveValidator(pool));
        }

        ValidatorConsensusInfo[] memory validators = validatorManagement.getActiveValidators();
        assertEq(validators.length, 4);
        assertEq(validators[0].validatorIndex, 0);
        assertEq(validators[3].validatorIndex, 3);
        assertEq(validators[3].votingPower, 400 ether);
        assertEq(validatorManagement.getCurrentEpoch(), 42);
    }

    function test_VoterDelegationCanChangeBeforeBattleSnapshot() public {
        vm.prank(OWNER);
        address pool = staking.createPool(address(0x101));

        vm.prank(OWNER);
        staking.setPoolVoter(pool, address(0x202));

        assertEq(staking.getPoolVoter(pool), address(0x202));
    }

    function test_RevertWhen_NonOwnerMutatesLocalInfrastructure() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(LocalBattleStaking.NotOwner.selector, OUTSIDER));
        staking.createPool(address(0x101));

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(LocalBattleValidatorManagement.NotOwner.selector, OUTSIDER));
        validatorManagement.addValidator(address(0x123), 100 ether);
    }
}
