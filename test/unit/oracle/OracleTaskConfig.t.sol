// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { OracleTaskConfig } from "../../../src/oracle/OracleTaskConfig.sol";
import { IOracleTaskConfig } from "../../../src/oracle/IOracleTaskConfig.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";

/// @title OracleTaskConfigTest
/// @notice Unit tests for OracleTaskConfig contract
contract OracleTaskConfigTest is Test {
    OracleTaskConfig public taskConfig;

    // Test addresses
    address public governance;
    address public alice;
    address public bob;

    // Test data - Source types
    uint32 public constant SOURCE_TYPE_BLOCKCHAIN = 0;
    uint32 public constant SOURCE_TYPE_JWK = 1;
    uint32 public constant SOURCE_TYPE_DNS = 2;
    uint256 public constant ETHEREUM_SOURCE_ID = 1;
    uint256 public constant ARBITRUM_SOURCE_ID = 42161;

    // Test task names
    bytes32 public constant TASK_EVENTS = keccak256("events");
    bytes32 public constant TASK_STATE_ROOTS = keccak256("state_roots");
    bytes32 public constant TASK_RECEIPTS = keccak256("receipts");

    function setUp() public {
        governance = SystemAddresses.GOVERNANCE;
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        taskConfig = new OracleTaskConfig();
    }

    // ========================================================================
    // SET TASK TESTS
    // ========================================================================

    function test_SetTask() public {
        bytes memory config = abi.encode("https://eth-mainnet.example.com", uint256(12), true);

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);

        IOracleTaskConfig.OracleTask memory task =
            taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);
        assertEq(task.config, config);
        assertTrue(task.updatedAt > 0);
    }

    function test_SetTask_UpdateExisting() public {
        bytes memory config1 = abi.encode("config v1");
        bytes memory config2 = abi.encode("config v2");

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config1);

        IOracleTaskConfig.OracleTask memory task1 =
            taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);
        uint64 updatedAt1 = task1.updatedAt;

        // Advance time
        vm.warp(block.timestamp + 100);

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config2);

        IOracleTaskConfig.OracleTask memory task2 =
            taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);
        assertEq(task2.config, config2);
        assertTrue(task2.updatedAt > updatedAt1);

        // Task count should still be 1 (update, not new)
        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);
    }

    function test_SetTask_RevertWhenNotGovernance() public {
        bytes memory config = abi.encode("config");

        vm.expectRevert();
        vm.prank(alice);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
    }

    function test_SetTask_RevertWhenEmptyConfig() public {
        bytes memory config = "";

        vm.expectRevert(abi.encodeWithSelector(Errors.EmptyConfig.selector));
        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
    }

    function test_SetTask_MultipleTasksPerSource() public {
        bytes memory eventsConfig = abi.encode("events config");
        bytes memory stateRootsConfig = abi.encode("state roots config");
        bytes memory receiptsConfig = abi.encode("receipts config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, eventsConfig);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS, stateRootsConfig);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_RECEIPTS, receiptsConfig);
        vm.stopPrank();

        // Verify all tasks exist
        assertEq(taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS).config, eventsConfig);
        assertEq(
            taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS).config, stateRootsConfig
        );
        assertEq(taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_RECEIPTS).config, receiptsConfig);

        // Verify task count
        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 3);

        // Verify task names are enumerable
        bytes32[] memory taskNames = taskConfig.getTaskNames(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(taskNames.length, 3);
    }

    function test_SetTask_MultipleSources() public {
        bytes memory ethConfig = abi.encode("ethereum config");
        bytes memory arbConfig = abi.encode("arbitrum config");
        bytes memory jwkConfig = abi.encode("jwk config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, ethConfig);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ARBITRUM_SOURCE_ID, TASK_EVENTS, arbConfig);
        taskConfig.setTask(SOURCE_TYPE_JWK, 1, TASK_EVENTS, jwkConfig);
        vm.stopPrank();

        assertEq(taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS).config, ethConfig);
        assertEq(taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ARBITRUM_SOURCE_ID, TASK_EVENTS).config, arbConfig);
        assertEq(taskConfig.getTask(SOURCE_TYPE_JWK, 1, TASK_EVENTS).config, jwkConfig);
    }

    // ========================================================================
    // REMOVE TASK TESTS
    // ========================================================================

    function test_RemoveTask() public {
        bytes memory config = abi.encode("config");

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);

        assertTrue(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS));
        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);

        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);

        assertFalse(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS));
        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);

        IOracleTaskConfig.OracleTask memory task =
            taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);
        assertEq(task.config.length, 0);
        assertEq(task.updatedAt, 0);
    }

    function test_RemoveTask_RevertWhenNotGovernance() public {
        bytes memory config = abi.encode("config");

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);

        vm.expectRevert();
        vm.prank(alice);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);
    }

    function test_RemoveTask_NonExistent() public {
        // Should not revert when removing non-existent task
        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);

        assertFalse(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS));
    }

    function test_RemoveTask_DoesNotAffectOtherTasks() public {
        bytes memory eventsConfig = abi.encode("events config");
        bytes memory stateRootsConfig = abi.encode("state roots config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, eventsConfig);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS, stateRootsConfig);
        vm.stopPrank();

        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 2);

        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);

        assertFalse(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS));
        assertTrue(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS));
        assertEq(
            taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS).config, stateRootsConfig
        );
        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);
    }

    function test_RemoveTask_DoesNotAffectOtherSources() public {
        bytes memory ethConfig = abi.encode("ethereum config");
        bytes memory arbConfig = abi.encode("arbitrum config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, ethConfig);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ARBITRUM_SOURCE_ID, TASK_EVENTS, arbConfig);
        vm.stopPrank();

        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);

        assertFalse(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS));
        assertTrue(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ARBITRUM_SOURCE_ID, TASK_EVENTS));
        assertEq(taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ARBITRUM_SOURCE_ID, TASK_EVENTS).config, arbConfig);
    }

    // ========================================================================
    // QUERY TESTS
    // ========================================================================

    function test_GetTask_NotFound() public view {
        IOracleTaskConfig.OracleTask memory task =
            taskConfig.getTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);
        assertEq(task.config.length, 0);
        assertEq(task.updatedAt, 0);
    }

    function test_HasTask() public {
        assertFalse(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS));

        bytes memory config = abi.encode("config");
        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);

        assertTrue(taskConfig.hasTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS));
    }

    function test_GetTaskNames() public {
        bytes memory config1 = abi.encode("config1");
        bytes memory config2 = abi.encode("config2");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config1);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS, config2);
        vm.stopPrank();

        bytes32[] memory taskNames = taskConfig.getTaskNames(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID);
        assertEq(taskNames.length, 2);

        // Check that both task names are in the array
        bool hasEvents = false;
        bool hasStateRoots = false;
        for (uint256 i = 0; i < taskNames.length; i++) {
            if (taskNames[i] == TASK_EVENTS) hasEvents = true;
            if (taskNames[i] == TASK_STATE_ROOTS) hasStateRoots = true;
        }
        assertTrue(hasEvents);
        assertTrue(hasStateRoots);
    }

    function test_GetTaskCount() public {
        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 0);

        bytes memory config = abi.encode("config");
        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);

        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 1);

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS, config);

        assertEq(taskConfig.getTaskCount(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID), 2);
    }

    function test_GetTaskNameAt() public {
        bytes memory config = abi.encode("config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS, config);
        vm.stopPrank();

        bytes32 name0 = taskConfig.getTaskNameAt(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 0);
        bytes32 name1 = taskConfig.getTaskNameAt(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, 1);

        // Both should be valid task names
        assertTrue(name0 == TASK_EVENTS || name0 == TASK_STATE_ROOTS);
        assertTrue(name1 == TASK_EVENTS || name1 == TASK_STATE_ROOTS);
        assertTrue(name0 != name1);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_TaskSet() public {
        bytes memory config = abi.encode("config");

        vm.expectEmit(true, true, true, true);
        emit IOracleTaskConfig.TaskSet(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
    }

    function test_Events_TaskRemoved() public {
        bytes memory config = abi.encode("config");

        vm.prank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);

        vm.expectEmit(true, true, true, true);
        emit IOracleTaskConfig.TaskRemoved(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);

        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_SetTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName,
        bytes memory config
    ) public {
        vm.assume(config.length > 0);

        vm.prank(governance);
        taskConfig.setTask(sourceType, sourceId, taskName, config);

        IOracleTaskConfig.OracleTask memory task = taskConfig.getTask(sourceType, sourceId, taskName);
        assertEq(task.config, config);
        assertTrue(task.updatedAt > 0);
        assertTrue(taskConfig.hasTask(sourceType, sourceId, taskName));
        assertEq(taskConfig.getTaskCount(sourceType, sourceId), 1);
    }

    function testFuzz_RemoveTask(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName,
        bytes memory config
    ) public {
        vm.assume(config.length > 0);

        vm.prank(governance);
        taskConfig.setTask(sourceType, sourceId, taskName, config);

        assertTrue(taskConfig.hasTask(sourceType, sourceId, taskName));

        vm.prank(governance);
        taskConfig.removeTask(sourceType, sourceId, taskName);

        assertFalse(taskConfig.hasTask(sourceType, sourceId, taskName));
        assertEq(taskConfig.getTaskCount(sourceType, sourceId), 0);
    }

    function testFuzz_MultipleTasks(
        uint32 sourceType,
        uint256 sourceId,
        bytes32 taskName1,
        bytes32 taskName2
    ) public {
        vm.assume(taskName1 != taskName2);

        bytes memory config1 = abi.encode("config1");
        bytes memory config2 = abi.encode("config2");

        vm.startPrank(governance);
        taskConfig.setTask(sourceType, sourceId, taskName1, config1);
        taskConfig.setTask(sourceType, sourceId, taskName2, config2);
        vm.stopPrank();

        assertEq(taskConfig.getTask(sourceType, sourceId, taskName1).config, config1);
        assertEq(taskConfig.getTask(sourceType, sourceId, taskName2).config, config2);
        assertEq(taskConfig.getTaskCount(sourceType, sourceId), 2);

        // Remove one, other should remain
        vm.prank(governance);
        taskConfig.removeTask(sourceType, sourceId, taskName1);

        assertFalse(taskConfig.hasTask(sourceType, sourceId, taskName1));
        assertTrue(taskConfig.hasTask(sourceType, sourceId, taskName2));
        assertEq(taskConfig.getTaskCount(sourceType, sourceId), 1);
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
        taskConfig.setTask(sourceType1, sourceId1, TASK_EVENTS, config1);
        taskConfig.setTask(sourceType2, sourceId2, TASK_EVENTS, config2);
        vm.stopPrank();

        assertEq(taskConfig.getTask(sourceType1, sourceId1, TASK_EVENTS).config, config1);
        assertEq(taskConfig.getTask(sourceType2, sourceId2, TASK_EVENTS).config, config2);

        // Remove one, other should remain
        vm.prank(governance);
        taskConfig.removeTask(sourceType1, sourceId1, TASK_EVENTS);

        assertFalse(taskConfig.hasTask(sourceType1, sourceId1, TASK_EVENTS));
        assertTrue(taskConfig.hasTask(sourceType2, sourceId2, TASK_EVENTS));
    }

    // ========================================================================
    // SOURCE ENUMERATION TESTS
    // ========================================================================

    function test_GetSourceTypes_Empty() public view {
        uint32[] memory sourceTypes = taskConfig.getSourceTypes();
        assertEq(sourceTypes.length, 0);
    }

    function test_GetSourceTypes() public {
        bytes memory config = abi.encode("config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
        taskConfig.setTask(SOURCE_TYPE_JWK, 0, TASK_EVENTS, config);
        vm.stopPrank();

        uint32[] memory sourceTypes = taskConfig.getSourceTypes();
        assertEq(sourceTypes.length, 2);

        // Check both source types are present
        bool hasBlockchain = false;
        bool hasJwk = false;
        for (uint256 i = 0; i < sourceTypes.length; i++) {
            if (sourceTypes[i] == SOURCE_TYPE_BLOCKCHAIN) hasBlockchain = true;
            if (sourceTypes[i] == SOURCE_TYPE_JWK) hasJwk = true;
        }
        assertTrue(hasBlockchain);
        assertTrue(hasJwk);
    }

    function test_GetSourceIds() public {
        bytes memory config = abi.encode("config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ARBITRUM_SOURCE_ID, TASK_EVENTS, config);
        vm.stopPrank();

        uint256[] memory sourceIds = taskConfig.getSourceIds(SOURCE_TYPE_BLOCKCHAIN);
        assertEq(sourceIds.length, 2);

        // Check both source IDs are present
        bool hasEthereum = false;
        bool hasArbitrum = false;
        for (uint256 i = 0; i < sourceIds.length; i++) {
            if (sourceIds[i] == ETHEREUM_SOURCE_ID) hasEthereum = true;
            if (sourceIds[i] == ARBITRUM_SOURCE_ID) hasArbitrum = true;
        }
        assertTrue(hasEthereum);
        assertTrue(hasArbitrum);
    }

    function test_GetSourceIds_Empty() public view {
        uint256[] memory sourceIds = taskConfig.getSourceIds(SOURCE_TYPE_BLOCKCHAIN);
        assertEq(sourceIds.length, 0);
    }

    function test_GetAllTasks() public {
        bytes memory ethConfig = abi.encode("ethereum config");
        bytes memory arbConfig = abi.encode("arbitrum config");
        bytes memory jwkConfig = abi.encode("jwk config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, ethConfig);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ARBITRUM_SOURCE_ID, TASK_STATE_ROOTS, arbConfig);
        taskConfig.setTask(SOURCE_TYPE_JWK, 0, TASK_EVENTS, jwkConfig);
        vm.stopPrank();

        IOracleTaskConfig.FullTaskInfo[] memory tasks = taskConfig.getAllTasks();
        assertEq(tasks.length, 3);

        // Verify all tasks are present
        bool foundEth = false;
        bool foundArb = false;
        bool foundJwk = false;
        for (uint256 i = 0; i < tasks.length; i++) {
            if (tasks[i].sourceType == SOURCE_TYPE_BLOCKCHAIN && tasks[i].sourceId == ETHEREUM_SOURCE_ID) {
                foundEth = true;
                assertEq(tasks[i].taskName, TASK_EVENTS);
                assertEq(tasks[i].config, ethConfig);
            }
            if (tasks[i].sourceType == SOURCE_TYPE_BLOCKCHAIN && tasks[i].sourceId == ARBITRUM_SOURCE_ID) {
                foundArb = true;
                assertEq(tasks[i].taskName, TASK_STATE_ROOTS);
                assertEq(tasks[i].config, arbConfig);
            }
            if (tasks[i].sourceType == SOURCE_TYPE_JWK && tasks[i].sourceId == 0) {
                foundJwk = true;
                assertEq(tasks[i].taskName, TASK_EVENTS);
                assertEq(tasks[i].config, jwkConfig);
            }
        }
        assertTrue(foundEth);
        assertTrue(foundArb);
        assertTrue(foundJwk);
    }

    function test_GetAllTasks_Empty() public view {
        IOracleTaskConfig.FullTaskInfo[] memory tasks = taskConfig.getAllTasks();
        assertEq(tasks.length, 0);
    }

    function test_SourceEnumeration_CleanupOnRemove() public {
        bytes memory config = abi.encode("config");

        // Add two tasks to same source
        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS, config);
        vm.stopPrank();

        // Verify source is registered
        uint32[] memory sourceTypes = taskConfig.getSourceTypes();
        assertEq(sourceTypes.length, 1);
        uint256[] memory sourceIds = taskConfig.getSourceIds(SOURCE_TYPE_BLOCKCHAIN);
        assertEq(sourceIds.length, 1);

        // Remove first task - source should still be registered
        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS);

        sourceTypes = taskConfig.getSourceTypes();
        assertEq(sourceTypes.length, 1);
        sourceIds = taskConfig.getSourceIds(SOURCE_TYPE_BLOCKCHAIN);
        assertEq(sourceIds.length, 1);

        // Remove second task - source should be cleaned up
        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_STATE_ROOTS);

        sourceTypes = taskConfig.getSourceTypes();
        assertEq(sourceTypes.length, 0);
        sourceIds = taskConfig.getSourceIds(SOURCE_TYPE_BLOCKCHAIN);
        assertEq(sourceIds.length, 0);
    }

    function test_SourceEnumeration_MultipleSourceTypes() public {
        bytes memory config = abi.encode("config");

        vm.startPrank(governance);
        taskConfig.setTask(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_SOURCE_ID, TASK_EVENTS, config);
        taskConfig.setTask(SOURCE_TYPE_JWK, 0, TASK_EVENTS, config);
        taskConfig.setTask(SOURCE_TYPE_DNS, 1, TASK_EVENTS, config);
        vm.stopPrank();

        uint32[] memory sourceTypes = taskConfig.getSourceTypes();
        assertEq(sourceTypes.length, 3);

        // Remove JWK task - only JWK sourceType should be removed
        vm.prank(governance);
        taskConfig.removeTask(SOURCE_TYPE_JWK, 0, TASK_EVENTS);

        sourceTypes = taskConfig.getSourceTypes();
        assertEq(sourceTypes.length, 2);

        // Verify JWK is no longer in source types
        for (uint256 i = 0; i < sourceTypes.length; i++) {
            assertTrue(sourceTypes[i] != SOURCE_TYPE_JWK);
        }
    }
}

