// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { OnDemandOracleTaskConfig } from "../../../src/oracle/ondemand/OnDemandOracleTaskConfig.sol";
import { IOnDemandOracleTaskConfig } from "../../../src/oracle/ondemand/IOnDemandOracleTaskConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";

/// @title OnDemandOracleTaskConfigTest
/// @notice Unit tests for OnDemandOracleTaskConfig contract
contract OnDemandOracleTaskConfigTest is Test {
    OnDemandOracleTaskConfig public taskConfig;

    // Test addresses
    address public governance;
    address public alice;
    address public bob;

    // Test data - Source types
    uint32 public constant SOURCE_TYPE_PRICE_FEED = 3;
    uint32 public constant SOURCE_TYPE_CUSTOM = 100;
    uint256 public constant NASDAQ_SOURCE_ID = 1;
    uint256 public constant NYSE_SOURCE_ID = 2;

    function setUp() public {
        governance = SystemAddresses.GOVERNANCE;
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        taskConfig = new OnDemandOracleTaskConfig();
    }

    // ========================================================================
    // SET TASK TYPE TESTS
    // ========================================================================

    function test_SetTaskType() public {
        bytes memory config = abi.encode("https://api.nasdaq.com/prices", uint256(60), true);

        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);

        IOnDemandOracleTaskConfig.OnDemandTaskType memory taskType =
            taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);
        assertEq(taskType.config, config);
        assertTrue(taskType.updatedAt > 0);
    }

    function test_SetTaskType_UpdateExisting() public {
        bytes memory config1 = abi.encode("config v1");
        bytes memory config2 = abi.encode("config v2");

        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config1);

        IOnDemandOracleTaskConfig.OnDemandTaskType memory taskType1 =
            taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);
        uint64 updatedAt1 = taskType1.updatedAt;

        // Advance time
        vm.warp(block.timestamp + 100);

        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config2);

        IOnDemandOracleTaskConfig.OnDemandTaskType memory taskType2 =
            taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);
        assertEq(taskType2.config, config2);
        assertTrue(taskType2.updatedAt > updatedAt1);
    }

    function test_SetTaskType_RevertWhenNotGovernance() public {
        bytes memory config = abi.encode("config");

        vm.expectRevert();
        vm.prank(alice);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);
    }

    function test_SetTaskType_RevertWhenEmptyConfig() public {
        bytes memory config = "";

        vm.expectRevert(abi.encodeWithSelector(Errors.EmptyConfig.selector));
        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);
    }

    function test_SetTaskType_MultipleSources() public {
        bytes memory nasdaqConfig = abi.encode("nasdaq config");
        bytes memory nyseConfig = abi.encode("nyse config");
        bytes memory customConfig = abi.encode("custom config");

        vm.startPrank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, nasdaqConfig);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NYSE_SOURCE_ID, nyseConfig);
        taskConfig.setTaskType(SOURCE_TYPE_CUSTOM, 1, customConfig);
        vm.stopPrank();

        assertEq(taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID).config, nasdaqConfig);
        assertEq(taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NYSE_SOURCE_ID).config, nyseConfig);
        assertEq(taskConfig.getTaskType(SOURCE_TYPE_CUSTOM, 1).config, customConfig);
    }

    // ========================================================================
    // REMOVE TASK TYPE TESTS
    // ========================================================================

    function test_RemoveTaskType() public {
        bytes memory config = abi.encode("config");

        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);

        assertTrue(taskConfig.isSupported(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID));

        vm.prank(governance);
        taskConfig.removeTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);

        assertFalse(taskConfig.isSupported(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID));

        IOnDemandOracleTaskConfig.OnDemandTaskType memory taskType =
            taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);
        assertEq(taskType.config.length, 0);
        assertEq(taskType.updatedAt, 0);
    }

    function test_RemoveTaskType_RevertWhenNotGovernance() public {
        bytes memory config = abi.encode("config");

        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);

        vm.expectRevert();
        vm.prank(alice);
        taskConfig.removeTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);
    }

    function test_RemoveTaskType_NonExistent() public {
        // Should not revert when removing non-existent task type
        vm.prank(governance);
        taskConfig.removeTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);

        assertFalse(taskConfig.isSupported(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID));
    }

    function test_RemoveTaskType_DoesNotAffectOtherTypes() public {
        bytes memory nasdaqConfig = abi.encode("nasdaq config");
        bytes memory nyseConfig = abi.encode("nyse config");

        vm.startPrank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, nasdaqConfig);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NYSE_SOURCE_ID, nyseConfig);
        vm.stopPrank();

        vm.prank(governance);
        taskConfig.removeTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);

        assertFalse(taskConfig.isSupported(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID));
        assertTrue(taskConfig.isSupported(SOURCE_TYPE_PRICE_FEED, NYSE_SOURCE_ID));
        assertEq(taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NYSE_SOURCE_ID).config, nyseConfig);
    }

    // ========================================================================
    // QUERY TESTS
    // ========================================================================

    function test_GetTaskType_NotFound() public view {
        IOnDemandOracleTaskConfig.OnDemandTaskType memory taskType =
            taskConfig.getTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);
        assertEq(taskType.config.length, 0);
        assertEq(taskType.updatedAt, 0);
    }

    function test_IsSupported() public {
        assertFalse(taskConfig.isSupported(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID));

        bytes memory config = abi.encode("config");
        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);

        assertTrue(taskConfig.isSupported(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID));
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_TaskTypeSet() public {
        bytes memory config = abi.encode("config");

        vm.expectEmit(true, true, true, true);
        emit IOnDemandOracleTaskConfig.TaskTypeSet(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);

        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);
    }

    function test_Events_TaskTypeRemoved() public {
        bytes memory config = abi.encode("config");

        vm.prank(governance);
        taskConfig.setTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID, config);

        vm.expectEmit(true, true, true, true);
        emit IOnDemandOracleTaskConfig.TaskTypeRemoved(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);

        vm.prank(governance);
        taskConfig.removeTaskType(SOURCE_TYPE_PRICE_FEED, NASDAQ_SOURCE_ID);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_SetTaskType(
        uint32 sourceType,
        uint256 sourceId,
        bytes memory config
    ) public {
        vm.assume(config.length > 0);

        vm.prank(governance);
        taskConfig.setTaskType(sourceType, sourceId, config);

        IOnDemandOracleTaskConfig.OnDemandTaskType memory taskType = taskConfig.getTaskType(sourceType, sourceId);
        assertEq(taskType.config, config);
        assertTrue(taskType.updatedAt > 0);
        assertTrue(taskConfig.isSupported(sourceType, sourceId));
    }

    function testFuzz_RemoveTaskType(
        uint32 sourceType,
        uint256 sourceId,
        bytes memory config
    ) public {
        vm.assume(config.length > 0);

        vm.prank(governance);
        taskConfig.setTaskType(sourceType, sourceId, config);

        assertTrue(taskConfig.isSupported(sourceType, sourceId));

        vm.prank(governance);
        taskConfig.removeTaskType(sourceType, sourceId);

        assertFalse(taskConfig.isSupported(sourceType, sourceId));
    }

    function testFuzz_IndependentSources(
        uint32 sourceType1,
        uint256 sourceId1,
        uint32 sourceType2,
        uint256 sourceId2
    ) public {
        vm.assume(sourceType1 != sourceType2 || sourceId1 != sourceId2);

        bytes memory config1 = abi.encode("config1");
        bytes memory config2 = abi.encode("config2");

        vm.startPrank(governance);
        taskConfig.setTaskType(sourceType1, sourceId1, config1);
        taskConfig.setTaskType(sourceType2, sourceId2, config2);
        vm.stopPrank();

        assertEq(taskConfig.getTaskType(sourceType1, sourceId1).config, config1);
        assertEq(taskConfig.getTaskType(sourceType2, sourceId2).config, config2);

        // Remove one, other should remain
        vm.prank(governance);
        taskConfig.removeTaskType(sourceType1, sourceId1);

        assertFalse(taskConfig.isSupported(sourceType1, sourceId1));
        assertTrue(taskConfig.isSupported(sourceType2, sourceId2));
    }
}

