// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ValidatorManagement } from "../../../src/staking/ValidatorManagement.sol";
import { IValidatorManagement, GenesisValidator } from "../../../src/staking/IValidatorManagement.sol";
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
import { MockBlsPopVerify } from "../../utils/MockBlsPopVerify.sol";

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
    bytes constant CONSENSUS_PUBKEY =
        hex"9112af1a4ef4038dfe24c5371e40b5bcfce16146bfc4ab819244ce57f5d002c4c3f06eca7273e733c0f78aada8c13deb";
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

        // Deploy mock BLS PoP precompile (real precompile lives in external EVM)
        vm.etch(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE, address(new MockBlsPopVerify()).code);
        mockReconfiguration = MockReconfiguration(SystemAddresses.RECONFIGURATION);

        // Initialize StakingConfig (with unbonding delay)
        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, 10 ether);

        // Initialize ValidatorConfig
        vm.prank(SystemAddresses.GENESIS);
        validatorConfig.initialize(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
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
    /// @dev Generates unique consensusPubkey to avoid DuplicateConsensusPubkey
    function _createAndRegisterValidator(
        address owner,
        uint256 stakeAmount,
        string memory moniker
    ) internal returns (address pool) {
        pool = _createStakePool(owner, stakeAmount);
        // Generate unique 48-byte pubkey based on pool address (BLS12-381 G1 compressed size)
        bytes memory uniquePubkey = abi.encodePacked(pool, bytes28(keccak256(abi.encodePacked(pool))));
        vm.prank(owner); // owner is also operator by default
        validatorManager.registerValidator(
            pool, moniker, uniquePubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
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

        ValidatorConsensusInfo[] memory pending = validatorManager.getPendingActiveValidators();
        assertEq(pending.length, 1, "Should have one pending validator");
        assertEq(pending[0].validator, pool, "Pending validator should match");
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
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, false, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
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

        ValidatorConsensusInfo[] memory pending = validatorManager.getPendingInactiveValidators();
        assertEq(pending.length, 1, "Should have one pending inactive");
        assertEq(pending[0].validator, pool1, "Pending should match");
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
        bytes memory newPubkey =
            hex"a666d31d6e3c5e8aab7e0f2e926f0b4307bbad66166a5598c8dde1152f2e16e964ad3e42f5e7c73e2e35c6a69b108f4e";
        bytes memory newPop = hex"cafebabe";

        vm.prank(alice);
        validatorManager.rotateConsensusKey(pool, newPubkey, newPop);

        ValidatorRecord memory record = validatorManager.getValidator(pool);
        assertEq(record.consensusPubkey, newPubkey, "Pubkey should be updated");
        assertEq(record.consensusPop, newPop, "PoP should be updated");
    }

    function test_rotateConsensusKey_emitsEvent() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");
        bytes memory newPubkey =
            hex"a666d31d6e3c5e8aab7e0f2e926f0b4307bbad66166a5598c8dde1152f2e16e964ad3e42f5e7c73e2e35c6a69b108f4e";

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ConsensusKeyRotated(pool, newPubkey);
        validatorManager.rotateConsensusKey(pool, newPubkey, hex"");
    }

    // ========================================================================
    // CONSENSUS PUBKEY UNIQUENESS TESTS
    // ========================================================================

    /// @notice Test that registering with a duplicate pubkey fails
    function test_RevertWhen_registerValidator_duplicatePubkey() public {
        // Alice registers with a specific pubkey
        address alicePool = _createStakePool(alice, MIN_BOND);
        bytes memory alicePubkey =
            hex"a1cecafe0000000100000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(alice);
        validatorManager.registerValidator(
            alicePool, "alice", alicePubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        // Bob tries to register with the same pubkey - should fail
        address bobPool = _createStakePool(bob, MIN_BOND);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateConsensusPubkey.selector, alicePubkey));
        validatorManager.registerValidator(
            bobPool, "bob", alicePubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    /// @notice Test that rotating to a pubkey already in use fails
    function test_RevertWhen_rotateConsensusKey_duplicatePubkey() public {
        // Alice and Bob register with different pubkeys
        address alicePool = _createStakePool(alice, MIN_BOND);
        bytes memory alicePubkey =
            hex"a1cecafe0000000100000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(alice);
        validatorManager.registerValidator(
            alicePool, "alice", alicePubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        address bobPool = _createStakePool(bob, MIN_BOND);
        bytes memory bobPubkey =
            hex"b0b0b0b0b01234aa00000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(bob);
        validatorManager.registerValidator(
            bobPool, "bob", bobPubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        // Alice tries to rotate to Bob's pubkey - should fail
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateConsensusPubkey.selector, bobPubkey));
        validatorManager.rotateConsensusKey(alicePool, bobPubkey, hex"abcd1234");
    }

    /// @notice Test that after rotation, old pubkey can be reused by another validator
    function test_rotateConsensusKey_clearsOldPubkey() public {
        // Alice registers with a specific pubkey
        address alicePool = _createStakePool(alice, MIN_BOND);
        bytes memory aliceOldPubkey =
            hex"a1cecafe0000000100000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(alice);
        validatorManager.registerValidator(
            alicePool, "alice", aliceOldPubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        // Alice rotates to a new key
        bytes memory aliceNewPubkey =
            hex"a1ecafe00000000200000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(alice);
        validatorManager.rotateConsensusKey(alicePool, aliceNewPubkey, hex"abcd1234");

        // Bob should now be able to register with Alice's old pubkey
        address bobPool = _createStakePool(bob, MIN_BOND);
        vm.prank(bob);
        validatorManager.registerValidator(
            bobPool, "bob", aliceOldPubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        // Verify both validators have their expected pubkeys
        ValidatorRecord memory aliceRecord = validatorManager.getValidator(alicePool);
        ValidatorRecord memory bobRecord = validatorManager.getValidator(bobPool);
        assertEq(aliceRecord.consensusPubkey, aliceNewPubkey, "Alice should have new pubkey");
        assertEq(bobRecord.consensusPubkey, aliceOldPubkey, "Bob should have Alice's old pubkey");
    }

    /// @notice Test that a validator can rotate to a new key while other validators have different keys
    function test_rotateConsensusKey_uniqueKeySuccess() public {
        // Alice and Bob both register with different pubkeys
        address alicePool = _createStakePool(alice, MIN_BOND);
        bytes memory alicePubkey =
            hex"a1cecafe0000000100000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(alice);
        validatorManager.registerValidator(
            alicePool, "alice", alicePubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        address bobPool = _createStakePool(bob, MIN_BOND);
        bytes memory bobPubkey =
            hex"b0b0b0b0b01234aa00000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(bob);
        validatorManager.registerValidator(
            bobPool, "bob", bobPubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );

        // Alice rotates to a completely new key (not Bob's)
        bytes memory aliceNewPubkey =
            hex"a1ecafe00000000300000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(alice);
        validatorManager.rotateConsensusKey(alicePool, aliceNewPubkey, hex"abcd1234");

        ValidatorRecord memory aliceRecord = validatorManager.getValidator(alicePool);
        assertEq(aliceRecord.consensusPubkey, aliceNewPubkey, "Alice should have new pubkey");
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
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, false, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
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
    /// @dev Uses 100 ether for alice so 20% voting power limit (20 ether) allows bob (10 ether) to join
    function test_getNextValidatorConsensusInfos_includesPendingActive() public {
        // Alice with 100 ether -> 20% voting power increase limit = 20 ether
        address pool1 = _createRegisterAndJoin(alice, 100 ether, "alice");
        _processEpoch();

        // Bob joins with MIN_BOND (10 ether) - fits within 20 ether limit
        address pool2 = _createAndRegisterValidator(bob, MIN_BOND, "bob");
        vm.prank(bob);
        validatorManager.joinValidatorSet(pool2);

        ValidatorConsensusInfo[] memory next = validatorManager.getNextValidatorConsensusInfos();

        // Should include both alice (active) and bob (pending_active)
        assertEq(next.length, 2, "Should include active and pending_active validators");
    }

    /// @notice Test getNextValidatorConsensusInfos assigns fresh indices (0, 1, 2, ...)
    /// @dev Total active power = 60 ether -> 20% limit = 12 ether. David uses MIN_BOND to fit.
    function test_getNextValidatorConsensusInfos_freshIndices() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, 20 ether, "bob");
        address pool3 = _createRegisterAndJoin(charlie, 30 ether, "charlie");
        _processEpoch();

        // Validator bob leaves (becomes pending_inactive)
        vm.prank(bob);
        validatorManager.leaveValidatorSet(pool2);

        // New validator david joins (becomes pending_active)
        // Total active power = 10 + 20 + 30 = 60 ether -> 20% limit = 12 ether
        // David uses MIN_BOND (10 ether) to fit within the limit
        address pool4 = _createAndRegisterValidator(david, MIN_BOND, "david");
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
    ///      Next returns (active - pending_inactive) + pending_active (respecting voting power limit)
    ///      Total active power = 60 ether -> 20% limit = 12 ether. David uses MIN_BOND to fit.
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
        // Total active power = 10 + 20 + 30 = 60 ether -> 20% limit = 12 ether
        // David uses MIN_BOND (10 ether) to fit within the limit
        address pool4 = _createAndRegisterValidator(david, MIN_BOND, "david");
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

    // ========================================================================
    // FORCE LEAVE VALIDATOR SET TESTS (Governance Privilege)
    // ========================================================================

    /// @notice Test that governance can force an ACTIVE validator to PENDING_INACTIVE
    function test_forceLeaveValidatorSet_fromActive() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.ACTIVE));

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.forceLeaveValidatorSet(pool1);

        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.PENDING_INACTIVE));

        ValidatorConsensusInfo[] memory pending = validatorManager.getPendingInactiveValidators();
        assertEq(pending.length, 1);
        assertEq(pending[0].validator, pool1);
    }

    /// @notice Test that governance can force a PENDING_ACTIVE validator to INACTIVE
    function test_forceLeaveValidatorSet_fromPendingActive() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");

        vm.prank(alice);
        validatorManager.joinValidatorSet(pool);
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.PENDING_ACTIVE));

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.forceLeaveValidatorSet(pool);

        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.INACTIVE));
        assertEq(validatorManager.getPendingActiveValidators().length, 0);
    }

    /// @notice Test that forceLeaveValidatorSet emits ValidatorForceLeaveRequested event
    function test_forceLeaveValidatorSet_emitsEvent() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectEmit(true, false, false, false);
        emit IValidatorManagement.ValidatorForceLeaveRequested(pool1);
        validatorManager.forceLeaveValidatorSet(pool1);
    }

    /// @notice Test that forceLeaveValidatorSet reverts when called by non-governance
    function test_RevertWhen_forceLeaveValidatorSet_notGovernance() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        vm.prank(alice);
        vm.expectRevert(); // SystemAccessControl reverts
        validatorManager.forceLeaveValidatorSet(pool1);
    }

    /// @notice Test that forceLeaveValidatorSet reverts when validator not found
    function test_RevertWhen_forceLeaveValidatorSet_validatorNotFound() public {
        address fakePool = makeAddr("fakePool");

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.ValidatorNotFound.selector, fakePool));
        validatorManager.forceLeaveValidatorSet(fakePool);
    }

    /// @notice Test that forceLeaveValidatorSet reverts when validator is INACTIVE
    function test_RevertWhen_forceLeaveValidatorSet_alreadyInactive() public {
        address pool = _createAndRegisterValidator(alice, MIN_BOND, "alice");
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.INACTIVE));

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector, uint8(ValidatorStatus.ACTIVE), uint8(ValidatorStatus.INACTIVE)
            )
        );
        validatorManager.forceLeaveValidatorSet(pool);
    }

    /// @notice Test that forceLeaveValidatorSet reverts when validator is already PENDING_INACTIVE
    function test_RevertWhen_forceLeaveValidatorSet_alreadyPendingInactive() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        // Alice voluntarily leaves - becomes PENDING_INACTIVE
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);
        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.PENDING_INACTIVE));

        // Governance tries to force leave - should revert
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector, uint8(ValidatorStatus.ACTIVE), uint8(ValidatorStatus.PENDING_INACTIVE)
            )
        );
        validatorManager.forceLeaveValidatorSet(pool1);
    }

    /// @notice Test that forceLeaveValidatorSet is blocked during reconfiguration
    function test_RevertWhen_forceLeaveValidatorSet_duringReconfiguration() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        mockReconfiguration.setTransitionInProgress(true);

        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        validatorManager.forceLeaveValidatorSet(pool1);
    }

    /// @notice Test that governance CAN force remove the last active validator (unlike voluntary leave)
    /// @dev This is an emergency capability - governance can force even the last validator to leave
    function test_forceLeaveValidatorSet_canRemoveLastValidator() public {
        address pool = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        _processEpoch();

        assertEq(validatorManager.getActiveValidatorCount(), 1, "Should have exactly 1 validator");

        // Voluntary leave would fail with CannotRemoveLastValidator
        vm.prank(alice);
        vm.expectRevert(Errors.CannotRemoveLastValidator.selector);
        validatorManager.leaveValidatorSet(pool);

        // But governance force leave should succeed
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.forceLeaveValidatorSet(pool);

        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.PENDING_INACTIVE));

        // After epoch, validator becomes inactive and set is empty
        _processEpoch();
        assertEq(validatorManager.getActiveValidatorCount(), 0, "Validator set should be empty");
        assertEq(uint8(validatorManager.getValidatorStatus(pool)), uint8(ValidatorStatus.INACTIVE));
    }

    /// @notice Test forceLeaveValidatorSet takes effect at next epoch (not immediately)
    function test_forceLeaveValidatorSet_effectiveAtNextEpoch() public {
        address pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        address pool2 = _createRegisterAndJoin(bob, MIN_BOND, "bob");
        _processEpoch();

        assertEq(validatorManager.getActiveValidatorCount(), 2);

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.forceLeaveValidatorSet(pool1);

        // Still 2 active validators until epoch processes
        assertEq(validatorManager.getActiveValidatorCount(), 2);

        // Next validator set excludes the force-leaving validator
        ValidatorConsensusInfo[] memory next = validatorManager.getNextValidatorConsensusInfos();
        assertEq(next.length, 1, "Next set should only have bob");
        assertEq(next[0].validator, pool2);

        // Process epoch - now alice is fully deactivated
        _processEpoch();
        assertEq(validatorManager.getActiveValidatorCount(), 1);
        assertEq(uint8(validatorManager.getValidatorStatus(pool1)), uint8(ValidatorStatus.INACTIVE));
    }

    // ========================================================================
    // INITIALIZATION TESTS
    // ========================================================================

    /// @notice Test successful initialization with genesis validators
    function test_initialize_success() public {
        // Deploy a fresh ValidatorManagement for initialization testing
        ValidatorManagement freshManager = new ValidatorManagement();

        // Create genesis validator data
        GenesisValidator[] memory genesisValidators = new GenesisValidator[](2);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "genesis-alice",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });
        genesisValidators[1] = GenesisValidator({
            stakePool: bob,
            moniker: "genesis-bob",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: bob,
            votingPower: 200 ether
        });

        // Initialize from GENESIS
        vm.prank(SystemAddresses.GENESIS);
        freshManager.initialize(genesisValidators);

        // Verify initialization state
        assertTrue(freshManager.isInitialized(), "Should be initialized");
        assertEq(freshManager.getActiveValidatorCount(), 2, "Should have 2 active validators");
        assertEq(freshManager.getTotalVotingPower(), 300 ether, "Total voting power should be 300 ether");
    }

    /// @notice Test initialization sets correct validator state
    function test_initialize_setsCorrectState() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](1);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "genesis-alice",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: bob, // Different fee recipient
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        freshManager.initialize(genesisValidators);

        // Verify validator record
        ValidatorRecord memory record = freshManager.getValidator(alice);
        assertEq(record.validator, alice, "Validator should match stakePool");
        assertEq(record.moniker, "genesis-alice", "Moniker should match");
        assertEq(uint8(record.status), uint8(ValidatorStatus.ACTIVE), "Status should be ACTIVE");
        assertEq(record.bond, 100 ether, "Bond should match voting power");
        assertEq(record.feeRecipient, bob, "Fee recipient should match");
        assertEq(record.validatorIndex, 0, "Index should be 0");
        assertEq(record.consensusPubkey, CONSENSUS_PUBKEY, "Consensus pubkey should match");
        assertEq(record.consensusPop, CONSENSUS_POP, "Consensus pop should match");

        // Verify isValidator
        assertTrue(freshManager.isValidator(alice), "Should be a validator");
    }

    /// @notice Test initialization with multiple validators assigns correct indices
    function test_initialize_assignsCorrectIndices() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](3);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "alice",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });
        genesisValidators[1] = GenesisValidator({
            stakePool: bob,
            moniker: "bob",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: bob,
            votingPower: 200 ether
        });
        genesisValidators[2] = GenesisValidator({
            stakePool: charlie,
            moniker: "charlie",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: charlie,
            votingPower: 300 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        freshManager.initialize(genesisValidators);

        // Verify indices are assigned correctly
        ValidatorRecord memory aliceRecord = freshManager.getValidator(alice);
        ValidatorRecord memory bobRecord = freshManager.getValidator(bob);
        ValidatorRecord memory charlieRecord = freshManager.getValidator(charlie);

        assertEq(aliceRecord.validatorIndex, 0, "Alice should have index 0");
        assertEq(bobRecord.validatorIndex, 1, "Bob should have index 1");
        assertEq(charlieRecord.validatorIndex, 2, "Charlie should have index 2");

        // Verify getActiveValidatorByIndex works
        ValidatorConsensusInfo memory v0 = freshManager.getActiveValidatorByIndex(0);
        ValidatorConsensusInfo memory v1 = freshManager.getActiveValidatorByIndex(1);
        ValidatorConsensusInfo memory v2 = freshManager.getActiveValidatorByIndex(2);

        assertEq(v0.validator, alice, "Index 0 should be alice");
        assertEq(v1.validator, bob, "Index 1 should be bob");
        assertEq(v2.validator, charlie, "Index 2 should be charlie");
    }

    /// @notice Test initialization emits correct events
    function test_initialize_emitsEvents() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](1);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "genesis-alice",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);

        // Expect ValidatorRegistered event
        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ValidatorRegistered(alice, "genesis-alice");

        // Expect ValidatorActivated event
        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ValidatorActivated(alice, 0, 100 ether);

        // Expect ValidatorManagementInitialized event
        vm.expectEmit(false, false, false, true);
        emit IValidatorManagement.ValidatorManagementInitialized(1, 100 ether);

        freshManager.initialize(genesisValidators);
    }

    /// @notice Test initialization with empty validator set
    function test_initialize_emptyValidatorSet() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](0);

        vm.prank(SystemAddresses.GENESIS);
        freshManager.initialize(genesisValidators);

        assertTrue(freshManager.isInitialized(), "Should be initialized");
        assertEq(freshManager.getActiveValidatorCount(), 0, "Should have 0 validators");
        assertEq(freshManager.getTotalVotingPower(), 0, "Total voting power should be 0");
    }

    /// @notice Test isInitialized returns false before initialization
    function test_isInitialized_falseBeforeInit() public {
        ValidatorManagement freshManager = new ValidatorManagement();
        assertFalse(freshManager.isInitialized(), "Should not be initialized");
    }

    /// @notice Test revert when caller is not GENESIS
    function test_RevertWhen_initialize_notGenesis() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](0);

        vm.prank(alice);
        vm.expectRevert(); // AccessControl revert
        freshManager.initialize(genesisValidators);
    }

    /// @notice Test revert when already initialized
    function test_RevertWhen_initialize_alreadyInitialized() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](0);

        // First initialization succeeds
        vm.prank(SystemAddresses.GENESIS);
        freshManager.initialize(genesisValidators);

        // Second initialization reverts
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        freshManager.initialize(genesisValidators);
    }

    /// @notice Test revert when moniker is too long
    function test_RevertWhen_initialize_monikerTooLong() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        // Create a moniker that's 32 bytes (exceeds 31 byte limit)
        string memory longMoniker = "12345678901234567890123456789012"; // 32 chars

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](1);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: longMoniker,
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.MonikerTooLong.selector, 31, 32));
        freshManager.initialize(genesisValidators);
    }

    /// @notice Test revert when consensus pubkey has invalid length (too short)
    function test_RevertWhen_initialize_invalidConsensusPubkeyLength_tooShort() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](1);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "genesis-alice",
            consensusPubkey: hex"1234", // Only 2 bytes, expected 48
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidConsensusPubkeyLength.selector, 48, 2));
        freshManager.initialize(genesisValidators);
    }

    /// @notice Test revert when consensus pubkey has invalid length (too long)
    function test_RevertWhen_initialize_invalidConsensusPubkeyLength_tooLong() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        // 49 bytes (one more than expected 48)
        bytes memory longPubkey = new bytes(49);
        for (uint256 i = 0; i < 49; i++) {
            longPubkey[i] = 0xAB;
        }

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](1);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "genesis-alice",
            consensusPubkey: longPubkey,
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidConsensusPubkeyLength.selector, 48, 49));
        freshManager.initialize(genesisValidators);
    }

    /// @notice Test revert when consensus pubkey is empty
    function test_RevertWhen_initialize_emptyConsensusPubkey() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](1);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "genesis-alice",
            consensusPubkey: hex"", // Empty
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidConsensusPubkeyLength.selector, 48, 0));
        freshManager.initialize(genesisValidators);
    }

    /// @notice Test revert when consensus PoP is empty
    function test_RevertWhen_initialize_emptyConsensusPop() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](1);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "genesis-alice",
            consensusPubkey: CONSENSUS_PUBKEY,
            consensusPop: hex"", // Empty PoP
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.InvalidConsensusPopLength.selector);
        freshManager.initialize(genesisValidators);
    }

    /// @notice Test that getActiveValidators returns correct data after initialization
    function test_initialize_getActiveValidators() public {
        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](2);
        genesisValidators[0] = GenesisValidator({
            stakePool: alice,
            moniker: "alice",
            consensusPubkey: hex"111100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
            consensusPop: hex"2222",
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });
        genesisValidators[1] = GenesisValidator({
            stakePool: bob,
            moniker: "bob",
            consensusPubkey: hex"333300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
            consensusPop: hex"4444",
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: bob,
            votingPower: 200 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        freshManager.initialize(genesisValidators);

        // Get active validators
        ValidatorConsensusInfo[] memory activeValidators = freshManager.getActiveValidators();
        assertEq(activeValidators.length, 2, "Should have 2 active validators");

        // Verify alice's consensus info
        assertEq(activeValidators[0].validator, alice);
        assertEq(activeValidators[0].votingPower, 100 ether);
        assertEq(activeValidators[0].validatorIndex, 0);
        assertEq(
            activeValidators[0].consensusPubkey,
            hex"111100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        );

        // Verify bob's consensus info
        assertEq(activeValidators[1].validator, bob);
        assertEq(activeValidators[1].votingPower, 200 ether);
        assertEq(activeValidators[1].validatorIndex, 1);
        assertEq(
            activeValidators[1].consensusPubkey,
            hex"333300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    /// @notice Fuzz test for initialization with varying validator counts
    function testFuzz_initialize_varyingCounts(
        uint8 validatorCount
    ) public {
        // Limit to reasonable range to avoid gas issues
        vm.assume(validatorCount <= 20);

        ValidatorManagement freshManager = new ValidatorManagement();

        GenesisValidator[] memory genesisValidators = new GenesisValidator[](validatorCount);
        uint256 expectedTotalPower = 0;

        for (uint256 i = 0; i < validatorCount; i++) {
            address validator = address(uint160(i + 1000)); // Create unique addresses
            uint256 power = (i + 1) * 10 ether;
            expectedTotalPower += power;

            genesisValidators[i] = GenesisValidator({
                stakePool: validator,
                moniker: "validator",
                consensusPubkey: CONSENSUS_PUBKEY,
                consensusPop: CONSENSUS_POP,
                networkAddresses: NETWORK_ADDRESSES,
                fullnodeAddresses: FULLNODE_ADDRESSES,
                feeRecipient: validator,
                votingPower: power
            });
        }

        vm.prank(SystemAddresses.GENESIS);
        freshManager.initialize(genesisValidators);

        assertEq(freshManager.getActiveValidatorCount(), validatorCount, "Validator count should match");
        assertEq(freshManager.getTotalVotingPower(), expectedTotalPower, "Total voting power should match");
        assertTrue(freshManager.isInitialized(), "Should be initialized");
    }
}

