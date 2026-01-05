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
    uint128 constant EARLY_RESOLUTION_THRESHOLD_BPS = 5000; // 50%

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
        assertEq(config.earlyResolutionThresholdBps(), 0);
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    function test_Initialize() public {
        // Call initialize as GENESIS
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(
            MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );

        // Verify values
        assertEq(config.minVotingThreshold(), MIN_VOTING_THRESHOLD);
        assertEq(config.requiredProposerStake(), REQUIRED_PROPOSER_STAKE);
        assertEq(config.votingDurationMicros(), VOTING_DURATION_MICROS);
        assertEq(config.earlyResolutionThresholdBps(), EARLY_RESOLUTION_THRESHOLD_BPS);
        assertTrue(config.isInitialized());
    }

    function test_RevertWhen_InitializeNotGenesis() public {
        address notGenesis = address(0x1234);

        vm.prank(notGenesis);
        vm.expectRevert();
        config.initialize(
            MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );
    }

    function test_RevertWhen_InitializeTwice() public {
        // First initialization
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(
            MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );

        // Second initialization should fail
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        config.initialize(
            MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );
    }

    function test_RevertWhen_InitializeZeroVotingDuration() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidVotingDuration.selector);
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, 0, EARLY_RESOLUTION_THRESHOLD_BPS);
    }

    function test_RevertWhen_InitializeInvalidEarlyResolutionThreshold() public {
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEarlyResolutionThreshold.selector, uint128(10001)));
        config.initialize(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, 10001);
    }

    // ========================================================================
    // SETTER TESTS - setForNextEpoch
    // ========================================================================

    function test_SetForNextEpoch() public {
        _initializeConfig();

        uint128 newMinThreshold = 2000 ether;
        uint256 newProposerStake = 200 ether;
        uint64 newVotingDuration = 14 days * 1_000_000;
        uint128 newEarlyThreshold = 6000;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newMinThreshold, newProposerStake, newVotingDuration, newEarlyThreshold);

        // Should not change current values, only set pending
        assertEq(config.minVotingThreshold(), MIN_VOTING_THRESHOLD);
        assertTrue(config.hasPendingConfig());

        (bool hasPending, GovernanceConfig.PendingConfig memory pendingConfig) = config.getPendingConfig();
        assertTrue(hasPending);
        assertEq(pendingConfig.minVotingThreshold, newMinThreshold);
        assertEq(pendingConfig.requiredProposerStake, newProposerStake);
        assertEq(pendingConfig.votingDurationMicros, newVotingDuration);
        assertEq(pendingConfig.earlyResolutionThresholdBps, newEarlyThreshold);
    }

    function test_RevertWhen_SetForNextEpoch_ZeroVotingDuration() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.InvalidVotingDuration.selector);
        config.setForNextEpoch(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, 0, EARLY_RESOLUTION_THRESHOLD_BPS);
    }

    function test_RevertWhen_SetForNextEpoch_InvalidEarlyThreshold() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEarlyResolutionThreshold.selector, uint128(10001)));
        config.setForNextEpoch(MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, 10001);
    }

    function test_RevertWhen_SetForNextEpoch_NotInitialized() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.GovernanceConfigNotInitialized.selector);
        config.setForNextEpoch(
            MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );
    }

    function test_RevertWhen_SetForNextEpoch_NotGovernance() public {
        _initializeConfig();

        address notGovernance = address(0x5678);
        vm.prank(notGovernance);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, notGovernance, SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(
            MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );
    }

    function test_Event_SetForNextEpoch() public {
        _initializeConfig();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(false, false, false, true);
        emit GovernanceConfig.PendingGovernanceConfigSet();
        config.setForNextEpoch(
            MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );
    }

    // ========================================================================
    // APPLY PENDING CONFIG TESTS
    // ========================================================================

    function test_ApplyPendingConfig() public {
        _initializeConfig();

        uint128 newMinThreshold = 2000 ether;
        uint256 newProposerStake = 200 ether;
        uint64 newVotingDuration = 14 days * 1_000_000;
        uint128 newEarlyThreshold = 6000;

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(newMinThreshold, newProposerStake, newVotingDuration, newEarlyThreshold);

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minVotingThreshold(), newMinThreshold);
        assertEq(config.requiredProposerStake(), newProposerStake);
        assertEq(config.votingDurationMicros(), newVotingDuration);
        assertEq(config.earlyResolutionThresholdBps(), newEarlyThreshold);
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
        config.setForNextEpoch(
            MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );

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
        config.setForNextEpoch(
            MIN_VOTING_THRESHOLD * 2, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, true);
        emit GovernanceConfig.GovernanceConfigUpdated();
        config.applyPendingConfig();
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_Initialize(
        uint128 minVotingThreshold,
        uint256 requiredProposerStake,
        uint64 votingDurationMicros,
        uint128 earlyResolutionThresholdBps
    ) public {
        vm.assume(votingDurationMicros > 0);
        vm.assume(earlyResolutionThresholdBps <= 10000);

        vm.prank(SystemAddresses.GENESIS);
        config.initialize(minVotingThreshold, requiredProposerStake, votingDurationMicros, earlyResolutionThresholdBps);

        assertEq(config.minVotingThreshold(), minVotingThreshold);
        assertEq(config.requiredProposerStake(), requiredProposerStake);
        assertEq(config.votingDurationMicros(), votingDurationMicros);
        assertEq(config.earlyResolutionThresholdBps(), earlyResolutionThresholdBps);
    }

    function testFuzz_SetForNextEpochAndApply(
        uint128 minVotingThreshold,
        uint256 requiredProposerStake,
        uint64 votingDurationMicros,
        uint128 earlyResolutionThresholdBps
    ) public {
        _initializeConfig();

        vm.assume(votingDurationMicros > 0);
        vm.assume(earlyResolutionThresholdBps <= 10000);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(
            minVotingThreshold, requiredProposerStake, votingDurationMicros, earlyResolutionThresholdBps
        );

        assertTrue(config.hasPendingConfig());

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();

        assertEq(config.minVotingThreshold(), minVotingThreshold);
        assertEq(config.requiredProposerStake(), requiredProposerStake);
        assertEq(config.votingDurationMicros(), votingDurationMicros);
        assertEq(config.earlyResolutionThresholdBps(), earlyResolutionThresholdBps);
        assertFalse(config.hasPendingConfig());
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _initializeConfig() internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(
            MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );
    }
}
