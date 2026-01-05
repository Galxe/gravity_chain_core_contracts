// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ValidatorManagement } from "../../../src/staking/ValidatorManagement.sol";
import { IValidatorManagement } from "../../../src/staking/IValidatorManagement.sol";
import { Staking } from "../../../src/staking/Staking.sol";
import { IStaking } from "../../../src/staking/IStaking.sol";
import { IStakePool } from "../../../src/staking/IStakePool.sol";
import { StakingConfig } from "../../../src/runtime/StakingConfig.sol";
import { ValidatorConfig } from "../../../src/runtime/ValidatorConfig.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { ValidatorRecord, ValidatorStatus, ValidatorConsensusInfo } from "../../../src/foundation/Types.sol";
import { IReconfiguration } from "../../../src/blocker/IReconfiguration.sol";

/// @notice Mock Reconfiguration contract for testing
contract MockReconfiguration {
    bool private _transitionInProgress;
    uint64 public currentEpoch;

    function isTransitionInProgress() external view returns (bool) {
        return _transitionInProgress;
    }

    function setTransitionInProgress(
        bool inProgress
    ) external {
        _transitionInProgress = inProgress;
    }

    /// @notice Increment epoch (simulates epoch transition)
    function incrementEpoch() external {
        currentEpoch++;
    }
}

