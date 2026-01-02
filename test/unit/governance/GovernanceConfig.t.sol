// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GovernanceConfig} from "src/governance/GovernanceConfig.sol";
import {SystemAddresses} from "src/foundation/SystemAddresses.sol";
import {Errors} from "src/foundation/Errors.sol";

/// @title GovernanceConfigTest
/// @notice Unit tests for GovernanceConfig contract
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
    // SETTER TESTS
    // ========================================================================

    function test_SetMinVotingThreshold() public {
        _initializeConfig();

        uint128 newThreshold = 2000 ether;

        vm.prank(SystemAddresses.TIMELOCK);
        config.setMinVotingThreshold(newThreshold);

        assertEq(config.minVotingThreshold(), newThreshold);
    }

    function test_RevertWhen_SetMinVotingThresholdNotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x5678);

        vm.prank(notTimelock);
        vm.expectRevert();
        config.setMinVotingThreshold(2000 ether);
    }

    function test_SetRequiredProposerStake() public {
        _initializeConfig();

        uint256 newStake = 200 ether;

        vm.prank(SystemAddresses.TIMELOCK);
        config.setRequiredProposerStake(newStake);

        assertEq(config.requiredProposerStake(), newStake);
    }

    function test_RevertWhen_SetRequiredProposerStakeNotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x5678);

        vm.prank(notTimelock);
        vm.expectRevert();
        config.setRequiredProposerStake(200 ether);
    }

    function test_SetVotingDurationMicros() public {
        _initializeConfig();

        uint64 newDuration = 14 days * 1_000_000;

        vm.prank(SystemAddresses.TIMELOCK);
        config.setVotingDurationMicros(newDuration);

        assertEq(config.votingDurationMicros(), newDuration);
    }

    function test_RevertWhen_SetVotingDurationMicrosNotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x5678);

        vm.prank(notTimelock);
        vm.expectRevert();
        config.setVotingDurationMicros(14 days * 1_000_000);
    }

    function test_RevertWhen_SetVotingDurationMicrosZero() public {
        _initializeConfig();

        vm.prank(SystemAddresses.TIMELOCK);
        vm.expectRevert(Errors.InvalidVotingDuration.selector);
        config.setVotingDurationMicros(0);
    }

    function test_SetEarlyResolutionThresholdBps() public {
        _initializeConfig();

        uint128 newThreshold = 6000; // 60%

        vm.prank(SystemAddresses.TIMELOCK);
        config.setEarlyResolutionThresholdBps(newThreshold);

        assertEq(config.earlyResolutionThresholdBps(), newThreshold);
    }

    function test_RevertWhen_SetEarlyResolutionThresholdBpsNotTimelock() public {
        _initializeConfig();

        address notTimelock = address(0x5678);

        vm.prank(notTimelock);
        vm.expectRevert();
        config.setEarlyResolutionThresholdBps(6000);
    }

    function test_RevertWhen_SetEarlyResolutionThresholdBpsTooHigh() public {
        _initializeConfig();

        vm.prank(SystemAddresses.TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEarlyResolutionThreshold.selector, uint128(10001)));
        config.setEarlyResolutionThresholdBps(10001);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_EmitConfigUpdatedOnSetMinVotingThreshold() public {
        _initializeConfig();

        uint128 newThreshold = 2000 ether;

        vm.prank(SystemAddresses.TIMELOCK);
        vm.expectEmit(true, false, false, true);
        emit GovernanceConfig.ConfigUpdated(keccak256("minVotingThreshold"), MIN_VOTING_THRESHOLD, newThreshold);
        config.setMinVotingThreshold(newThreshold);
    }

    function test_EmitConfigUpdatedOnSetRequiredProposerStake() public {
        _initializeConfig();

        uint256 newStake = 200 ether;

        vm.prank(SystemAddresses.TIMELOCK);
        vm.expectEmit(true, false, false, true);
        emit GovernanceConfig.ConfigUpdated(keccak256("requiredProposerStake"), REQUIRED_PROPOSER_STAKE, newStake);
        config.setRequiredProposerStake(newStake);
    }

    function test_EmitConfigUpdatedOnSetVotingDurationMicros() public {
        _initializeConfig();

        uint64 newDuration = 14 days * 1_000_000;

        vm.prank(SystemAddresses.TIMELOCK);
        vm.expectEmit(true, false, false, true);
        emit GovernanceConfig.ConfigUpdated(keccak256("votingDurationMicros"), VOTING_DURATION_MICROS, newDuration);
        config.setVotingDurationMicros(newDuration);
    }

    function test_EmitConfigUpdatedOnSetEarlyResolutionThresholdBps() public {
        _initializeConfig();

        uint128 newThreshold = 6000;

        vm.prank(SystemAddresses.TIMELOCK);
        vm.expectEmit(true, false, false, true);
        emit GovernanceConfig.ConfigUpdated(
            keccak256("earlyResolutionThresholdBps"), EARLY_RESOLUTION_THRESHOLD_BPS, newThreshold
        );
        config.setEarlyResolutionThresholdBps(newThreshold);
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

