// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Timestamp} from "../../../src/runtime/Timestamp.sol";
import {SystemAddresses} from "../../../src/foundation/SystemAddresses.sol";
import {Errors} from "../../../src/foundation/Errors.sol";
import {NotAllowed} from "../../../src/foundation/SystemAccessControl.sol";

/// @title TimestampTest
/// @notice Unit tests for Timestamp contract
contract TimestampTest is Test {
    Timestamp public timestamp;

    // Common test values
    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant ONE_SECOND = 1_000_000;
    uint64 constant ONE_HOUR = 3_600_000_000;
    address constant PROPOSER = address(0x1234);

    function setUp() public {
        timestamp = new Timestamp();
    }

    // ========================================================================
    // CONSTANTS TESTS
    // ========================================================================

    function test_MicroConversionFactor() public view {
        assertEq(timestamp.MICRO_CONVERSION_FACTOR(), 1_000_000);
    }

    // ========================================================================
    // INITIAL STATE TESTS
    // ========================================================================

    function test_InitialState() public view {
        assertEq(timestamp.microseconds(), 0);
        assertEq(timestamp.nowMicroseconds(), 0);
        assertEq(timestamp.nowSeconds(), 0);
    }

    // ========================================================================
    // VIEW FUNCTION TESTS
    // ========================================================================

    function test_NowMicroseconds() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        assertEq(timestamp.nowMicroseconds(), INITIAL_TIME);
    }

    function test_NowSeconds() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // 1_000_000_000_000_000 microseconds = 1_000_000_000 seconds
        assertEq(timestamp.nowSeconds(), INITIAL_TIME / ONE_SECOND);
    }

    function test_NowSecondsConversion() public {
        // Test with a value that doesn't divide evenly
        uint64 microTime = 5_500_000; // 5.5 seconds
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, microTime);

        // Should truncate to 5 seconds
        assertEq(timestamp.nowSeconds(), 5);
    }

    // ========================================================================
    // NORMAL BLOCK UPDATE TESTS
    // ========================================================================

    function test_UpdateGlobalTime_NormalBlock() public {
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        assertEq(timestamp.microseconds(), INITIAL_TIME);
    }

    function test_UpdateGlobalTime_NormalBlock_Advance() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // Advance time
        uint64 newTime = INITIAL_TIME + ONE_HOUR;
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, newTime);

        assertEq(timestamp.microseconds(), newTime);
    }

    function test_UpdateGlobalTime_NormalBlock_MinimalAdvance() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // Advance by just 1 microsecond
        uint64 newTime = INITIAL_TIME + 1;
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, newTime);

        assertEq(timestamp.microseconds(), newTime);
    }

    function test_RevertWhen_NormalBlock_TimeNotAdvancing() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // Try to set same time (should revert)
        vm.prank(SystemAddresses.BLOCK);
        vm.expectRevert(abi.encodeWithSelector(Errors.TimestampMustAdvance.selector, INITIAL_TIME, INITIAL_TIME));
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);
    }

    function test_RevertWhen_NormalBlock_TimeGoingBackwards() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // Try to go backwards
        uint64 pastTime = INITIAL_TIME - ONE_HOUR;
        vm.prank(SystemAddresses.BLOCK);
        vm.expectRevert(abi.encodeWithSelector(Errors.TimestampMustAdvance.selector, pastTime, INITIAL_TIME));
        timestamp.updateGlobalTime(PROPOSER, pastTime);
    }

    // ========================================================================
    // NIL BLOCK UPDATE TESTS
    // ========================================================================

    function test_UpdateGlobalTime_NilBlock() public {
        // Set initial time with normal block
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // NIL block with same timestamp
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(SystemAddresses.SYSTEM_CALLER, INITIAL_TIME);

        // Time should stay the same
        assertEq(timestamp.microseconds(), INITIAL_TIME);
    }

    function test_UpdateGlobalTime_NilBlock_FirstBlock() public {
        // First block can be NIL block with 0 timestamp
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(SystemAddresses.SYSTEM_CALLER, 0);

        assertEq(timestamp.microseconds(), 0);
    }

    function test_RevertWhen_NilBlock_TimeDifferent() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // NIL block with different timestamp should revert
        uint64 differentTime = INITIAL_TIME + 1;
        vm.prank(SystemAddresses.BLOCK);
        vm.expectRevert(abi.encodeWithSelector(Errors.TimestampMustEqual.selector, differentTime, INITIAL_TIME));
        timestamp.updateGlobalTime(SystemAddresses.SYSTEM_CALLER, differentTime);
    }

    function test_RevertWhen_NilBlock_TimeLower() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // NIL block with lower timestamp should revert
        uint64 lowerTime = INITIAL_TIME - 1;
        vm.prank(SystemAddresses.BLOCK);
        vm.expectRevert(abi.encodeWithSelector(Errors.TimestampMustEqual.selector, lowerTime, INITIAL_TIME));
        timestamp.updateGlobalTime(SystemAddresses.SYSTEM_CALLER, lowerTime);
    }

    // ========================================================================
    // ACCESS CONTROL TESTS
    // ========================================================================

    function test_RevertWhen_CallerNotBlock() public {
        address notBlock = address(0x9999);
        vm.prank(notBlock);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notBlock, SystemAddresses.BLOCK));
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);
    }

    function test_RevertWhen_CallerIsSystemCaller() public {
        // SYSTEM_CALLER is not allowed to call directly (only BLOCK can)
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.BLOCK));
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);
    }

    function test_RevertWhen_CallerIsGenesis() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GENESIS, SystemAddresses.BLOCK));
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);
    }

    function test_RevertWhen_CallerIsTimelock() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GOVERNANCE, SystemAddresses.BLOCK));
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Event_GlobalTimeUpdated_NormalBlock() public {
        vm.prank(SystemAddresses.BLOCK);
        vm.expectEmit(true, false, false, true);
        emit Timestamp.GlobalTimeUpdated(PROPOSER, 0, INITIAL_TIME);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);
    }

    function test_Event_GlobalTimeUpdated_NilBlock() public {
        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, INITIAL_TIME);

        // NIL block should also emit event
        vm.prank(SystemAddresses.BLOCK);
        vm.expectEmit(true, false, false, true);
        emit Timestamp.GlobalTimeUpdated(SystemAddresses.SYSTEM_CALLER, INITIAL_TIME, INITIAL_TIME);
        timestamp.updateGlobalTime(SystemAddresses.SYSTEM_CALLER, INITIAL_TIME);
    }

    function test_Event_GlobalTimeUpdated_Sequence() public {
        uint64 time1 = INITIAL_TIME;
        uint64 time2 = INITIAL_TIME + ONE_HOUR;
        uint64 time3 = INITIAL_TIME + 2 * ONE_HOUR;

        vm.prank(SystemAddresses.BLOCK);
        vm.expectEmit(true, false, false, true);
        emit Timestamp.GlobalTimeUpdated(PROPOSER, 0, time1);
        timestamp.updateGlobalTime(PROPOSER, time1);

        vm.prank(SystemAddresses.BLOCK);
        vm.expectEmit(true, false, false, true);
        emit Timestamp.GlobalTimeUpdated(PROPOSER, time1, time2);
        timestamp.updateGlobalTime(PROPOSER, time2);

        vm.prank(SystemAddresses.BLOCK);
        vm.expectEmit(true, false, false, true);
        emit Timestamp.GlobalTimeUpdated(PROPOSER, time2, time3);
        timestamp.updateGlobalTime(PROPOSER, time3);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_UpdateGlobalTime_Advance(uint64 initial, uint64 advance) public {
        // Bound to avoid overflow
        initial = uint64(bound(initial, 1, type(uint64).max / 2));
        advance = uint64(bound(advance, 1, type(uint64).max / 2));

        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, initial);

        // Advance time
        uint64 newTime = initial + advance;
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, newTime);

        assertEq(timestamp.microseconds(), newTime);
    }

    function testFuzz_NowSecondsConversion(uint64 microTime) public {
        // Bound to ensure we can set it
        vm.assume(microTime > 0);

        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, microTime);

        // Verify conversion
        uint64 expectedSeconds = microTime / timestamp.MICRO_CONVERSION_FACTOR();
        assertEq(timestamp.nowSeconds(), expectedSeconds);
    }

    function testFuzz_NilBlock_SameTime(uint64 time) public {
        vm.assume(time > 0);

        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, time);

        // NIL block with same time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(SystemAddresses.SYSTEM_CALLER, time);

        // Time should stay the same
        assertEq(timestamp.microseconds(), time);
    }

    function testFuzz_RevertWhen_NormalBlock_NotAdvancing(uint64 time) public {
        vm.assume(time > 0);

        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(PROPOSER, time);

        // Try to set same time with normal block
        vm.prank(SystemAddresses.BLOCK);
        vm.expectRevert(abi.encodeWithSelector(Errors.TimestampMustAdvance.selector, time, time));
        timestamp.updateGlobalTime(PROPOSER, time);
    }
}

