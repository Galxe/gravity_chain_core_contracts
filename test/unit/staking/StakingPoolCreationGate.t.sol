// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Staking } from "../../../src/staking/Staking.sol";
import { StakingConfig } from "../../../src/runtime/StakingConfig.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorStatus } from "../../../src/foundation/Types.sol";

contract MockValidatorManagementGate {
    function isValidator(
        address
    ) external pure returns (bool) {
        return false;
    }

    function getValidatorStatus(
        address
    ) external pure returns (ValidatorStatus) {
        return ValidatorStatus.INACTIVE;
    }
}

contract MockReconfigurationGate {
    function isTransitionInProgress() external pure returns (bool) {
        return false;
    }
}

/// @title StakingPoolCreationGateTest
/// @notice Tests for the `allowPoolCreation` gate on Staking.createPool, including
///         the GENESIS bypass and governance flip via the pending-config pathway.
contract StakingPoolCreationGateTest is Test {
    Staking public staking;
    StakingConfig public stakingConfig;
    Timestamp public timestamp;

    address public alice = makeAddr("alice");

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

        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new MockValidatorManagementGate()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfigurationGate()).code);

        // Initialize with allowPoolCreation = false (mainnet-launch default)
        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, false);

        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP);

        vm.deal(alice, 100 ether);
        vm.deal(SystemAddresses.GENESIS, 100 ether);
    }

    function _createPoolAs(
        address caller
    ) internal returns (address) {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;
        vm.prank(caller);
        return staking.createPool{ value: MIN_STAKE }(alice, alice, alice, alice, lockedUntil);
    }

    // --------------------------------------------------------------------
    // Gate blocks permissionless creation when allowPoolCreation is false
    // --------------------------------------------------------------------

    function test_createPool_RevertsWhenDisabled_ForExternalCaller() public {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        vm.prank(alice);
        vm.expectRevert(Errors.PoolCreationDisabled.selector);
        staking.createPool{ value: MIN_STAKE }(alice, alice, alice, alice, lockedUntil);
    }

    // --------------------------------------------------------------------
    // GENESIS bypass works regardless of flag state
    // --------------------------------------------------------------------

    function test_createPool_GenesisCanBypassWhenDisabled() public {
        address pool = _createPoolAs(SystemAddresses.GENESIS);
        assertTrue(staking.isPool(pool), "Genesis-created pool should be registered");
        assertEq(staking.getPoolCount(), 1, "Pool count should be 1");
    }

    // --------------------------------------------------------------------
    // Governance flip takes effect at epoch boundary
    // --------------------------------------------------------------------

    function test_createPool_GovernanceFlip_TakesEffectAfterApply() public {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        // Queue the flip via governance (dedicated setter — independent of the
        // atomic setForNextEpoch path)
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setAllowPoolCreationForNextEpoch(true);

        // Before apply: gate is still closed for external callers
        vm.prank(alice);
        vm.expectRevert(Errors.PoolCreationDisabled.selector);
        staking.createPool{ value: MIN_STAKE }(alice, alice, alice, alice, lockedUntil);

        // Apply at epoch boundary
        vm.prank(SystemAddresses.RECONFIGURATION);
        stakingConfig.applyPendingConfig();

        assertTrue(stakingConfig.allowPoolCreation(), "Flag should be true after apply");

        // After apply: external caller can create
        address pool = _createPoolAs(alice);
        assertTrue(staking.isPool(pool), "External caller should succeed after flip");
    }

    // --------------------------------------------------------------------
    // Governance can flip back to closed
    // --------------------------------------------------------------------

    function test_createPool_GovernanceFlipBack_RecloseGate() public {
        uint64 lockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        // Open the gate
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setAllowPoolCreationForNextEpoch(true);
        vm.prank(SystemAddresses.RECONFIGURATION);
        stakingConfig.applyPendingConfig();

        // External caller can create while open
        address pool = _createPoolAs(alice);
        assertTrue(staking.isPool(pool), "External caller should succeed while open");

        // Close it again
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setAllowPoolCreationForNextEpoch(false);
        vm.prank(SystemAddresses.RECONFIGURATION);
        stakingConfig.applyPendingConfig();

        assertFalse(stakingConfig.allowPoolCreation(), "Flag should be false after re-close");

        // External caller blocked again
        vm.prank(alice);
        vm.expectRevert(Errors.PoolCreationDisabled.selector);
        staking.createPool{ value: MIN_STAKE }(alice, alice, alice, alice, lockedUntil);

        // GENESIS still bypasses
        address genesisPool = _createPoolAs(SystemAddresses.GENESIS);
        assertTrue(staking.isPool(genesisPool), "Genesis should still bypass after re-close");
    }
}
