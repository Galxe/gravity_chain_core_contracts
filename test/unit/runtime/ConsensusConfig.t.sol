// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ConsensusConfig } from "../../../src/runtime/ConsensusConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

/// @title ConsensusConfigTest
/// @notice Unit tests for ConsensusConfig contract
contract ConsensusConfigTest is Test {
    ConsensusConfig public config;

    // Common test values (BCS-serialized bytes)
    bytes constant INITIAL_CONFIG = hex"0102030405060708";
    bytes constant NEW_CONFIG = hex"090a0b0c0d0e0f10";

    function setUp() public {
        config = new ConsensusConfig();
    }

    // ========================================================================
    // INITIAL STATE TESTS
    // ========================================================================

    function test_InitialState() public view {
        assertFalse(config.isInitialized());
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(INITIAL_CONFIG);

        assertTrue(config.isInitialized());
        assertEq(config.getCurrentConfig(), INITIAL_CONFIG);
    }

    function test_RevertWhen_Initialize_EmptyConfig() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.EmptyConfig.selector);
        config.initialize("");
    }

    function test_RevertWhen_Initialize_AlreadyInitialized() public {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(INITIAL_CONFIG);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.ConsensusConfigAlreadyInitialized.selector);
        config.initialize(NEW_CONFIG);
    }

    function test_RevertWhen_Initialize_NotGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        config.initialize(INITIAL_CONFIG);
    }

    function test_Event_Initialize() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(true, false, false, false);
        emit ConsensusConfig.ConsensusConfigUpdated(keccak256(INITIAL_CONFIG));
        config.initialize(INITIAL_CONFIG);
    }

    // ========================================================================
    // VIEW FUNCTION TESTS
    // ========================================================================

    function test_GetCurrentConfig() public {
        _initializeConfig();

        bytes memory currentConfig = config.getCurrentConfig();
        assertEq(currentConfig, INITIAL_CONFIG);
    }

    function test_RevertWhen_GetCurrentConfig_NotInitialized() public {
        vm.expectRevert(Errors.ConsensusConfigNotInitialized.selector);
        config.getCurrentConfig();
    }

    function test_GetPendingConfig_NoPending() public {
        _initializeConfig();

        (bool hasPending, bytes memory pendingConfig) = config.getPendingConfig();
        assertFalse(hasPending);
        assertEq(pendingConfig.length, 0);
    }

    function test_GetPendingConfig_HasPending() public {
        _initializeConfig();

        // Set pending config
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(NEW_CONFIG);

        (bool hasPending, bytes memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingConfig, NEW_CONFIG);
    }

    function test_RevertWhen_GetPendingConfig_NotInitialized() public {
        vm.expectRevert(Errors.ConsensusConfigNotInitialized.selector);
        config.getPendingConfig();
    }

    // ========================================================================
    // SET FOR NEXT EPOCH TESTS
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(NEW_CONFIG);

        assertTrue(config.hasPendingConfig());
        (bool hasPending, bytes memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingConfig, NEW_CONFIG);

        // Current config should not change yet
        assertEq(config.getCurrentConfig(), INITIAL_CONFIG);
    }

    function test_SetForNextEpoch_Overwrite() public {
        _initializeConfig();

        // First pending config
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(NEW_CONFIG);

        // Overwrite with another pending config
        bytes memory anotherConfig = hex"1112131415";
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(anotherConfig);

        (bool hasPending, bytes memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingConfig, anotherConfig);
    }

    function test_RevertWhen_SetForNextEpoch_EmptyConfig() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.EmptyConfig.selector);
        config.setForNextEpoch("");
    }

    function test_RevertWhen_SetForNextEpoch_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x1234);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(NEW_CONFIG);
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.ConsensusConfigNotInitialized.selector);
        config.setForNextEpoch(NEW_CONFIG);
    }

    function test_Event_SetForNextEpoch() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, false);
        emit ConsensusConfig.PendingConsensusConfigSet(keccak256(NEW_CONFIG));
        config.setForNextEpoch(NEW_CONFIG);
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeConfig();

        // Set pending config
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(NEW_CONFIG);
        assertTrue(config.hasPendingConfig());

        // Apply pending config
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        // Check that pending was applied
        assertFalse(config.hasPendingConfig());
        assertEq(config.getCurrentConfig(), NEW_CONFIG);
    }

    function test_ApplyPendingConfig_NoPending() public {
        _initializeConfig();

        // Apply without pending config should be no-op
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        // Config should remain unchanged
        assertEq(config.getCurrentConfig(), INITIAL_CONFIG);
        assertFalse(config.hasPendingConfig());
    }

    function test_RevertWhen_ApplyPendingConfig_NotReconfiguration() public {
        _initializeConfig();

        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        config.applyPendingConfig();
    }

    function test_RevertWhen_ApplyPendingConfig_NotInitialized() public {
        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(Errors.ConsensusConfigNotInitialized.selector);
        config.applyPendingConfig();
    }

    function test_Event_ApplyPendingConfig() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(NEW_CONFIG);

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(true, false, false, false);
        emit ConsensusConfig.ConsensusConfigUpdated(keccak256(NEW_CONFIG));
        config.applyPendingConfig();
    }

    function test_Event_PendingConsensusConfigCleared() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(NEW_CONFIG);

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, false);
        emit ConsensusConfig.PendingConsensusConfigCleared();
        config.applyPendingConfig();
    }

    // ========================================================================
    // ACCESS CONTROL TESTS
    // ========================================================================

    function test_RevertWhen_SetForNextEpoch_CalledByGenesis() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GENESIS, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(NEW_CONFIG);
    }

    function test_RevertWhen_SetForNextEpoch_CalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(NEW_CONFIG);
    }

    function test_RevertWhen_SetForNextEpoch_CalledByReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.RECONFIGURATION, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(NEW_CONFIG);
    }

    function test_RevertWhen_ApplyPendingConfig_CalledByGovernance() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GOVERNANCE, SystemAddresses.RECONFIGURATION)
        );
        config.applyPendingConfig();
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Initialize(
        bytes calldata configBytes
    ) public {
        vm.assume(configBytes.length > 0);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(configBytes);

        assertTrue(config.isInitialized());
        assertEq(config.getCurrentConfig(), configBytes);
    }

    function testFuzz_SetAndApplyPendingConfig(
        bytes calldata newConfigBytes
    ) public {
        vm.assume(newConfigBytes.length > 0);
        _initializeConfig();

        // Set pending
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newConfigBytes);
        assertTrue(config.hasPendingConfig());
        assertEq(config.getCurrentConfig(), INITIAL_CONFIG); // Still initial

        // Apply pending
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();
        assertFalse(config.hasPendingConfig());
        assertEq(config.getCurrentConfig(), newConfigBytes);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(INITIAL_CONFIG);
    }
}

