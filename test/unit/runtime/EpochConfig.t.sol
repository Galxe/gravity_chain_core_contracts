// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { EpochConfig } from "../../../src/runtime/EpochConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title EpochConfigTest
/// @notice Unit tests for EpochConfig contract
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
    // SETTER TESTS - setEpochIntervalMicros
    // ========================================================================

    function test_SetEpochIntervalMicros() public {
        _initializeConfig();

        uint64 newInterval = 4 hours * 1_000_000; // 4 hours
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setEpochIntervalMicros(newInterval);

        assertEq(config.epochIntervalMicros(), newInterval);
    }

    function test_RevertWhen_SetEpochIntervalMicros_Zero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidEpochInterval.selector);
        config.setEpochIntervalMicros(0);
    }

    function test_RevertWhen_SetEpochIntervalMicros_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.EpochConfigNotInitialized.selector);
        config.setEpochIntervalMicros(EPOCH_INTERVAL);
    }

    function test_RevertWhen_SetEpochIntervalMicros_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setEpochIntervalMicros(EPOCH_INTERVAL * 2);
    }

    function test_Event_SetEpochIntervalMicros() public {
        _initializeConfig();

        uint64 newInterval = 4 hours * 1_000_000;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit EpochConfig.EpochIntervalUpdated(EPOCH_INTERVAL, newInterval);
        config.setEpochIntervalMicros(newInterval);
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
        config.setEpochIntervalMicros(EPOCH_INTERVAL * 2);
    }

    function test_RevertWhen_SetterCalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setEpochIntervalMicros(EPOCH_INTERVAL * 2);
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

    function testFuzz_SetEpochIntervalMicros(
        uint64 newInterval
    ) public {
        vm.assume(newInterval > 0);
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setEpochIntervalMicros(newInterval);

        assertEq(config.epochIntervalMicros(), newInterval);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(EPOCH_INTERVAL);
    }
}

