// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Errors } from "../../../src/foundation/Errors.sol";

/// @title ErrorsTest
/// @notice Unit tests for Errors library
/// @dev Tests that all errors can be properly thrown and caught with correct parameters.
///      All timestamps use microseconds (1 second = 1_000_000 microseconds).
contract ErrorsTest is Test {
    // Microsecond conversion factor
    uint64 internal constant MICRO = 1_000_000;

    // Example timestamps in microseconds
    uint64 internal constant TIMESTAMP_NOV_2023 = 1_700_000_000 * MICRO;
    uint64 internal constant TIMESTAMP_OCT_2023 = 1_699_000_000 * MICRO;
    uint64 internal constant ONE_DAY_MICROS = 86_400 * MICRO;
    uint64 internal constant THIRTY_DAYS_MICROS = 30 * ONE_DAY_MICROS;
    uint64 internal constant SEVEN_DAYS_MICROS = 7 * ONE_DAY_MICROS;

    // ========================================================================
    // STAKING ERRORS
    // ========================================================================

    function test_NoStakePosition() public {
        address staker = address(0x1234);

        vm.expectRevert(abi.encodeWithSelector(Errors.NoStakePosition.selector, staker));
        this.throwNoStakePosition(staker);
    }

    function test_InsufficientStake() public {
        uint256 required = 1000 ether;
        uint256 actual = 500 ether;

        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientStake.selector, required, actual));
        this.throwInsufficientStake(required, actual);
    }

    function test_LockupNotExpired() public {
        uint64 lockedUntil = TIMESTAMP_NOV_2023; // Lockup expires Nov 2023
        uint64 currentTime = TIMESTAMP_OCT_2023; // Current time is Oct 2023

        vm.expectRevert(abi.encodeWithSelector(Errors.LockupNotExpired.selector, lockedUntil, currentTime));
        this.throwLockupNotExpired(lockedUntil, currentTime);
    }

    function test_ZeroAmount() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        this.throwZeroAmount();
    }

    // ========================================================================
    // VALIDATOR ERRORS
    // ========================================================================

    function test_ValidatorNotFound() public {
        address validator = address(0x1234);

        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorNotFound.selector, validator));
        this.throwValidatorNotFound(validator);
    }

    function test_ValidatorAlreadyExists() public {
        address validator = address(0x1234);

        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorAlreadyExists.selector, validator));
        this.throwValidatorAlreadyExists(validator);
    }

    function test_InvalidStatus() public {
        uint8 expected = 2;
        uint8 actual = 0;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidStatus.selector, expected, actual));
        this.throwInvalidStatus(expected, actual);
    }

    function test_InsufficientBond() public {
        uint256 required = 1000 ether;
        uint256 actual = 500 ether;

        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBond.selector, required, actual));
        this.throwInsufficientBond(required, actual);
    }

    function test_ExceedsMaximumBond() public {
        uint256 maximum = 10000 ether;
        uint256 actual = 15000 ether;

        vm.expectRevert(abi.encodeWithSelector(Errors.ExceedsMaximumBond.selector, maximum, actual));
        this.throwExceedsMaximumBond(maximum, actual);
    }

    function test_NotOwner() public {
        address expected = address(0x1234);
        address actual = address(0x5678);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOwner.selector, expected, actual));
        this.throwNotOwner(expected, actual);
    }

    function test_NotOperator() public {
        address expected = address(0x1234);
        address actual = address(0x5678);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOperator.selector, expected, actual));
        this.throwNotOperator(expected, actual);
    }

    function test_ValidatorSetChangesDisabled() public {
        vm.expectRevert(Errors.ValidatorSetChangesDisabled.selector);
        this.throwValidatorSetChangesDisabled();
    }

    function test_MaxValidatorSetSizeReached() public {
        uint256 maxSize = 100;

        vm.expectRevert(abi.encodeWithSelector(Errors.MaxValidatorSetSizeReached.selector, maxSize));
        this.throwMaxValidatorSetSizeReached(maxSize);
    }

    function test_VotingPowerIncreaseLimitExceeded() public {
        uint256 limit = 10;
        uint256 actual = 15;

        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPowerIncreaseLimitExceeded.selector, limit, actual));
        this.throwVotingPowerIncreaseLimitExceeded(limit, actual);
    }

    function test_MonikerTooLong() public {
        uint256 maxLength = 31;
        uint256 actualLength = 50;

        vm.expectRevert(abi.encodeWithSelector(Errors.MonikerTooLong.selector, maxLength, actualLength));
        this.throwMonikerTooLong(maxLength, actualLength);
    }

    function test_UnbondNotReady() public {
        uint64 availableAt = TIMESTAMP_NOV_2023; // Unbond available Nov 2023
        uint64 currentTime = TIMESTAMP_OCT_2023; // Current time is Oct 2023

        vm.expectRevert(abi.encodeWithSelector(Errors.UnbondNotReady.selector, availableAt, currentTime));
        this.throwUnbondNotReady(availableAt, currentTime);
    }

    // ========================================================================
    // RECONFIGURATION ERRORS
    // ========================================================================

    function test_ReconfigurationInProgress() public {
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        this.throwReconfigurationInProgress();
    }

    function test_ReconfigurationNotInProgress() public {
        vm.expectRevert(Errors.ReconfigurationNotInProgress.selector);
        this.throwReconfigurationNotInProgress();
    }

    function test_EpochNotYetEnded() public {
        uint64 nextEpochTime = TIMESTAMP_NOV_2023; // Next epoch Nov 2023
        uint64 currentTime = TIMESTAMP_OCT_2023; // Current time is Oct 2023

        vm.expectRevert(abi.encodeWithSelector(Errors.EpochNotYetEnded.selector, nextEpochTime, currentTime));
        this.throwEpochNotYetEnded(nextEpochTime, currentTime);
    }

    // ========================================================================
    // GOVERNANCE ERRORS
    // ========================================================================

    function test_ProposalNotFound() public {
        uint64 proposalId = 42;

        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, proposalId));
        this.throwProposalNotFound(proposalId);
    }

    function test_VotingPeriodEnded() public {
        uint64 expirationTime = TIMESTAMP_OCT_2023; // Voting ended Oct 2023

        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodEnded.selector, expirationTime));
        this.throwVotingPeriodEnded(expirationTime);
    }

    function test_VotingPeriodNotEnded() public {
        uint64 expirationTime = TIMESTAMP_NOV_2023; // Voting ends Nov 2023

        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodNotEnded.selector, expirationTime));
        this.throwVotingPeriodNotEnded(expirationTime);
    }

    function test_ProposalAlreadyResolved() public {
        uint64 proposalId = 42;

        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalAlreadyResolved.selector, proposalId));
        this.throwProposalAlreadyResolved(proposalId);
    }

    function test_ExecutionHashMismatch() public {
        bytes32 expected = keccak256("expected");
        bytes32 actual = keccak256("actual");

        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionHashMismatch.selector, expected, actual));
        this.throwExecutionHashMismatch(expected, actual);
    }

    function test_InsufficientLockup() public {
        uint64 required = TIMESTAMP_NOV_2023 + THIRTY_DAYS_MICROS; // Required: lockup until Dec 2023
        uint64 actual = TIMESTAMP_NOV_2023 + SEVEN_DAYS_MICROS; // Actual: only locked until Nov 7

        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientLockup.selector, required, actual));
        this.throwInsufficientLockup(required, actual);
    }

    function test_AtomicResolutionNotAllowed() public {
        vm.expectRevert(Errors.AtomicResolutionNotAllowed.selector);
        this.throwAtomicResolutionNotAllowed();
    }

    function test_InsufficientVotingPower() public {
        uint256 required = 1000 ether;
        uint256 actual = 500 ether;

        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientVotingPower.selector, required, actual));
        this.throwInsufficientVotingPower(required, actual);
    }

    // ========================================================================
    // TIMESTAMP ERRORS
    // ========================================================================

    function test_TimestampMustAdvance() public {
        uint64 proposed = TIMESTAMP_OCT_2023; // Same as current (didn't advance)
        uint64 current = TIMESTAMP_OCT_2023;

        vm.expectRevert(abi.encodeWithSelector(Errors.TimestampMustAdvance.selector, proposed, current));
        this.throwTimestampMustAdvance(proposed, current);
    }

    function test_TimestampMustEqual() public {
        uint64 proposed = TIMESTAMP_NOV_2023; // Different from current (should be equal for NIL block)
        uint64 current = TIMESTAMP_OCT_2023;

        vm.expectRevert(abi.encodeWithSelector(Errors.TimestampMustEqual.selector, proposed, current));
        this.throwTimestampMustEqual(proposed, current);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_NoStakePosition(
        address staker
    ) public {
        vm.expectRevert(abi.encodeWithSelector(Errors.NoStakePosition.selector, staker));
        this.throwNoStakePosition(staker);
    }

    function testFuzz_InsufficientStake(
        uint256 required,
        uint256 actual
    ) public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientStake.selector, required, actual));
        this.throwInsufficientStake(required, actual);
    }

    function testFuzz_ValidatorNotFound(
        address validator
    ) public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorNotFound.selector, validator));
        this.throwValidatorNotFound(validator);
    }

    // ========================================================================
    // ERROR SELECTOR TESTS
    // ========================================================================

    function test_ErrorSelectors() public pure {
        // Verify error selectors are computed correctly
        assertEq(Errors.NoStakePosition.selector, bytes4(keccak256("NoStakePosition(address)")));
        assertEq(Errors.InsufficientStake.selector, bytes4(keccak256("InsufficientStake(uint256,uint256)")));
        assertEq(Errors.LockupNotExpired.selector, bytes4(keccak256("LockupNotExpired(uint64,uint64)")));
        assertEq(Errors.ZeroAmount.selector, bytes4(keccak256("ZeroAmount()")));
        assertEq(Errors.ValidatorNotFound.selector, bytes4(keccak256("ValidatorNotFound(address)")));
        assertEq(Errors.ValidatorAlreadyExists.selector, bytes4(keccak256("ValidatorAlreadyExists(address)")));
        assertEq(Errors.InvalidStatus.selector, bytes4(keccak256("InvalidStatus(uint8,uint8)")));
        assertEq(Errors.InsufficientBond.selector, bytes4(keccak256("InsufficientBond(uint256,uint256)")));
        assertEq(Errors.NotOwner.selector, bytes4(keccak256("NotOwner(address,address)")));
        assertEq(Errors.NotOperator.selector, bytes4(keccak256("NotOperator(address,address)")));
    }

    // ========================================================================
    // HELPER FUNCTIONS (external throwers for testing)
    // ========================================================================

    // Staking errors
    function throwNoStakePosition(
        address staker
    ) external pure {
        revert Errors.NoStakePosition(staker);
    }

    function throwInsufficientStake(
        uint256 required,
        uint256 actual
    ) external pure {
        revert Errors.InsufficientStake(required, actual);
    }

    function throwLockupNotExpired(
        uint64 lockedUntil,
        uint64 currentTime
    ) external pure {
        revert Errors.LockupNotExpired(lockedUntil, currentTime);
    }

    function throwZeroAmount() external pure {
        revert Errors.ZeroAmount();
    }

    // Validator errors
    function throwValidatorNotFound(
        address validator
    ) external pure {
        revert Errors.ValidatorNotFound(validator);
    }

    function throwValidatorAlreadyExists(
        address validator
    ) external pure {
        revert Errors.ValidatorAlreadyExists(validator);
    }

    function throwInvalidStatus(
        uint8 expected,
        uint8 actual
    ) external pure {
        revert Errors.InvalidStatus(expected, actual);
    }

    function throwInsufficientBond(
        uint256 required,
        uint256 actual
    ) external pure {
        revert Errors.InsufficientBond(required, actual);
    }

    function throwExceedsMaximumBond(
        uint256 maximum,
        uint256 actual
    ) external pure {
        revert Errors.ExceedsMaximumBond(maximum, actual);
    }

    function throwNotOwner(
        address expected,
        address actual
    ) external pure {
        revert Errors.NotOwner(expected, actual);
    }

    function throwNotOperator(
        address expected,
        address actual
    ) external pure {
        revert Errors.NotOperator(expected, actual);
    }

    function throwValidatorSetChangesDisabled() external pure {
        revert Errors.ValidatorSetChangesDisabled();
    }

    function throwMaxValidatorSetSizeReached(
        uint256 maxSize
    ) external pure {
        revert Errors.MaxValidatorSetSizeReached(maxSize);
    }

    function throwVotingPowerIncreaseLimitExceeded(
        uint256 limit,
        uint256 actual
    ) external pure {
        revert Errors.VotingPowerIncreaseLimitExceeded(limit, actual);
    }

    function throwMonikerTooLong(
        uint256 maxLength,
        uint256 actualLength
    ) external pure {
        revert Errors.MonikerTooLong(maxLength, actualLength);
    }

    function throwUnbondNotReady(
        uint64 availableAt,
        uint64 currentTime
    ) external pure {
        revert Errors.UnbondNotReady(availableAt, currentTime);
    }

    // Reconfiguration errors
    function throwReconfigurationInProgress() external pure {
        revert Errors.ReconfigurationInProgress();
    }

    function throwReconfigurationNotInProgress() external pure {
        revert Errors.ReconfigurationNotInProgress();
    }

    function throwEpochNotYetEnded(
        uint64 nextEpochTime,
        uint64 currentTime
    ) external pure {
        revert Errors.EpochNotYetEnded(nextEpochTime, currentTime);
    }

    // Governance errors
    function throwProposalNotFound(
        uint64 proposalId
    ) external pure {
        revert Errors.ProposalNotFound(proposalId);
    }

    function throwVotingPeriodEnded(
        uint64 expirationTime
    ) external pure {
        revert Errors.VotingPeriodEnded(expirationTime);
    }

    function throwVotingPeriodNotEnded(
        uint64 expirationTime
    ) external pure {
        revert Errors.VotingPeriodNotEnded(expirationTime);
    }

    function throwProposalAlreadyResolved(
        uint64 proposalId
    ) external pure {
        revert Errors.ProposalAlreadyResolved(proposalId);
    }

    function throwExecutionHashMismatch(
        bytes32 expected,
        bytes32 actual
    ) external pure {
        revert Errors.ExecutionHashMismatch(expected, actual);
    }

    function throwInsufficientLockup(
        uint64 required,
        uint64 actual
    ) external pure {
        revert Errors.InsufficientLockup(required, actual);
    }

    function throwAtomicResolutionNotAllowed() external pure {
        revert Errors.AtomicResolutionNotAllowed();
    }

    function throwInsufficientVotingPower(
        uint256 required,
        uint256 actual
    ) external pure {
        revert Errors.InsufficientVotingPower(required, actual);
    }

    // Timestamp errors
    function throwTimestampMustAdvance(
        uint64 proposed,
        uint64 current
    ) external pure {
        revert Errors.TimestampMustAdvance(proposed, current);
    }

    function throwTimestampMustEqual(
        uint64 proposed,
        uint64 current
    ) external pure {
        revert Errors.TimestampMustEqual(proposed, current);
    }
}

