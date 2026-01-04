// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { VersionConfig } from "../../../src/runtime/VersionConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title VersionConfigTest
/// @notice Unit tests for VersionConfig contract
contract VersionConfigTest is Test {
    VersionConfig public config;

    // Common test values
    uint64 constant INITIAL_VERSION = 1;

    function setUp() public {
        config = new VersionConfig();
    }

    // ========================================================================
    // INITIAL STATE TESTS
    // ========================================================================

    function test_InitialState() public view {
        assertEq(config.majorVersion(), 0);
        assertFalse(config.isInitialized());
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(INITIAL_VERSION);

        assertEq(config.majorVersion(), INITIAL_VERSION);
        assertTrue(config.isInitialized());
    }

    function test_Initialize_ZeroVersion() public {
        // Zero version is allowed at initialization
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(0);

        assertEq(config.majorVersion(), 0);
        assertTrue(config.isInitialized());
    }

    function test_RevertWhen_Initialize_AlreadyInitialized() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(INITIAL_VERSION);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.VersionAlreadyInitialized.selector);
        config.initialize(INITIAL_VERSION + 1);
    }

    function test_RevertWhen_Initialize_NotGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        config.initialize(INITIAL_VERSION);
    }

    function test_Event_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(false, false, false, true);
        emit VersionConfig.VersionUpdated(0, INITIAL_VERSION);
        config.initialize(INITIAL_VERSION);
    }

    // ========================================================================
    // SETTER TESTS - setMajorVersion
    // ========================================================================

    function test_SetMajorVersion() public {
        _initializeConfig();

        uint64 newVersion = INITIAL_VERSION + 1;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMajorVersion(newVersion);

        assertEq(config.majorVersion(), newVersion);
    }

    function test_SetMajorVersion_MultipleIncrements() public {
        _initializeConfig();

        // Increment multiple times
        for (uint64 i = 2; i <= 10; i++) {
            vm.prank(SystemAddresses.GOVERNANCE);
            config.setMajorVersion(i);
            assertEq(config.majorVersion(), i);
        }
    }

    function test_SetMajorVersion_SkipVersions() public {
        _initializeConfig();

        // Can skip versions (e.g., go from 1 to 10)
        uint64 newVersion = 10;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMajorVersion(newVersion);

        assertEq(config.majorVersion(), newVersion);
    }

    function test_RevertWhen_SetMajorVersion_SameVersion() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.VersionMustIncrease.selector, INITIAL_VERSION, INITIAL_VERSION));
        config.setMajorVersion(INITIAL_VERSION);
    }

    function test_RevertWhen_SetMajorVersion_LowerVersion() public {
        _initializeConfig();

        // First increase version
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMajorVersion(5);

        // Try to decrease
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.VersionMustIncrease.selector, 5, 3));
        config.setMajorVersion(3);
    }

    function test_RevertWhen_SetMajorVersion_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.VersionNotInitialized.selector);
        config.setMajorVersion(INITIAL_VERSION);
    }

    function test_RevertWhen_SetMajorVersion_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setMajorVersion(INITIAL_VERSION + 1);
    }

    function test_Event_SetMajorVersion() public {
        _initializeConfig();

        uint64 newVersion = INITIAL_VERSION + 1;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit VersionConfig.VersionUpdated(INITIAL_VERSION, newVersion);
        config.setMajorVersion(newVersion);
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
        config.setMajorVersion(INITIAL_VERSION + 1);
    }

    function test_RevertWhen_SetterCalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setMajorVersion(INITIAL_VERSION + 1);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Initialize(
        uint64 version
    ) public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(version);

        assertEq(config.majorVersion(), version);
        assertTrue(config.isInitialized());
    }

    function testFuzz_SetMajorVersion(
        uint64 currentVersion,
        uint64 newVersion
    ) public {
        vm.assume(newVersion > currentVersion);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(currentVersion);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setMajorVersion(newVersion);

        assertEq(config.majorVersion(), newVersion);
    }

    function testFuzz_RevertWhen_SetMajorVersion_NotIncreasing(
        uint64 currentVersion,
        uint64 newVersion
    ) public {
        vm.assume(newVersion <= currentVersion);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(currentVersion);

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.VersionMustIncrease.selector, currentVersion, newVersion));
        config.setMajorVersion(newVersion);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(INITIAL_VERSION);
    }
}

