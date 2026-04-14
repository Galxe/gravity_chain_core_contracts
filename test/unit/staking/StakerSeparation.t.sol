// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Staking } from "../../../src/staking/Staking.sol";
import { IStakePool } from "../../../src/staking/IStakePool.sol";
import { StakingConfig } from "../../../src/runtime/StakingConfig.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorStatus } from "../../../src/foundation/Types.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

contract MockValidatorManagement2 {
    function isValidator(address) external pure returns (bool) { return false; }
    function getValidatorStatus(address) external pure returns (ValidatorStatus) {
        return ValidatorStatus.INACTIVE;
    }
}

contract MockReconfiguration2 {
    function isTransitionInProgress() external pure returns (bool) { return false; }
}

/// @title StakerSeparationTest
/// @notice Verifies Staking.createPool and StakePool role checks work when
///         owner / staker / operator are three distinct EVM addresses.
///         This guards the Genesis.sol change that stops collapsing all three
///         roles into a single address.
contract StakerSeparationTest is Test {
    Staking public staking;
    StakingConfig public stakingConfig;
    Timestamp public timestamp;

    address public ownerAddr   = makeAddr("distinctOwner");
    address public stakerAddr  = makeAddr("distinctStaker");
    address public operatorAddr = makeAddr("distinctOperator");
    address public voterAddr   = makeAddr("distinctVoter");
    address public stranger    = makeAddr("stranger");

    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000;
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000;
    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000;

    function setUp() public {
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new MockValidatorManagement2()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfiguration2()).code);

        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY);

        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(ownerAddr, INITIAL_TIMESTAMP);

        vm.deal(ownerAddr, 1000 ether);
        vm.deal(stakerAddr, 1000 ether);
        vm.deal(operatorAddr, 1000 ether);
        vm.deal(stranger, 1000 ether);
    }

    function _createDistinctPool() internal returns (address pool) {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;
        vm.prank(ownerAddr);
        pool = staking.createPool{ value: MIN_STAKE }(
            ownerAddr,
            stakerAddr,
            operatorAddr,
            voterAddr,
            lockedUntil
        );
    }

    function test_createPool_DistinctRolesStored() public {
        address pool = _createDistinctPool();

        assertEq(Ownable(pool).owner(), ownerAddr, "owner mismatch");
        assertEq(IStakePool(pool).getStaker(), stakerAddr, "staker mismatch");
        assertEq(IStakePool(pool).getOperator(), operatorAddr, "operator mismatch");
        assertEq(staking.getPoolOperator(pool), operatorAddr, "factory operator view mismatch");
    }

    function test_addStake_OnlyStakerSucceeds() public {
        address pool = _createDistinctPool();

        // Owner cannot addStake
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, ownerAddr, stakerAddr));
        IStakePool(pool).addStake{ value: 1 ether }();

        // Operator cannot addStake
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, operatorAddr, stakerAddr));
        IStakePool(pool).addStake{ value: 1 ether }();

        // Stranger cannot addStake
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotStaker.selector, stranger, stakerAddr));
        IStakePool(pool).addStake{ value: 1 ether }();

        // Staker succeeds
        vm.prank(stakerAddr);
        IStakePool(pool).addStake{ value: 1 ether }();
    }

    function test_setStaker_OnlyOwnerSucceeds() public {
        address pool = _createDistinctPool();
        address newStaker = makeAddr("newStaker");

        // Staker cannot rotate itself
        vm.prank(stakerAddr);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stakerAddr));
        IStakePool(pool).setStaker(newStaker);

        // Operator cannot
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operatorAddr));
        IStakePool(pool).setStaker(newStaker);

        // Owner succeeds
        vm.prank(ownerAddr);
        IStakePool(pool).setStaker(newStaker);
        assertEq(IStakePool(pool).getStaker(), newStaker, "setStaker did not apply");
    }

    function test_setOperator_OnlyOwnerSucceeds() public {
        address pool = _createDistinctPool();
        address newOperator = makeAddr("newOperator");

        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operatorAddr));
        IStakePool(pool).setOperator(newOperator);

        vm.prank(stakerAddr);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stakerAddr));
        IStakePool(pool).setOperator(newOperator);

        vm.prank(ownerAddr);
        IStakePool(pool).setOperator(newOperator);
        assertEq(IStakePool(pool).getOperator(), newOperator, "setOperator did not apply");
    }
}
