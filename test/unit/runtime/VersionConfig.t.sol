// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { VersionConfig } from "../../../src/runtime/VersionConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title VersionConfigTest
/// @notice Unit tests for VersionConfig contract with pending pattern
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
        assertFalse(config.hasPendingConfig());
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
    // SETTER TESTS - setForNextEpoch
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeConfig();

        uint64 newVersion = INITIAL_VERSION + 1;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newVersion);

        // Should not change current version, only set pending
        assertEq(config.majorVersion(), INITIAL_VERSION);
        assertTrue(config.hasPendingConfig());

        (bool hasPending, uint64 pendingVersion) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingVersion, newVersion);
    }

    function test_SetForNextEpoch_SkipVersions() public {
        _initializeConfig();

        // Can skip versions (e.g., go from 1 to 10)
        uint64 newVersion = 10;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newVersion);

        assertTrue(config.hasPendingConfig());
        (bool hasPending, uint64 pendingVersion) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingVersion, newVersion);
    }

    function test_RevertWhen_SetForNextEpoch_SameVersion() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.VersionMustIncrease.selector, INITIAL_VERSION, INITIAL_VERSION));
        config.setForNextEpoch(INITIAL_VERSION);
    }

    function test_RevertWhen_SetForNextEpoch_LowerVersion() public {
        _initializeConfig();

        // Try to set a lower version
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.VersionMustIncrease.selector, INITIAL_VERSION, 0));
        config.setForNextEpoch(0);
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.VersionNotInitialized.selector);
        config.setForNextEpoch(INITIAL_VERSION);
    }

    function test_RevertWhen_SetForNextEpoch_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(INITIAL_VERSION + 1);
    }

    function test_Event_SetForNextEpoch() public {
        _initializeConfig();

        uint64 newVersion = INITIAL_VERSION + 1;
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit VersionConfig.PendingVersionSet(newVersion);
        config.setForNextEpoch(newVersion);
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeConfig();

        uint64 newVersion = INITIAL_VERSION + 1;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newVersion);

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.majorVersion(), newVersion);
        assertFalse(config.hasPendingConfig());
    }

    function test_ApplyPendingConfig_NoPending() public {
        _initializeConfig();

        // Should be no-op when no pending config
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.majorVersion(), INITIAL_VERSION);
        assertFalse(config.hasPendingConfig());
    }

    function test_RevertWhen_ApplyPendingConfig_NotReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(INITIAL_VERSION + 1);

        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        config.applyPendingConfig();
    }

    function test_Event_ApplyPendingConfig() public {
        _initializeConfig();

        uint64 newVersion = INITIAL_VERSION + 1;
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newVersion);

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, true);
        emit VersionConfig.VersionUpdated(INITIAL_VERSION, newVersion);
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
        config.setForNextEpoch(INITIAL_VERSION + 1);
    }

    function test_RevertWhen_SetterCalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(INITIAL_VERSION + 1);
    }

    function test_RevertWhen_SetterCalledByReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.RECONFIGURATION, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(INITIAL_VERSION + 1);
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

    function testFuzz_SetForNextEpochAndApply(
        uint64 currentVersion,
        uint64 newVersion
    ) public {
        vm.assume(newVersion > currentVersion);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(currentVersion);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newVersion);

        assertTrue(config.hasPendingConfig());

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.majorVersion(), newVersion);
        assertFalse(config.hasPendingConfig());
    }

    function testFuzz_RevertWhen_SetForNextEpoch_NotIncreasing(
        uint64 currentVersion,
        uint64 newVersion
    ) public {
        vm.assume(newVersion <= currentVersion);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(currentVersion);

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.VersionMustIncrease.selector, currentVersion, newVersion));
        config.setForNextEpoch(newVersion);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(INITIAL_VERSION);
    }
}
