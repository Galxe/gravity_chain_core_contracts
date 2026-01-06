// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GovernanceConfig } from "src/runtime/GovernanceConfig.sol";
import { SystemAddresses } from "src/foundation/SystemAddresses.sol";
import { Errors } from "src/foundation/Errors.sol";
import { NotAllowed } from "src/foundation/SystemAccessControl.sol";

/// @title GovernanceConfigTest
/// @notice Unit tests for GovernanceConfig contract with pending pattern
contract GovernanceConfigTest is Test {
    GovernanceConfig public config;

    // Test values
    uint128 constant MIN_VOTING_THRESHOLD = 1000 ether;
    uint256 constant REQUIRED_PROPOSER_STAKE = 100 ether;
    uint64 constant VOTING_DURATION_MICROS = 7 days * 1_000_000; // 7 days in microseconds

    function setUp() public {
        // Deploy config at the expected system address
        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);
        config = GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);
    }

    // ========================================================================
    // INITIAL STATE TESTS
    // ========================================================================

    function test_InitialState() public view {
        assertEq(config.minVotingThreshold(), 0);
        assertEq(config.requiredProposerStake(), 0);
        assertEq(config.votingDurationMicros(), 0);
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public {
        // Call initialize as GENESIS
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);

        // Verify values
        assertEq(config.minVotingThreshold(), MIN_VOTING_THRESHOLD);
        assertEq(config.requiredProposerStake(), REQUIRED_PROPOSER_STAKE);
        assertEq(config.votingDurationMicros(), VOTING_DURATION_MICROS);
        assertTrue(config.isInitialized());
    }

    function test_RevertWhen_InitializeNotGenesis() public {
        address notGenesis = address(0x1234);

        vm.prank(notGenesis);
        vm.expectRevert();
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    function test_RevertWhen_InitializeTwice() public {
        // First initialization
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);

        // Second initialization should fail
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    function test_RevertWhen_InitializeZeroVotingDuration() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidVotingDuration.selector);
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, 0);
    }

    // ========================================================================
    // SETTER TESTS - setForNextEpoch
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeConfig();

        uint128 newMinThreshold = 2000 ether;
        uint256 newProposerStake = 200 ether;
        uint64 newVotingDuration = 14 days * 1_000_000;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newMinThreshold, newProposerStake, newVotingDuration);

        // Should not change current values, only set pending
        assertEq(config.minVotingThreshold(), MIN_VOTING_THRESHOLD);
        assertTrue(config.hasPendingConfig());

        (bool hasPending, GovernanceConfig.PendingConfig memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingConfig.minVotingThreshold, newMinThreshold);
        assertEq(pendingConfig.requiredProposerStake, newProposerStake);
        assertEq(pendingConfig.votingDurationMicros, newVotingDuration);
    }

    function test_RevertWhen_SetForNextEpoch_ZeroVotingDuration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidVotingDuration.selector);
        config.setForNextEpoch(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, 0);
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.GovernanceConfigNotInitialized.selector);
        config.setForNextEpoch(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    function test_RevertWhen_SetForNextEpoch_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x5678);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    function test_Event_SetForNextEpoch() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit GovernanceConfig.PendingGovernanceConfigSet();
        config.setForNextEpoch(MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeConfig();

        uint128 newMinThreshold = 2000 ether;
        uint256 newProposerStake = 200 ether;
        uint64 newVotingDuration = 14 days * 1_000_000;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newMinThreshold, newProposerStake, newVotingDuration);

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minVotingThreshold(), newMinThreshold);
        assertEq(config.requiredProposerStake(), newProposerStake);
        assertEq(config.votingDurationMicros(), newVotingDuration);
        assertFalse(config.hasPendingConfig());
    }

    function test_ApplyPendingConfig_NoPending() public {
        _initializeConfig();

        // Should be no-op when no pending config
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minVotingThreshold(), MIN_VOTING_THRESHOLD);
        assertFalse(config.hasPendingConfig());
    }

    function test_RevertWhen_ApplyPendingConfig_NotReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);

        address notReconfiguration = address(0x1234);
        vm.prank(notReconfiguration);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, notReconfiguration, SystemAddresses.RECONFIGURATION)
        );
        config.applyPendingConfig();
    }

    function test_Event_ApplyPendingConfig() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, true);
        emit GovernanceConfig.GovernanceConfigUpdated();
        config.applyPendingConfig();
    }

    // ========================================================================
    // GOVERNANCE-ONLY ACCESS CONTROL TESTS
    // ========================================================================

    function test_RevertWhen_SetterCalledByGenesis() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.GENESIS, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    function test_RevertWhen_SetterCalledBySystemCaller() public {
        _initializeConfig();

        vm.prank(SystemAddresses.SYSTEM_CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    function test_RevertWhen_SetterCalledByReconfiguration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectRevert(
            abi.encodeWithSelector(NotAllowed.selector, SystemAddresses.RECONFIGURATION, SystemAddresses.GOVERNANCE)
        );
        config.setForNextEpoch(MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Initialize(
        uint128 minVotingThreshold,
        uint256 requiredProposerStake,
        uint64 votingDurationMicros
    ) public {
        vm.assume(votingDurationMicros > 0);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(minVotingThreshold, requiredProposerStake, votingDurationMicros);

        assertEq(config.minVotingThreshold(), minVotingThreshold);
        assertEq(config.requiredProposerStake(), requiredProposerStake);
        assertEq(config.votingDurationMicros(), votingDurationMicros);
    }

    function testFuzz_SetForNextEpochAndApply(
        uint128 minVotingThreshold,
        uint256 requiredProposerStake,
        uint64 votingDurationMicros
    ) public {
        _initializeConfig();

        vm.assume(votingDurationMicros > 0);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(minVotingThreshold, requiredProposerStake, votingDurationMicros);

        assertTrue(config.hasPendingConfig());

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minVotingThreshold(), minVotingThreshold);
        assertEq(config.requiredProposerStake(), requiredProposerStake);
        assertEq(config.votingDurationMicros(), votingDurationMicros);
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS);
    }
}