/// @title ValidatorManagementTest
/// @notice Unit tests for ValidatorManagement contract
contract ValidatorManagementTest is Test {
    ValidatorManagement public validatorManager;
    Staking public staking;
    StakingConfig public stakingConfig;
    ValidatorConfig public validatorConfig;
    Timestamp public timestamp;
    MockReconfiguration public mockReconfiguration;

    // Test addresses
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");

    // Test constants
    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000; // 14 days in microseconds
    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000; // Initial time in microseconds

    // Validator constants
    uint256 constant MIN_BOND = 10 ether;
    uint256 constant MAX_BOND = 1000 ether;
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000; // 7 days in microseconds
    uint64 constant VOTING_POWER_INCREASE_LIMIT = 20; // 20%
    uint256 constant MAX_VALIDATOR_SET_SIZE = 100;

    // Sample consensus key data
    bytes constant CONSENSUS_PUBKEY = hex"1234567890abcdef";
    bytes constant CONSENSUS_POP = hex"abcdef1234567890";
    bytes constant NETWORK_ADDRESSES = hex"0102030405060708";
    bytes constant FULLNODE_ADDRESSES = hex"0807060504030201";

    function setUp() public {
        // Deploy contracts at system addresses
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        validatorConfig = ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);
        validatorManager = ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);

        // Deploy mock Reconfiguration at RECONFIGURATION address
        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfiguration()).code);
        mockReconfiguration = MockReconfiguration(SystemAddresses.RECONFIGURATION);

        // Initialize StakingConfig (with unbonding delay)
        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 10 ether);

        // Initialize ValidatorConfig
        vm.prank(SystemAddresses.GENESIS);
        validatorConfig.initialize(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE
        );

        // Set initial timestamp
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP);

        // Fund test accounts
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(charlie, 10000 ether);
        vm.deal(david, 10000 ether);
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    /// @notice Create a stake pool with given owner and stake amount
    function _createStakePool(
        address owner,
        uint256 stakeAmount
    ) internal returns (address pool) {
        uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION;
        vm.prank(owner);
        pool = staking.createPool{ value: stakeAmount }(owner, owner, owner, owner, lockedUntil);
    }

    /// @notice Create a stake pool and register as validator
    function _createAndRegisterValidator(
        address owner,
        uint256 stakeAmount,
        string memory moniker
    ) internal returns (address pool) {
        pool = _createStakePool(owner, stakeAmount);
        vm.prank(owner); // owner is also operator by default
        validatorManager.registerValidator(
            pool, moniker, CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    /// @notice Create, register, and join validator set
    function _createRegisterAndJoin(
        address owner,
        uint256 stakeAmount,
        string memory moniker
    ) internal returns (address pool) {
        pool = _createAndRegisterValidator(owner, stakeAmount, moniker);
        vm.prank(owner);
        validatorManager.joinValidatorSet(pool);
    }

    /// @notice Process an epoch transition
    function _processEpoch() internal {
        // onNewEpoch will query currentEpoch() + 1 for the event, so we need
        // to increment the mock epoch AFTER the call (simulates Reconfiguration behavior)
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorManager.onNewEpoch();
        mockReconfiguration.incrementEpoch();
    }

    // ========================================================================
    // REGISTRATION TESTS
    // ========================================================================

    function test_registerValidator_success() public {
        address pool = _createStakePool(alice, MIN_BOND);

        vm.prank(alice);
        validatorManager.registerValidator(
            pool, "alice-validator", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        assertTrue(validatorManager.isValidator(pool), "Should be a validator");

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(record.validator, pool, "Validator should match pool");
        assertEq(record.moniker, "alice-validator", "Moniker should match");
        assertEq(record.owner, alice, "Owner should be alice");
        assertEq(record.operator, alice, "Operator should be alice");
        assertEq(uint8(record.status), uint8(ValidatorStatus.INACTIVE), "Status should be INACTIVE");
        assertEq(record.bond, MIN_BOND, "Bond should match");
    }

    function test_registerValidator_emitsEvent() public {
        address pool = _createStakePool(alice, MIN_BOND);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ValidatorRegistered(pool, "alice-validator");
        validatorManager.registerValidator(
            pool, "alice-validator", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function test_RevertWhen_registerValidator_invalidPool() public {
        address fakePool = makeAddr("fakePool");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, fakePool));
        validatorManager.registerValidator(
            fakePool, "fake", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function test_RevertWhen_registerValidator_notOperator() public {
        address pool = _createStakePool(alice, MIN_BOND);

        vm.prank(bob); // Bob is not the operator
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOperator.selector, alice, bob));
        validatorManager.registerValidator(
            pool, "alice", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function test_RevertWhen_registerValidator_alreadyExists() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorAlreadyExists.selector, pool));
        validatorManager.registerValidator(
            pool, "alice", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function test_RevertWhen_registerValidator_insufficientBond() public {
        address pool = _createStakePool(alice, MIN_BOND - 1 ether); // Below minimum

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBond.selector, MIN_BOND, MIN_BOND - 1 ether));
        validatorManager.registerValidator(
            pool, "alice", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function test_RevertWhen_registerValidator_monikerTooLong() public {
        address pool = _createStakePool(alice, MIN_BOND);
        string memory longMoniker = "this-moniker-is-way-too-long-to-be-valid";

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.MonikerTooLong.selector, 31, bytes(longMoniker).length));
        validatorManager.registerValidator(
            pool, longMoniker, CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    // ========================================================================
    // JOIN VALIDATOR SET TESTS
    // ========================================================================

    function test_joinValidatorSet_success() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        vm.prank(alice);
        validatorManager.joinValidatorSet(pool);

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(uint8(record.status), uint8(ValidatorStatus.PENDING_ACTIVE), "Status should be PENDING_ACTIVE");

        address[] memory pending = validatorManager.getPendingActiveValidators();
        assertEq(pending.length, 1, "Should have one pending validator");
        assertEq(pending[0], pool, "Pending validator should match");
    }

    function test_joinValidatorSet_emitsEvent() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit IValidatorManagement.ValidatorJoinRequested(pool);
        validatorManager.joinValidatorSet(pool);
    }

    function test_RevertWhen_joinValidatorSet_notInactive() public {
        address pool = _createRegisterAndJoin(alice, MIN_BOND, "alice");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector, uint8(ValidatorStatus.INACTIVE), uint8(ValidatorStatus.PENDING_ACTIVE)
            )
        );
        validatorManager.joinValidatorSet(pool);
    }

    function test_RevertWhen_joinValidatorSet_validatorNotFound() public {
        address fakePool = makeAddr("fakePool");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorNotFound.selector, fakePool));
        validatorManager.joinValidatorSet(fakePool);
    }

    function test_RevertWhen_joinValidatorSet_notOperator() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOperator.selector, alice, bob));
        validatorManager.joinValidatorSet(pool);
    }

    function test_RevertWhen_joinValidatorSet_setChangesDisabled() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        // Disable validator set changes via pending pattern
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, false, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE
        );
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        vm.prank(alice);
        vm.expectRevert(Errors.ValidatorSetChangesDisabled.selector);
        validatorManager.joinValidatorSet(pool);
    }

    // ========================================================================
    // LEAVE VALIDATOR SET TESTS
    // ========================================================================

    function test_leaveValidatorSet_success() public {
        // Need at least 2 validators since last validator cannot leave
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch(); // Activate both validators

        ValidatorRecord memory before = validatorManager.getValidator(pool1);
        assertEq(uint8(before.status), uint8(ValidatorStatus.ACTIVE), "Should be ACTIVE");

        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        ValidatorRecord memory after_ = validatorManager.getValidator(pool1);
        assertEq(uint8(after_.status), uint8(ValidatorStatus.PENDING_INACTIVE), "Should be PENDING_INACTIVE");

        address[] memory pending = validatorManager.getPendingInactiveValidators();
        assertEq(pending.length, 1, "Should have one pending inactive");
        assertEq(pending[0], pool1, "Pending should match");
    }

    function test_leaveValidatorSet_emitsEvent() public {
        // Need at least 2 validators since last validator cannot leave
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit IValidatorManagement.ValidatorLeaveRequested(pool1);
        validatorManager.leaveValidatorSet(pool1);
    }

    function test_RevertWhen_leaveValidatorSet_notActive() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector, uint8(ValidatorStatus.ACTIVE), uint8(ValidatorStatus.INACTIVE)
            )
        );
        validatorManager.leaveValidatorSet(pool);
    }

    // ========================================================================
    // EPOCH PROCESSING TESTS
    // ========================================================================

    function test_onNewEpoch_activatesPendingValidator() public {
        address pool = _createRegisterAndJoin(alice, MIN_BOND, "alice");

        assertEq(validatorManager.getActiveValidatorCount(), 0, "No active validators before epoch");

        _processEpoch();

        assertEq(validatorManager.getActiveValidatorCount(), 1, "Should have one active validator");
        assertEq(validatorManager.getCurrentEpoch(), 1, "Epoch should be 1");

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(uint8(record.status), uint8(ValidatorStatus.ACTIVE), "Status should be ACTIVE");
        assertEq(record.validatorIndex, 0, "Index should be 0");
    }

    function test_onNewEpoch_deactivatesPendingInactive() public {
        // Need at least 2 validators since last validator cannot leave
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch(); // Activate both

        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        _processEpoch(); // Deactivate pool1

        assertEq(validatorManager.getActiveValidatorCount(), 1, "One active validator remaining");

        ValidatorRecord memory record = validatorManager.getValidator(pool1);
        assertEq(uint8(record.status), uint8(ValidatorStatus.INACTIVE), "Status should be INACTIVE");

        // Verify bob is still active
        ValidatorRecord memory bobRecord = validatorManager.getValidator(pool2);
        assertEq(uint8(bobRecord.status), uint8(ValidatorStatus.ACTIVE), "Bob should still be ACTIVE");
    }

    function test_onNewEpoch_assignsIndicesCorrectly() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        address pool3 = _createRegisterAndJoin(charlie, MIN_BOND, "charlie");

        _processEpoch();

        assertEq(validatorManager.getActiveValidatorCount(), 3, "Should have 3 validators");

        // Verify indices are 0, 1, 2
        ValidatorConsensusInfo[] memory validators = validatorManager.getActiveValidators();
        for (uint64 i = 0; i < validators.length; i++) {
            ValidatorRecord memory record = validatorManager.getValidator(validators[i].validator);
            assertEq(record.validatorIndex, i, "Index should match position");
        }
    }

    function test_onNewEpoch_reassignsIndicesAfterLeave() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        address pool3 = _createRegisterAndJoin(charlie, MIN_BOND, "charlie");

        _processEpoch(); // All active with indices 0, 1, 2

        // Bob leaves
        vm.prank(bob);
        validatorManager.leaveValidatorSet(pool2);

        _processEpoch(); // Bob removed, indices reassigned

        assertEq(validatorManager.getActiveValidatorCount(), 2, "Should have 2 validators");

        // Verify indices are still 0, 1 (contiguous)
        ValidatorConsensusInfo[] memory validators = validatorManager.getActiveValidators();
        for (uint64 i = 0; i < validators.length; i++) {
            ValidatorRecord memory record = validatorManager.getValidator(validators[i].validator);
            assertEq(record.validatorIndex, i, "Index should be contiguous");
        }
    }

    function test_onNewEpoch_updatesTotalVotingPower() public {
        _createRegisterAndJoin(alice, 20 ether, "alice");
        _createRegisterAndJoin(bob, 30 ether, "bob");

        _processEpoch();

        assertEq(validatorManager.getTotalVotingPower(), 50 ether, "Total voting power should be 50 ether");
    }

    function test_onNewEpoch_capsVotingPowerAtMaxBond() public {
        _createRegisterAndJoin(alice, MAX_BOND + 100 ether, "alice"); // Above max

        _processEpoch();

        // Total voting power should be capped at MAX_BOND
        assertEq(validatorManager.getTotalVotingPower(), MAX_BOND, "Voting power should be capped");
    }

    function test_onNewEpoch_emitsEpochProcessedEvent() public {
        _createRegisterAndJoin(alice, MIN_BOND, "alice");

        vm.prank(SystemAddresses.RECONFIGURATION);
        vm.expectEmit(false, false, false, true);
        emit IValidatorManagement.EpochProcessed(1, 1, MIN_BOND);
        validatorManager.onNewEpoch();
    }

    function test_RevertWhen_onNewEpoch_notReconfiguration() public {
        vm.prank(alice);
        vm.expectRevert();
        validatorManager.onNewEpoch();
    }

    // ========================================================================
    // VOTING POWER LIMIT TESTS
    // ========================================================================

    function test_onNewEpoch_respectsVotingPowerLimit() public {
        // Set up a validator with 100 ether (will become the base)
        address pool1 = _createRegisterAndJoin(alice, 100 ether, "alice");
        _processEpoch();

        // Try to add a validator with 30 ether (30% increase, limit is 20%)
        address pool2 = _createRegisterAndJoin(bob, 30 ether, "bob");
        _processEpoch();

        // Bob should still be pending because 30 > 20% of 100
        assertEq(validatorManager.getActiveValidatorCount(), 1, "Only alice should be active");

        ValidatorRecord memory bobRecord = validatorManager.getValidator(pool2);
        assertEq(uint8(bobRecord.status), uint8(ValidatorStatus.PENDING_ACTIVE), "Bob should still be pending");
    }

    function test_onNewEpoch_activatesWithinLimit() public {
        // Set up a validator with 100 ether
        address pool1 = _createRegisterAndJoin(alice, 100 ether, "alice");
        _processEpoch();

        // Add a validator with 15 ether (15% increase, within 20% limit)
        address pool2 = _createRegisterAndJoin(bob, 15 ether, "bob");
        _processEpoch();

        // Bob should be activated
        assertEq(validatorManager.getActiveValidatorCount(), 2, "Both should be active");

        ValidatorRecord memory bobRecord = validatorManager.getValidator(pool2);
        assertEq(uint8(bobRecord.status), uint8(ValidatorStatus.ACTIVE), "Bob should be active");
    }

    // ========================================================================
    // OPERATOR FUNCTION TESTS
    // ========================================================================

    function test_rotateConsensusKey_success() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");
        bytes memory newPubkey = hex"deadbeef";
        bytes memory newPop = hex"cafebabe";

        vm.prank(alice);
        validatorManager.rotateConsensusKey(pool, newPubkey, newPop);

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(record.consensusPubkey, newPubkey, "Pubkey should be updated");
        assertEq(record.consensusPop, newPop, "PoP should be updated");
    }

    function test_rotateConsensusKey_emitsEvent() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");
        bytes memory newPubkey = hex"deadbeef";

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ConsensusKeyRotated(pool, newPubkey);
        validatorManager.rotateConsensusKey(pool, newPubkey, hex"");
    }

    function test_setFeeRecipient_success() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");
        address newRecipient = makeAddr("recipient");

        vm.prank(alice);
        validatorManager.setFeeRecipient(pool, newRecipient);

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(record.pendingFeeRecipient, newRecipient, "Pending recipient should be set");
        assertEq(record.feeRecipient, alice, "Current recipient unchanged until epoch");
    }

    function test_setFeeRecipient_appliedAtEpoch() public {
        address pool = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch(); // Activate

        address newRecipient = makeAddr("recipient");
        vm.prank(alice);
        validatorManager.setFeeRecipient(pool, newRecipient);

        _processEpoch(); // Apply change

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(record.feeRecipient, newRecipient, "Fee recipient should be updated");
        assertEq(record.pendingFeeRecipient, address(0), "Pending should be cleared");
    }

    // ========================================================================
    // VIEW FUNCTION TESTS
    // ========================================================================

    function test_getActiveValidatorByIndex_success() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, 20 ether, "bob");
        _processEpoch();

        ValidatorConsensusInfo memory info0 = validatorManager.getActiveValidatorByIndex(0);
        ValidatorConsensusInfo memory info1 = validatorManager.getActiveValidatorByIndex(1);

        // One of them should be pool1, one pool2
        assertTrue(info0.validator == pool1 || info0.validator == pool2, "Index 0 should be valid");
        assertTrue(info1.validator == pool1 || info1.validator == pool2, "Index 1 should be valid");
        assertTrue(info0.validator != info1.validator, "Different validators at different indices");
    }

    function test_RevertWhen_getActiveValidatorByIndex_outOfBounds() public {
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch();

        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorIndexOutOfBounds.selector, 1, 1));
        validatorManager.getActiveValidatorByIndex(1);
    }

    function test_getValidatorStatus_allStatuses() public {
        address pool = _createStakePool(alice, MIN_BOND);

        // Not registered - should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorNotFound.selector, pool));
        validatorManager.getValidatorStatus(pool);

        // Register - INACTIVE
        vm.prank(alice);
        validatorManager.registerValidator(
            pool, "alice", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.INACTIVE));

        // Join - PENDING_ACTIVE
        vm.prank(alice);
        validatorManager.joinValidatorSet(pool);
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.PENDING_ACTIVE));

        // Need another validator so alice can leave (last validator cannot leave)
        _createRegisterAndJoin(bob, MIN_BOND, "bob");

        // Epoch - ACTIVE (both alice and bob become active)
        _processEpoch();
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.ACTIVE));

        // Leave - PENDING_INACTIVE
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool);
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.PENDING_INACTIVE));

        // Epoch - INACTIVE
        _processEpoch();
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.INACTIVE));
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_registerValidator_variousBondAmounts(
        uint256 bondAmount
    ) public {
        bondAmount = bound(bondAmount, MIN_BOND, MAX_BOND);

        address pool = _createStakePool(alice, bondAmount);
        vm.prank(alice);
        validatorManager.registerValidator(
            pool, "alice", CONSENSUS_PUBKEY, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(record.bond, bondAmount, "Bond should match");
    }

    function testFuzz_multipleValidators(
        uint8 numValidators
    ) public {
        numValidators = uint8(bound(numValidators, 1, 10)); // Keep small to avoid gas issues

        for (uint256 i = 0; i < numValidators; i++) {
            address user = address(uint160(0x1000 + i));
            vm.deal(user, 1000 ether);
            _createRegisterAndJoin(user, MIN_BOND + i * 1 ether, "validator");
        }

        _processEpoch();

        // All validators should be active
        assertEq(validatorManager.getActiveValidatorCount(), numValidators, "All validators should be active");

        // Check indices are contiguous
        for (uint64 i = 0; i < numValidators; i++) {
            ValidatorConsensusInfo memory info = validatorManager.getActiveValidatorByIndex(i);
            ValidatorRecord memory record = validatorManager.getValidator(info.validator);
            assertEq(record.validatorIndex, i, "Index should be contiguous");
        }
    }

    // ========================================================================
    // INVARIANT TESTS
    // ========================================================================

    function test_invariant_indicesAreContiguous() public {
        // Create several validators
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _createRegisterAndJoin(charlie, MIN_BOND, "charlie");
        _processEpoch();

        // Have one leave
        address pool2 = staking.getPool(1); // Bob's pool
        vm.prank(bob);
        validatorManager.leaveValidatorSet(pool2);
        _processEpoch();

        // Add a new one
        _createRegisterAndJoin(david, MIN_BOND, "david");
        _processEpoch();

        // Verify indices are 0, 1, 2 (contiguous)
        uint256 count = validatorManager.getActiveValidatorCount();
        for (uint64 i = 0; i < count; i++) {
            ValidatorConsensusInfo memory info = validatorManager.getActiveValidatorByIndex(i);
            ValidatorRecord memory record = validatorManager.getValidator(info.validator);
            assertEq(record.validatorIndex, i, "Index should match position");
        }
    }

    function test_invariant_totalVotingPowerMatchesSum() public {
        _createRegisterAndJoin(alice, 10 ether, "alice");
        _createRegisterAndJoin(bob, 20 ether, "bob");
        _createRegisterAndJoin(charlie, 30 ether, "charlie");
        _processEpoch();

        uint256 total = validatorManager.getTotalVotingPower();
        uint256 sum = 0;

        ValidatorConsensusInfo[] memory validators = validatorManager.getActiveValidators();
        for (uint256 i = 0; i < validators.length; i++) {
            sum += validators[i].votingPower;
        }

        assertEq(total, sum, "Total should match sum of individual powers");
    }

    function test_invariant_onlyActiveHasValidIndex() public {
        address pool = _createRegisterAndJoin(alice, MIN_BOND, "alice");

        // PENDING_ACTIVE - no valid index yet
        ValidatorRecord memory pendingRecord = validatorManager.getValidator(pool);
        assertEq(uint8(pendingRecord.status), uint8(ValidatorStatus.PENDING_ACTIVE));
        // Index is 0 by default, but that's not "invalid" - it's just not assigned yet

        // Need another validator so alice can leave (last validator cannot leave)
        _createRegisterAndJoin(bob, MIN_BOND, "bob");

        _processEpoch();

        // ACTIVE - has valid index
        ValidatorRecord memory activeRecord = validatorManager.getValidator(pool);
        assertEq(uint8(activeRecord.status), uint8(ValidatorStatus.ACTIVE));
        // Index could be 0 or 1 depending on order, just verify it's assigned
        assertTrue(activeRecord.validatorIndex < 2, "Should have valid index");

        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool);

        // PENDING_INACTIVE - keeps index for current epoch
        ValidatorRecord memory pendingInactiveRecord = validatorManager.getValidator(pool);
        assertEq(uint8(pendingInactiveRecord.status), uint8(ValidatorStatus.PENDING_INACTIVE));

        _processEpoch();

        // INACTIVE - index cleared (uses type(uint64).max as sentinel)
        ValidatorRecord memory inactiveRecord = validatorManager.getValidator(pool);
        assertEq(uint8(inactiveRecord.status), uint8(ValidatorStatus.INACTIVE));
        assertEq(inactiveRecord.validatorIndex, type(uint64).max, "Index should be cleared to max uint64");
    }

    // ========================================================================
    // SECURITY TESTS (Aptos parity)
    // ========================================================================

    /// @notice Test that the last active validator cannot leave (would halt consensus)
    function test_RevertWhen_leaveValidatorSet_lastValidator() public {
        address pool = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch(); // Activate

        assertEq(validatorManager.getActiveValidatorCount(), 1, "Should have exactly 1 validator");

        vm.prank(alice);
        vm.expectRevert(Errors.CannotRemoveLastValidator.selector);
        validatorManager.leaveValidatorSet(pool);
    }

    /// @notice Test that a validator can cancel their join request by leaving from PENDING_ACTIVE
    function test_leaveValidatorSet_fromPendingActive() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        // Join - becomes PENDING_ACTIVE
        vm.prank(alice);
        validatorManager.joinValidatorSet(pool);
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.PENDING_ACTIVE));

        // Leave from PENDING_ACTIVE - should revert to INACTIVE
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool);

        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.INACTIVE));
        assertEq(validatorManager.getPendingActiveValidators().length, 0, "Should have no pending active validators");
    }

    /// @notice Test that operations are blocked during reconfiguration
    function test_RevertWhen_joinValidatorSet_duringReconfiguration() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        validatorManager.joinValidatorSet(pool);
    }

    /// @notice Test that leaveValidatorSet is blocked during reconfiguration
    function test_RevertWhen_leaveValidatorSet_duringReconfiguration() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        validatorManager.leaveValidatorSet(pool1);
    }

    /// @notice Test that rotateConsensusKey is blocked during reconfiguration
    function test_RevertWhen_rotateConsensusKey_duringReconfiguration() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        validatorManager.rotateConsensusKey(pool, hex"abcd1234", hex"5678efab");
    }

    /// @notice Test that setFeeRecipient is blocked during reconfiguration
    function test_RevertWhen_setFeeRecipient_duringReconfiguration() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        validatorManager.setFeeRecipient(pool, bob);
    }

    /// @notice Test that leaveValidatorSet is blocked when allowValidatorSetChange is false
    function test_RevertWhen_leaveValidatorSet_setChangesDisabled() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Disable validator set changes via pending pattern
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, false, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE
        );
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        vm.prank(alice);
        vm.expectRevert(Errors.ValidatorSetChangesDisabled.selector);
        validatorManager.leaveValidatorSet(pool1);
    }

    // ========================================================================
    // STAKE WITHDRAWAL PROTECTION TESTS (Bucket-Based)
    // ========================================================================

    /// @notice Test that active validators can unstake but must maintain minimum bond
    /// @dev With bucket-based withdrawals, validators can unstake but effective stake must stay >= minBond
    function test_RevertWhen_unstake_wouldBreachMinBond() public {
        // Create validator with exact minimum bond
        address pool = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch();

        // Verify validator is active
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.ACTIVE));

        // Attempting to unstake any amount should fail (would breach min bond)
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.WithdrawalWouldBreachMinimumBond.selector, MIN_BOND - 1, MIN_BOND)
        );
        IStakePool(pool).unstake(1);
    }

    /// @notice Test that active validators can unstake excess above minimum bond
    function test_unstake_activeValidator_excessStake() public {
        // Create validator with extra stake above minimum bond
        uint256 stakeAmount = MIN_BOND * 2; // 20 ether
        address pool = _createRegisterAndJoin(alice, stakeAmount, "alice");
        _processEpoch();

        // Verify validator is active
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.ACTIVE));

        // Can unstake excess stake (keeping >= minBond)
        uint256 excessAmount = stakeAmount - MIN_BOND; // 10 ether
        vm.prank(alice);
        IStakePool(pool).unstake(excessAmount);

        // Verify unstake is in pending bucket
        assertEq(IStakePool(pool).getTotalPending(), excessAmount);

        // Advance time past lockup + unbonding delay
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP + LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Withdraw available
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool).withdrawAvailable(alice);

        assertEq(alice.balance, balanceBefore + excessAmount);
    }

    /// @notice Test that PENDING_INACTIVE validators can unstake
    function test_unstake_pendingInactiveValidator() public {
        // Setup: two validators so one can leave
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND * 2, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Alice requests to leave - becomes PENDING_INACTIVE
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);
        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.PENDING_INACTIVE));

        // PENDING_INACTIVE can unstake excess (must still maintain min bond)
        uint256 excessAmount = MIN_BOND; // Can withdraw half
        vm.prank(alice);
        IStakePool(pool1).unstake(excessAmount);

        // Advance time past lockup + unbonding delay
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP + LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Withdraw available
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool1).withdrawAvailable(alice);

        assertEq(alice.balance, balanceBefore + excessAmount);
    }

    /// @notice Test that validators can withdraw all stake after leaving and epoch processes
    /// @dev Complete flow: ACTIVE -> PENDING_INACTIVE -> INACTIVE -> unstake -> withdraw
    function test_unstake_afterLeavingValidatorSet() public {
        // Setup: two validators so one can leave
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Alice requests to leave
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        // Process epoch - Alice becomes INACTIVE
        _processEpoch();
        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.INACTIVE));

        // INACTIVE validators can unstake full amount
        vm.prank(alice);
        IStakePool(pool1).unstake(MIN_BOND);

        // Advance time past lockup + unbonding delay
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP + LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Withdraw available
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool1).withdrawAvailable(alice);

        assertEq(alice.balance, balanceBefore + MIN_BOND, "Alice should receive withdrawn stake");
        assertEq(IStakePool(pool1).getActiveStake(), 0, "Pool active stake should be zero");
    }

    /// @notice Test that non-validator pools (registered but INACTIVE) can withdraw
    function test_unstake_inactiveValidator() public {
        // Create and register validator but don't join the active set
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        // Verify validator is INACTIVE (registered but not in active set)
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.INACTIVE));

        // INACTIVE validators can unstake full amount
        vm.prank(alice);
        IStakePool(pool).unstake(MIN_BOND);

        // Advance time past lockup + unbonding delay
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP + LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Withdraw available
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool).withdrawAvailable(alice);

        assertEq(alice.balance, balanceBefore + MIN_BOND, "Alice should receive withdrawn stake");
    }

    /// @notice Test that non-validator pools (not registered) can unstake and withdraw
    function test_unstake_nonValidatorPool() public {
        // Create a stake pool but don't register as validator
        address pool = _createStakePool(alice, MIN_BOND);

        // Pool is not a validator
        assertFalse(validatorManager.isValidator(pool), "Pool should not be a validator");

        // Unstake
        vm.prank(alice);
        IStakePool(pool).unstake(MIN_BOND);

        // Advance time past lockup + unbonding delay
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP + LOCKUP_DURATION + UNBONDING_DELAY + 1);

        // Non-validator pools can withdraw
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        IStakePool(pool).withdrawAvailable(alice);

        assertEq(alice.balance, balanceBefore + MIN_BOND, "Alice should receive withdrawn stake");
    }

    /// @notice Test that isValidator returns false for unregistered pools
    function test_isValidator_returnsFalseForUnregisteredPool() public {
        // Create a stake pool but don't register as validator
        address pool = _createStakePool(alice, MIN_BOND);

        // isValidator should return false
        assertFalse(validatorManager.isValidator(pool), "Unregistered pool should not be a validator");
    }

    /// @notice Test that getValidatorStatus reverts for unregistered pools
    function test_RevertWhen_getValidatorStatus_unregisteredPool() public {
        // Create a stake pool but don't register as validator
        address pool = _createStakePool(alice, MIN_BOND);

        // getValidatorStatus should revert with ValidatorNotFound
        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorNotFound.selector, pool));
        validatorManager.getValidatorStatus(pool);
    }

    // ========================================================================
    // DKG SUPPORT FUNCTION TESTS
    // ========================================================================

    /// @notice Test getCurValidatorConsensusInfos returns active validators only when no pending_inactive
    function test_getCurValidatorConsensusInfos_activeOnly() public {
        _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, 20 ether, "bob");
        _processEpoch();

        ValidatorConsensusInfo[] memory cur = validatorManager.getCurValidatorConsensusInfos();

        assertEq(cur.length, 2, "Should return 2 current validators");
        // Verify both validators are present
        bool foundAlice = false;
        bool foundBob = false;
        for (uint256 i = 0; i < cur.length; i++) {
            if (cur[i].votingPower == MIN_BOND) foundAlice = true;
            if (cur[i].votingPower == 20 ether) foundBob = true;
        }
        assertTrue(foundAlice && foundBob, "Should include both validators");
    }

    /// @notice Test getCurValidatorConsensusInfos includes pending_inactive validators
    /// @dev Pending_inactive validators remain in _activeValidators until epoch boundary,
    ///      so they are automatically included in getCurValidatorConsensusInfos
    function test_getCurValidatorConsensusInfos_includesPendingInactive() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, 20 ether, "bob");
        address pool3 = _createRegisterAndJoin(charlie, 30 ether, "charlie");
        _processEpoch();

        // Alice requests to leave - becomes PENDING_INACTIVE
        // She's still in _activeValidators until the next epoch boundary
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        // Verify alice is now PENDING_INACTIVE
        assertEq(
            uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.PENDING_INACTIVE), "Alice pending"
        );

        ValidatorConsensusInfo[] memory cur = validatorManager.getCurValidatorConsensusInfos();

        // Should still include alice (pending_inactive) for DKG dealers
        // _activeValidators contains all 3 until epoch boundary processes them
        assertEq(cur.length, 3, "Should include all 3 validators including pending_inactive");

        // Verify alice is in the results
        bool aliceFound = false;
        for (uint256 i = 0; i < cur.length; i++) {
            if (cur[i].validator == pool1) {
                aliceFound = true;
                break;
            }
        }
        assertTrue(aliceFound, "Alice (pending_inactive) should be in cur validators");
    }

    /// @notice Test getNextValidatorConsensusInfos excludes pending_inactive
    function test_getNextValidatorConsensusInfos_excludesPendingInactive() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, 20 ether, "bob");
        address pool3 = _createRegisterAndJoin(charlie, 30 ether, "charlie");
        _processEpoch();

        // Alice requests to leave - becomes PENDING_INACTIVE
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        ValidatorConsensusInfo[] memory next = validatorManager.getNextValidatorConsensusInfos();

        // Should exclude alice (pending_inactive), only bob and charlie
        assertEq(next.length, 2, "Should return 2 validators excluding pending_inactive");

        // Verify indices are fresh (0, 1)
        for (uint256 i = 0; i < next.length; i++) {
            assertTrue(next[i].validator == pool2 || next[i].validator == pool3, "Should be bob or charlie");
        }
    }

    /// @notice Test getNextValidatorConsensusInfos includes pending_active that meet min stake
    function test_getNextValidatorConsensusInfos_includesPendingActive() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch();

        // Bob joins - becomes PENDING_ACTIVE
        address pool2 = _createAndRegisterValidator(bob, 20 ether, "bob");
        vm.prank(bob);
        validatorManager.joinValidatorSet(pool2);

        ValidatorConsensusInfo[] memory next = validatorManager.getNextValidatorConsensusInfos();

        // Should include both alice (active) and bob (pending_active)
        assertEq(next.length, 2, "Should include active and pending_active validators");
    }

    /// @notice Test getNextValidatorConsensusInfos assigns fresh indices (0, 1, 2, ...)
    function test_getNextValidatorConsensusInfos_freshIndices() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, 20 ether, "bob");
        address pool3 = _createRegisterAndJoin(charlie, 30 ether, "charlie");
        _processEpoch();

        // Validator bob leaves (becomes pending_inactive)
        vm.prank(bob);
        validatorManager.leaveValidatorSet(pool2);

        // New validator david joins (becomes pending_active)
        address pool4 = _createAndRegisterValidator(david, 40 ether, "david");
        vm.prank(david);
        validatorManager.joinValidatorSet(pool4);

        ValidatorConsensusInfo[] memory next = validatorManager.getNextValidatorConsensusInfos();

        // Should have alice, charlie, david (3 validators)
        // Indices should be 0, 1, 2 (position in array)
        assertEq(next.length, 3, "Should have 3 validators in next set");

        // Verify no duplicates and all expected validators present
        address[3] memory expected = [pool1, pool3, pool4]; // alice, charlie, david
        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < next.length; j++) {
                if (next[j].validator == expected[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Expected validator should be in next set");
        }
    }

    /// @notice Test getCurValidatorConsensusInfos returns empty when no validators
    function test_getCurValidatorConsensusInfos_emptyWhenNoValidators() public view {
        ValidatorConsensusInfo[] memory cur = validatorManager.getCurValidatorConsensusInfos();
        assertEq(cur.length, 0, "Should return empty array when no validators");
    }

    /// @notice Test getNextValidatorConsensusInfos returns empty when no projected validators
    function test_getNextValidatorConsensusInfos_emptyWhenNoProjectedValidators() public view {
        ValidatorConsensusInfo[] memory next = validatorManager.getNextValidatorConsensusInfos();
        assertEq(next.length, 0, "Should return empty array when no projected validators");
    }

    /// @notice Test that cur and next can differ when validators are joining/leaving
    /// @dev Cur returns _activeValidators (which includes pending_inactive until epoch boundary)
    ///      Next returns (active - pending_inactive) + pending_active
    function test_curAndNextValidatorsDiffer() public {
        // Start with 3 validators
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, 20 ether, "bob");
        address pool3 = _createRegisterAndJoin(charlie, 30 ether, "charlie");
        _processEpoch();

        // Bob leaves (pending_inactive) - still in _activeValidators until epoch boundary
        vm.prank(bob);
        validatorManager.leaveValidatorSet(pool2);

        // David joins (pending_active)
        address pool4 = _createAndRegisterValidator(david, 40 ether, "david");
        vm.prank(david);
        validatorManager.joinValidatorSet(pool4);

        ValidatorConsensusInfo[] memory cur = validatorManager.getCurValidatorConsensusInfos();
        ValidatorConsensusInfo[] memory next = validatorManager.getNextValidatorConsensusInfos();

        // Cur: alice, bob (pending_inactive still in _activeValidators), charlie = 3
        assertEq(cur.length, 3, "Cur should have 3 validators (pending_inactive still in _activeValidators)");

        // Next: alice, charlie, david (pending_active) = 3 (bob excluded)
        assertEq(next.length, 3, "Next should have 3 validators");

        // Verify bob is in cur but not in next
        bool bobInCur = false;
        bool bobInNext = false;
        for (uint256 i = 0; i < cur.length; i++) {
            if (cur[i].validator == pool2) bobInCur = true;
        }
        for (uint256 i = 0; i < next.length; i++) {
            if (next[i].validator == pool2) bobInNext = true;
        }
        assertTrue(bobInCur, "Bob should be in cur (pending_inactive still in _activeValidators)");
        assertFalse(bobInNext, "Bob should NOT be in next (leaving)");

        // Verify david is in next but not in cur
        bool davidInCur = false;
        bool davidInNext = false;
        for (uint256 i = 0; i < cur.length; i++) {
            if (cur[i].validator == pool4) davidInCur = true;
        }
        for (uint256 i = 0; i < next.length; i++) {
            if (next[i].validator == pool4) davidInNext = true;
        }
        assertFalse(davidInCur, "David should NOT be in cur (not active yet)");
        assertTrue(davidInNext, "David should be in next (pending_active)");
    }

    // ========================================================================
    // STAKING FREEZE DURING RECONFIGURATION TESTS
    // ========================================================================

    /// @notice Test that addStake is blocked during reconfiguration
    function test_RevertWhen_addStake_duringReconfiguration() public {
        address pool = _createStakePool(alice, MIN_BOND);

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool).addStake{ value: 1 ether }();
    }

    /// @notice Test that unstake is blocked during reconfiguration
    function test_RevertWhen_unstake_duringReconfiguration() public {
        address pool = _createStakePool(alice, MIN_BOND * 2);

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool).unstake(1 ether);
    }

    /// @notice Test that withdrawAvailable is blocked during reconfiguration
    function test_RevertWhen_withdrawAvailable_duringReconfiguration() public {
        address pool = _createStakePool(alice, MIN_BOND);

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool).withdrawAvailable(alice);
    }

    /// @notice Test that unstakeAndWithdraw is blocked during reconfiguration
    function test_RevertWhen_unstakeAndWithdraw_duringReconfiguration() public {
        address pool = _createStakePool(alice, MIN_BOND * 2);

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool).unstakeAndWithdraw(1 ether, alice);
    }

    /// @notice Test that renewLockUntil is blocked during reconfiguration
    function test_RevertWhen_renewLockUntil_duringReconfiguration() public {
        address pool = _createStakePool(alice, MIN_BOND);

        // Start reconfiguration
        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);
    }

    /// @notice Test that staking operations work normally when reconfiguration is not in progress
    function test_stakingOperations_whenNotReconfiguring() public {
        address pool = _createStakePool(alice, MIN_BOND * 2);

        // Ensure reconfiguration is not in progress
        mockReconfiguration.setTransitionInProgress(false);

        // All operations should work
        vm.startPrank(alice);

        // addStake
        IStakePool(pool).addStake{ value: 1 ether }();
        assertEq(IStakePool(pool).getActiveStake(), MIN_BOND * 2 + 1 ether);

        // unstake
        IStakePool(pool).unstake(1 ether);
        assertEq(IStakePool(pool).getTotalPending(), 1 ether);

        // renewLockUntil
        uint64 oldLockup = IStakePool(pool).getLockedUntil();
        IStakePool(pool).renewLockUntil(LOCKUP_DURATION);
        assertGt(IStakePool(pool).getLockedUntil(), oldLockup);

        vm.stopPrank();
    }
}

