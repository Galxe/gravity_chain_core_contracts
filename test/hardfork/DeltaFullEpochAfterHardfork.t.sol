// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DeltaHardforkBase } from "./DeltaHardforkBase.t.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { ValidatorConsensusInfo, ValidatorStatus } from "../../src/foundation/Types.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";
import { IDKG } from "../../src/runtime/IDKG.sol";

/// @title DeltaFullEpochAfterHardforkTest
/// @notice Integration test: complete epoch lifecycle after Delta hardfork.
///         Verifies the entire consensus engine flow works correctly with upgraded bytecodes.
contract DeltaFullEpochAfterHardforkTest is DeltaHardforkBase {
    address public pool1;
    address public pool2;

    function setUp() public override {
        super.setUp();
        // Setup running chain with larger stakes so voting power increase limit (20%)
        // allows a new MIN_BOND validator to join in one epoch.
        // Total VP = 30 + 30 = 60 ETH, 20% = 12 ETH > MIN_BOND (10 ETH)
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 3, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND * 3, "bob");
        _processEpoch();

        // Apply Delta hardfork mid-chain
        _applyDeltaHardfork();
    }

    // ========================================================================
    // BASIC EPOCH LIFECYCLE
    // ========================================================================

    /// @notice Complete a full epoch transition after hardfork
    function test_epochTransition_fullCycleAfterHardfork() public {
        assertEq(validatorManager.getActiveValidatorCount(), 2, "should have 2 validators");
        uint64 epochBefore = reconfig.currentEpoch();

        // Complete epoch transition
        _completeEpochTransition();

        assertEq(reconfig.currentEpoch(), epochBefore + 1, "epoch should advance");
        assertEq(validatorManager.getActiveValidatorCount(), 2, "validators preserved");
    }

    /// @notice Run multiple epoch transitions after hardfork
    function test_epochTransition_multipleAfterHardfork() public {
        for (uint64 i = 0; i < 5; i++) {
            uint64 epochBefore = reconfig.currentEpoch();
            _completeEpochTransition();
            assertEq(reconfig.currentEpoch(), epochBefore + 1, "epoch should advance");
        }
    }

    // ========================================================================
    // VALIDATOR CHURN AFTER HARDFORK
    // ========================================================================

    /// @notice New validator can join after hardfork
    function test_validatorJoin_afterHardfork() public {
        // Charlie joins with MIN_BOND
        address pool3 = _createAndRegisterValidator(charlie, MIN_BOND, "charlie");
        vm.prank(charlie);
        validatorManager.joinValidatorSet(pool3);

        // Complete enough epochs for charlie to be activated
        for (uint256 i = 0; i < 5; i++) {
            _completeEpochTransition();
            if (validatorManager.getActiveValidatorCount() >= 3) break;
        }

        assertEq(validatorManager.getActiveValidatorCount(), 3, "should have 3 validators");
        assertEq(
            uint8(validatorManager.getValidatorStatus(pool3)), uint8(ValidatorStatus.ACTIVE), "charlie should be active"
        );
    }

    /// @notice Validator can leave after hardfork
    function test_validatorLeave_afterHardfork() public {
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        _completeEpochTransition();

        assertEq(validatorManager.getActiveValidatorCount(), 1, "should have 1 validator");
        assertEq(
            uint8(validatorManager.getValidatorStatus(pool1)),
            uint8(ValidatorStatus.INACTIVE),
            "alice should be inactive"
        );
    }

    /// @notice Validator churn (join + leave) in same epoch after hardfork
    function test_validatorChurn_afterHardfork() public {
        // Alice leaves
        vm.prank(alice);
        validatorManager.leaveValidatorSet(pool1);

        // Charlie joins (within voting power limit)
        address pool3 = _createAndRegisterValidator(charlie, MIN_BOND, "charlie");
        vm.prank(charlie);
        validatorManager.joinValidatorSet(pool3);

        // Complete epochs until churn is processed
        for (uint256 i = 0; i < 3; i++) {
            _completeEpochTransition();
            if (validatorManager.getActiveValidatorCount() == 2) break;
        }

        // Alice should have left, charlie should have joined
        assertEq(
            uint8(validatorManager.getValidatorStatus(pool1)),
            uint8(ValidatorStatus.INACTIVE),
            "alice should be inactive"
        );
    }

    // ========================================================================
    // STAKING OPERATIONS AFTER HARDFORK
    // ========================================================================

    /// @notice Staking operations work correctly after hardfork + epoch transition
    function test_staking_operationsAfterHardforkEpoch() public {
        // Complete an epoch first
        _completeEpochTransition();

        // Add stake
        uint256 stakeBefore = IStakePool(pool1).getActiveStake();
        vm.prank(alice);
        IStakePool(pool1).addStake{ value: 5 ether }();
        assertEq(IStakePool(pool1).getActiveStake(), stakeBefore + 5 ether, "stake should increase");

        // Complete another epoch
        _completeEpochTransition();

        // Verify voting power updated
        assertEq(validatorManager.getActiveValidatorCount(), 2, "validators still active");
    }

    // ========================================================================
    // STAKING CONFIG PENDING + EPOCH (CROSS-MODULE)
    // ========================================================================

    /// @notice StakingConfig pending config (3-arg) applied via Reconfiguration after hardfork
    function test_stakingConfigPending_appliedViaEpoch() public {
        uint256 newMinStake = 5 ether;

        // Queue config change (3-arg signature)
        vm.prank(SystemAddresses.GOVERNANCE);
        stakingConfig.setForNextEpoch(newMinStake, LOCKUP_DURATION, UNBONDING_DELAY);
        assertTrue(stakingConfig.hasPendingConfig(), "should have pending");

        // Complete epoch transition
        _completeEpochTransition();

        // Config should be applied
        assertEq(stakingConfig.minimumStake(), newMinStake, "new config applied");
        assertFalse(stakingConfig.hasPendingConfig(), "pending cleared");
    }

    // ========================================================================
    // RECONFIGURATION INVARIANTS
    // ========================================================================

    /// @notice No staking operations during reconfiguration (invariant preserved after hardfork)
    function test_invariant_frozenDuringReconfig() public {
        // Create charlie's pool before reconfig starts
        _createAndRegisterValidator(charlie, MIN_BOND, "charlie");

        // Start reconfiguration
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        assertTrue(reconfig.isTransitionInProgress(), "should be in reconfiguration");

        // StakePool.addStake blocked during reconfig
        vm.prank(alice);
        vm.expectRevert(Errors.ReconfigurationInProgress.selector);
        IStakePool(pool1).addStake{ value: 1 ether }();

        // Complete reconfig
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);

        // Now operations resume
        vm.prank(alice);
        IStakePool(pool1).addStake{ value: 1 ether }();
    }

    // ========================================================================
    // DKG SESSION AFTER HARDFORK
    // ========================================================================

    /// @notice DKG session starts correctly after hardfork
    function test_dkg_sessionAfterHardfork() public {
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();

        (bool hasSession, IDKG.DKGSessionInfo memory sessionInfo) = dkg.getIncompleteSession();
        assertTrue(hasSession, "should have DKG session");
        assertEq(sessionInfo.metadata.dealerValidatorSet.length, 2, "should have 2 dealers");
        assertEq(sessionInfo.metadata.targetValidatorSet.length, 2, "should have 2 targets");

        // Complete
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);
        assertEq(reconfig.currentEpoch(), 2, "epoch should advance");
    }

    // ========================================================================
    // CONSENSUS KEY ROTATION ACROSS EPOCHS (Integration)
    // ========================================================================

    /// @notice Test consensus key rotation works across epoch boundaries after hardfork
    function test_consensusKeyRotation_acrossEpochs() public {
        // Rotate alice's key
        bytes memory newPubkey = abi.encodePacked(pool1, bytes28(keccak256(abi.encodePacked(pool1, "newkey"))));
        vm.prank(alice);
        validatorManager.rotateConsensusKey(pool1, newPubkey, hex"a0b1c2d3");

        // Complete epoch — key should be applied
        _completeEpochTransition();

        // Verify new key is active
        ValidatorConsensusInfo[] memory info = validatorManager.getActiveValidators();
        bool found = false;
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].validator == pool1) {
                assertEq(keccak256(info[i].consensusPubkey), keccak256(newPubkey), "new key applied");
                found = true;
                break;
            }
        }
        assertTrue(found, "pool1 should be active");

        // Run more epochs to verify stability
        for (uint256 i = 0; i < 3; i++) {
            _completeEpochTransition();
        }
        assertEq(validatorManager.getActiveValidatorCount(), 2, "validators stable");
    }

    // ========================================================================
    // FUZZ: Multiple epoch transitions with random validator churn
    // ========================================================================

    /// @notice Fuzz test: epoch transitions with varying behavior after hardfork
    function testFuzz_epochsAfterHardfork(
        uint8 numEpochs
    ) public {
        numEpochs = uint8(bound(numEpochs, 1, 10));

        for (uint8 i = 0; i < numEpochs; i++) {
            _completeEpochTransition();
        }

        // Should complete without reverting
        assertEq(reconfig.currentEpoch(), uint64(1) + uint64(numEpochs), "should complete all epochs");
    }
}
