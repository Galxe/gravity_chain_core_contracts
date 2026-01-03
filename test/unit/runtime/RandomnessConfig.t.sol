// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {RandomnessConfig} from "../../../src/runtime/RandomnessConfig.sol";
import {SystemAddresses} from "../../../src/foundation/SystemAddresses.sol";
import {Errors} from "../../../src/foundation/Errors.sol";
import {NotAllowed} from "../../../src/foundation/SystemAccessControl.sol";

/// @title RandomnessConfigTest
/// @notice Unit tests for RandomnessConfig contract
contract RandomnessConfigTest is Test {
    RandomnessConfig public config;

    // Common test values (fixed-point thresholds, value / 2^64)
    // Using uint256 intermediates to avoid overflow
    uint64 constant HALF = uint64(1) << 63; // 0.5
    uint64 constant TWO_THIRDS = uint64((uint256(1) << 64) * 2 / 3); // ~0.667
    uint64 constant THREE_QUARTERS = uint64((uint256(1) << 64) * 3 / 4); // 0.75

    function setUp() public {
        config = new RandomnessConfig();
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _createOffConfig() internal pure returns (RandomnessConfig.RandomnessConfigData memory) {
        return RandomnessConfig.RandomnessConfigData({
            variant: RandomnessConfig.ConfigVariant.Off,
            configV2: RandomnessConfig.ConfigV2Data(0, 0, 0)
        });
    }

    function _createV2Config(uint64 secrecy, uint64 reconstruction, uint64 fastPath)
        internal
        pure
        returns (RandomnessConfig.RandomnessConfigData memory)
    {
        return RandomnessConfig.RandomnessConfigData({
            variant: RandomnessConfig.ConfigVariant.V2,
            configV2: RandomnessConfig.ConfigV2Data({
                secrecyThreshold: secrecy,
                reconstructionThreshold: reconstruction,
                fastPathSecrecyThreshold: fastPath
            })
        });
    }

    function _initializeWithOff() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(_createOffConfig());
    }

    function _initializeWithV2() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(_createV2Config(HALF, TWO_THIRDS, THREE_QUARTERS));
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize_Off() public {
        RandomnessConfig.RandomnessConfigData memory initConfig = _createOffConfig();

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(initConfig);

        assertTrue(config.isInitialized());
        assertFalse(config.enabled());

        RandomnessConfig.RandomnessConfigData memory currentConfig = config.getCurrentConfig();
        assertEq(uint8(currentConfig.variant), uint8(RandomnessConfig.ConfigVariant.Off));
    }

    function test_Initialize_V2() public {
        RandomnessConfig.RandomnessConfigData memory initConfig = _createV2Config(HALF, TWO_THIRDS, THREE_QUARTERS);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(initConfig);

        assertTrue(config.isInitialized());
        assertTrue(config.enabled());

        RandomnessConfig.RandomnessConfigData memory currentConfig = config.getCurrentConfig();
        assertEq(uint8(currentConfig.variant), uint8(RandomnessConfig.ConfigVariant.V2));
        assertEq(currentConfig.configV2.secrecyThreshold, HALF);
        assertEq(currentConfig.configV2.reconstructionThreshold, TWO_THIRDS);
        assertEq(currentConfig.configV2.fastPathSecrecyThreshold, THREE_QUARTERS);
    }

    function test_RevertWhen_DoubleInitialize() public {
        _initializeWithOff();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.RandomnessAlreadyInitialized.selector);
        config.initialize(_createOffConfig());
    }

    function test_RevertWhen_InitializeNotGenesis() public {
        address notGenesis = address(0x1234);
        vm.prank(notGenesis);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGenesis, SystemAddresses.GENESIS));
        config.initialize(_createOffConfig());
    }

    function test_RevertWhen_Initialize_InvalidV2Config() public {
        // reconstruction < secrecy is invalid
        RandomnessConfig.RandomnessConfigData memory invalidConfig = _createV2Config(TWO_THIRDS, HALF, THREE_QUARTERS);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRandomnessConfig.selector, "reconstruction must be >= secrecy"));
        config.initialize(invalidConfig);
    }

    // ========================================================================
    // VIEW FUNCTION TESTS
    // ========================================================================

    function test_Enabled_Off() public {
        _initializeWithOff();
        assertFalse(config.enabled());
    }

    function test_Enabled_V2() public {
        _initializeWithV2();
        assertTrue(config.enabled());
    }

    function test_RevertWhen_EnabledNotInitialized() public {
        vm.expectRevert(Errors.RandomnessNotInitialized.selector);
        config.enabled();
    }

    function test_GetCurrentConfig() public {
        _initializeWithV2();

        RandomnessConfig.RandomnessConfigData memory currentConfig = config.getCurrentConfig();
        assertEq(uint8(currentConfig.variant), uint8(RandomnessConfig.ConfigVariant.V2));
        assertEq(currentConfig.configV2.secrecyThreshold, HALF);
    }

    function test_RevertWhen_GetCurrentConfigNotInitialized() public {
        vm.expectRevert(Errors.RandomnessNotInitialized.selector);
        config.getCurrentConfig();
    }

    function test_GetPendingConfig_NoPending() public {
        _initializeWithV2();

        (bool hasPending, RandomnessConfig.RandomnessConfigData memory pendingConfig) = config.getPendingConfig();
        assertFalse(hasPending);
        // pendingConfig is uninitialized/default, but hasPending is false
        assertEq(uint8(pendingConfig.variant), uint8(RandomnessConfig.ConfigVariant.Off));
    }

    function test_GetPendingConfig_HasPending() public {
        _initializeWithV2();

        // Set pending config
        RandomnessConfig.RandomnessConfigData memory newConfig = _createOffConfig();
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newConfig);

        (bool hasPending, RandomnessConfig.RandomnessConfigData memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(uint8(pendingConfig.variant), uint8(RandomnessConfig.ConfigVariant.Off));
    }

    // ========================================================================
    // SET FOR NEXT EPOCH TESTS
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeWithV2();

        RandomnessConfig.RandomnessConfigData memory newConfig = _createOffConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newConfig);

        assertTrue(config.hasPendingConfig());
        (bool hasPending, RandomnessConfig.RandomnessConfigData memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(uint8(pendingConfig.variant), uint8(RandomnessConfig.ConfigVariant.Off));

        // Current config should not change yet
        assertTrue(config.enabled());
    }

    function test_SetForNextEpoch_Overwrite() public {
        _initializeWithV2();

        // First pending config
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(_createOffConfig());

        // Overwrite with new pending config
        RandomnessConfig.RandomnessConfigData memory newV2Config =
            _createV2Config(THREE_QUARTERS, THREE_QUARTERS, THREE_QUARTERS);
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newV2Config);

        (bool hasPending, RandomnessConfig.RandomnessConfigData memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(uint8(pendingConfig.variant), uint8(RandomnessConfig.ConfigVariant.V2));
        assertEq(pendingConfig.configV2.secrecyThreshold, THREE_QUARTERS);
    }

    function test_RevertWhen_SetForNextEpoch_NotTimelock() public {
        _initializeWithV2();

        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notTimelock, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(_createOffConfig());
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.RandomnessNotInitialized.selector);
        config.setForNextEpoch(_createOffConfig());
    }

    function test_RevertWhen_SetForNextEpoch_InvalidConfig() public {
        _initializeWithV2();

        // Invalid: reconstruction < secrecy
        RandomnessConfig.RandomnessConfigData memory invalidConfig = _createV2Config(TWO_THIRDS, HALF, THREE_QUARTERS);

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRandomnessConfig.selector, "reconstruction must be >= secrecy"));
        config.setForNextEpoch(invalidConfig);
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeWithV2();
        assertTrue(config.enabled());

        // Set pending config to Off
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(_createOffConfig());
        assertTrue(config.hasPendingConfig());

        // Apply pending config
        vm.prank(SystemAddresses.EPOCH_MANAGER);
        config.applyPendingConfig();

        // Check that pending was applied
        assertFalse(config.hasPendingConfig());
        assertFalse(config.enabled());

        RandomnessConfig.RandomnessConfigData memory currentConfig = config.getCurrentConfig();
        assertEq(uint8(currentConfig.variant), uint8(RandomnessConfig.ConfigVariant.Off));
    }

    function test_ApplyPendingConfig_NoPending() public {
        _initializeWithV2();

        // Apply without pending config should be no-op
        vm.prank(SystemAddresses.EPOCH_MANAGER);
        config.applyPendingConfig();

        // Config should remain unchanged
        assertTrue(config.enabled());
        assertFalse(config.hasPendingConfig());
    }

    function test_RevertWhen_ApplyPendingConfig_NotEpochManager() public {
        _initializeWithV2();

        address notEpochManager = address(0x1234);
        vm.prank(notEpochManager);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notEpochManager, SystemAddresses.EPOCH_MANAGER));
        config.applyPendingConfig();
    }

    function test_RevertWhen_ApplyPendingConfig_NotInitialized() public {
        vm.prank(SystemAddresses.EPOCH_MANAGER);
        vm.expectRevert(Errors.RandomnessNotInitialized.selector);
        config.applyPendingConfig();
    }

    // ========================================================================
    // CONFIG BUILDER TESTS
    // ========================================================================

    function test_NewOff() public view {
        RandomnessConfig.RandomnessConfigData memory offConfig = config.newOff();
        assertEq(uint8(offConfig.variant), uint8(RandomnessConfig.ConfigVariant.Off));
        assertEq(offConfig.configV2.secrecyThreshold, 0);
        assertEq(offConfig.configV2.reconstructionThreshold, 0);
        assertEq(offConfig.configV2.fastPathSecrecyThreshold, 0);
    }

    function test_NewV2() public view {
        RandomnessConfig.RandomnessConfigData memory v2Config = config.newV2(HALF, TWO_THIRDS, THREE_QUARTERS);
        assertEq(uint8(v2Config.variant), uint8(RandomnessConfig.ConfigVariant.V2));
        assertEq(v2Config.configV2.secrecyThreshold, HALF);
        assertEq(v2Config.configV2.reconstructionThreshold, TWO_THIRDS);
        assertEq(v2Config.configV2.fastPathSecrecyThreshold, THREE_QUARTERS);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Event_RandomnessConfigUpdated_Initialize() public {
        RandomnessConfig.RandomnessConfigData memory initConfig = _createV2Config(HALF, TWO_THIRDS, THREE_QUARTERS);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectEmit(true, true, false, false);
        emit RandomnessConfig.RandomnessConfigUpdated(RandomnessConfig.ConfigVariant.Off, RandomnessConfig.ConfigVariant.V2);
        config.initialize(initConfig);
    }

    function test_Event_PendingRandomnessConfigSet() public {
        _initializeWithV2();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, false);
        emit RandomnessConfig.PendingRandomnessConfigSet(RandomnessConfig.ConfigVariant.Off);
        config.setForNextEpoch(_createOffConfig());
    }

    function test_Event_RandomnessConfigUpdated_Apply() public {
        _initializeWithV2();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(_createOffConfig());

        vm.prank(SystemAddresses.EPOCH_MANAGER);
        vm.expectEmit(true, true, false, false);
        emit RandomnessConfig.RandomnessConfigUpdated(RandomnessConfig.ConfigVariant.V2, RandomnessConfig.ConfigVariant.Off);
        config.applyPendingConfig();
    }

    function test_Event_PendingRandomnessConfigCleared() public {
        _initializeWithV2();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(_createOffConfig());

        vm.prank(SystemAddresses.EPOCH_MANAGER);
        vm.expectEmit(false, false, false, false);
        emit RandomnessConfig.PendingRandomnessConfigCleared();
        config.applyPendingConfig();
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_InitializeV2(uint64 secrecy, uint64 reconstruction, uint64 fastPath) public {
        // Ensure valid config: reconstruction >= secrecy
        vm.assume(reconstruction >= secrecy);

        RandomnessConfig.RandomnessConfigData memory initConfig = _createV2Config(secrecy, reconstruction, fastPath);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(initConfig);

        assertTrue(config.isInitialized());
        assertTrue(config.enabled());

        RandomnessConfig.RandomnessConfigData memory currentConfig = config.getCurrentConfig();
        assertEq(currentConfig.configV2.secrecyThreshold, secrecy);
        assertEq(currentConfig.configV2.reconstructionThreshold, reconstruction);
        assertEq(currentConfig.configV2.fastPathSecrecyThreshold, fastPath);
    }

    function testFuzz_SetAndApplyPendingConfig(uint64 secrecy, uint64 reconstruction, uint64 fastPath) public {
        _initializeWithOff();
        vm.assume(reconstruction >= secrecy);

        RandomnessConfig.RandomnessConfigData memory newConfig = _createV2Config(secrecy, reconstruction, fastPath);

        // Set pending
        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newConfig);
        assertTrue(config.hasPendingConfig());
        assertFalse(config.enabled()); // Still Off

        // Apply pending
        vm.prank(SystemAddresses.EPOCH_MANAGER);
        config.applyPendingConfig();
        assertFalse(config.hasPendingConfig());
        assertTrue(config.enabled()); // Now V2

        RandomnessConfig.RandomnessConfigData memory currentConfig = config.getCurrentConfig();
        assertEq(currentConfig.configV2.secrecyThreshold, secrecy);
        assertEq(currentConfig.configV2.reconstructionThreshold, reconstruction);
        assertEq(currentConfig.configV2.fastPathSecrecyThreshold, fastPath);
    }

    function testFuzz_RevertWhen_InvalidV2Config(uint64 secrecy, uint64 reconstruction, uint64 fastPath) public {
        // Ensure invalid config: reconstruction < secrecy
        vm.assume(reconstruction < secrecy);

        RandomnessConfig.RandomnessConfigData memory invalidConfig = _createV2Config(secrecy, reconstruction, fastPath);

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRandomnessConfig.selector, "reconstruction must be >= secrecy"));
        config.initialize(invalidConfig);
    }
}

