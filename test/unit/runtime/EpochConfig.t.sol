// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { EpochConfig } from "../../../src/runtime/EpochConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title EpochConfigTest
/// @notice Unit tests for EpochConfig contract with pending pattern
contract EpochConfigTest is Test {
    EpochConfig public config;

    // Common test values (microseconds)
    uint64 constant EPOCH_INTERVAL = 2 hours * 1_000_000; // 2 hours in microseconds

    function setUp() public {
        config = new EpochConfig();
    }

    // ========================================================================
    // INITIAL STATE TESTS
    // ========================================================================

    function test_InitialState() public view {
        assertEq(config.epochIntervalMicros(), 0);
        assertFalse(config.isInitialized());
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(EPOCH_INTERVAL);

        assertEq(config.epochIntervalMicros(), EPOCH_INTERVAL);
        assertTrue(config.isInitialized());
    }

    function test_RevertWhen_Initialize_ZeroInterval() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidEpochInterval.selector);
        config.initialize(0);
    }

    function test_RevertWhen_Initialize_AlreadyInitialized() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(EPOCH_INTERVAL);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.EpochConfigAlreadyInitialized.selector);
        config.initialize(EPOCH_INTERVAL * 2);
    }

    function test_RevertWhen_Initialize_NotGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        config.initialize(EPOCH_INTERVAL);
    }

    function test_Event_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(false, false, false, true);
        emit EpochConfig.EpochIntervalUpdated(0, EPOCH_INTERVAL);
        config.initialize(EPOCH_INTERVAL);
    }

    // ========================================================================
    // SETTER TESTS - setForNextEpoch
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeConfig();

        uint64 newInterval = 4 hours * 1_000_000; // 4 hours
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newInterval);

        // Should not change current value, only set pending
        assertEq(config.epochIntervalMicros(), EPOCH_INTERVAL);
        assertTrue(config.hasPendingConfig());

        (bool hasPending, uint64 pendingInterval) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingInterval, newInterval);
    }

    function test_RevertWhen_SetForNextEpoch_Zero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidEpochInterval.selector);
        config.setForNextEpoch(0);
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.EpochConfigNotInitialized.selector);
        config.setForNextEpoch(EPOCH_INTERVAL);
    }

    function test_RevertWhen_SetForNextEpoch_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(EPOCH_INTERVAL * 2);
    }

    function test_Event_SetForNextEpoch() public {
        _initializeConfig();

        uint64 newInterval = 4 hours * 1_000_000;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit EpochConfig.PendingEpochIntervalSet(newInterval);
        config.setForNextEpoch(newInterval);
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeConfig();

        uint64 newInterval = 4 hours * 1_000_000;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newInterval);

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.epochIntervalMicros(), newInterval);
        assertFalse(config.hasPendingConfig());
    }

    function test_ApplyPendingConfig_NoPending() public {
        _initializeConfig();

        // Should be no-op when no pending config
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.epochIntervalMicros(), EPOCH_INTERVAL);
        assertFalse(config.hasPendingConfig());
    }

    function test_RevertWhen_ApplyPendingConfig_NotReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(EPOCH_INTERVAL * 2);

        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        config.applyPendingConfig();
    }

    function test_Event_ApplyPendingConfig() public {
        _initializeConfig();

        uint64 newInterval = 4 hours * 1_000_000;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newInterval);

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, true);
        emit EpochConfig.EpochIntervalUpdated(EPOCH_INTERVAL, newInterval);
        config.applyPendingConfig();
    }

    // ========================================================================
    // ACCESS CONTROL TESTS
    // ========================================================================

    function test_RevertWhen_SetterCalledByGenesis() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GENESIS, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(EPOCH_INTERVAL * 2);
    }

    function test_RevertWhen_SetterCalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(EPOCH_INTERVAL * 2);
    }

    function test_RevertWhen_SetterCalledByReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.RECONFIGURATION, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(EPOCH_INTERVAL * 2);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Initialize(
        uint64 interval
    ) public {
        vm.assume(interval > 0);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(interval);

        assertEq(config.epochIntervalMicros(), interval);
        assertTrue(config.isInitialized());
    }

    function testFuzz_SetForNextEpoch(
        uint64 newInterval
    ) public {
        vm.assume(newInterval > 0);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newInterval);

        assertTrue(config.hasPendingConfig());
        (bool hasPending, uint64 pendingInterval) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingInterval, newInterval);
    }

    function testFuzz_ApplyPendingConfig(
        uint64 newInterval
    ) public {
        vm.assume(newInterval > 0);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newInterval);

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.epochIntervalMicros(), newInterval);
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(EPOCH_INTERVAL);
    }
}
