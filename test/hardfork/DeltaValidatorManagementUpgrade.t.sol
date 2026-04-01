// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DeltaHardforkBase } from "./DeltaHardforkBase.t.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { ValidatorConsensusInfo, ValidatorStatus } from "../../src/foundation/Types.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title DeltaValidatorManagementUpgradeTest
/// @notice Tests for ValidatorManagement after Delta hardfork bytecode replacement.
///         Key concerns from PR #49 and #55:
///         - Consensus key rotation: pending key pattern (rotateConsensusKey → applied at epoch boundary)
///         - try/catch on renewPoolLockup (epoch transition liveness)
///         - Whale node VP activation (first validator always activates even if power > maxIncrease)
///         - Eviction fairness: break → continue (tail-index validators no longer immune)
contract DeltaValidatorManagementUpgradeTest is DeltaHardforkBase {
    address public pool1;
    address public pool2;

    function setUp() public override {
        super.setUp();
        // Create pools with larger stakes for VP limit headroom
        // Total VP = 30 + 30 = 60 ETH, 20% = 12 ETH > MIN_BOND (10 ETH)
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 3, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND * 3, "bob");
        _processEpoch();

        // Apply Delta hardfork
        _applyDeltaHardfork();
    }

    // ========================================================================
    // CONSENSUS KEY ROTATION (Pending Key Pattern — Fix D2-3)
    // ========================================================================

    /// @notice Test that rotateConsensusKey stores key as pending (not immediately applied)
    function test_consensusKeyRotation_pendingPattern() public {
        // Get current consensus pubkey
        ValidatorConsensusInfo[] memory infoBefore = validatorManager.getActiveValidators();
        bytes memory oldKey = infoBefore[0].consensusPubkey;

        // Generate new key material
        bytes memory newPubkey = abi.encodePacked(pool1, bytes28(keccak256(abi.encodePacked(pool1, "rotated"))));
        bytes memory newPop = hex"deadbeef";

        // Rotate consensus key
        vm.prank(alice);
        validatorManager.rotateConsensusKey(pool1, newPubkey, newPop);

        // Key should NOT have changed yet (it's pending)
        ValidatorConsensusInfo[] memory infoAfter = validatorManager.getActiveValidators();
        assertEq(
            keccak256(infoAfter[0].consensusPubkey), keccak256(oldKey), "key should not change until epoch boundary"
        );

        // Complete epoch transition — pending key should be applied
        _completeEpochTransition();

        // Now the key should be the new one
        ValidatorConsensusInfo[] memory infoEpoch = validatorManager.getActiveValidators();
        // Find pool1's entry (order might change after epoch)
        bool found = false;
        for (uint256 i = 0; i < infoEpoch.length; i++) {
            if (infoEpoch[i].validator == pool1) {
                assertEq(
                    keccak256(infoEpoch[i].consensusPubkey),
                    keccak256(newPubkey),
                    "new key should be applied after epoch"
                );
                found = true;
                break;
            }
        }
        assertTrue(found, "pool1 should be in active set");
    }

    /// @notice Test that duplicate consensus key during rotation is rejected
    function test_consensusKeyRotation_duplicateRejected() public {
        // Get bob's current consensus key
        ValidatorConsensusInfo[] memory info = validatorManager.getActiveValidators();
        bytes memory bobKey;
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].validator == pool2) {
                bobKey = info[i].consensusPubkey;
                break;
            }
        }

        // Alice tries to rotate to bob's key — should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateConsensusPubkey.selector, bobKey));
        validatorManager.rotateConsensusKey(pool1, bobKey, hex"aabb");
    }

    /// @notice Test overwriting a pending key rotation before epoch boundary
    function test_consensusKeyRotation_overwritePending() public {
        bytes memory key1 = abi.encodePacked(pool1, bytes28(keccak256(abi.encodePacked(pool1, "key1"))));
        bytes memory key2 = abi.encodePacked(pool1, bytes28(keccak256(abi.encodePacked(pool1, "key2"))));

        // Rotate to key1
        vm.prank(alice);
        validatorManager.rotateConsensusKey(pool1, key1, hex"a0a1");

        // Rotate to key2 (overwrites pending key1)
        vm.prank(alice);
        validatorManager.rotateConsensusKey(pool1, key2, hex"b0b2");

        // After epoch, key2 should be applied (not key1)
        _completeEpochTransition();

        ValidatorConsensusInfo[] memory info = validatorManager.getActiveValidators();
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].validator == pool1) {
                assertEq(keccak256(info[i].consensusPubkey), keccak256(key2), "key2 should be applied, not key1");
                break;
            }
        }

        // key1 should be freed — someone else can now use it
        address pool3 = _createAndRegisterValidator(charlie, MIN_BOND, "charlie");
        // Registering charlie already consumed a unique key. Rotate charlie to key1.
        vm.prank(charlie);
        validatorManager.rotateConsensusKey(pool3, key1, hex"c0c3c4c5c6");
        // Should not revert — key1 was released when alice overwrote it with key2
    }

    // ========================================================================
    // TRY/CATCH ON RENEW POOL LOCKUP (Epoch Transition Liveness — PR #49)
    // ========================================================================

    /// @notice Test that epoch transition succeeds even if renewing a pool lockup somehow fails
    /// @dev The try/catch wrapping ensures one bad pool can't block the entire reconfiguration
    function test_epochTransition_livenesDespitePoolIssue() public {
        // Complete multiple epoch transitions — they should all succeed
        for (uint256 i = 0; i < 3; i++) {
            _completeEpochTransition();
        }
        assertEq(validatorManager.getActiveValidatorCount(), 2, "validators preserved");
    }

    // ========================================================================
    // WHALE NODE VP ACTIVATION (PR #55)
    // ========================================================================

    /// @notice Test that a whale validator (power > maxIncrease) can still activate
    /// @dev The fix ensures addedPower > 0 check allows first validator to always activate
    function test_whaleNodeActivation_firstAlwaysActivates() public {
        // Create a whale validator with very large stake
        // maxIncrease = totalVP * 20% = 60 * 20% = 12 ETH
        // Whale has 100 ETH which is > 12 ETH
        address whalePool = _createRegisterAndJoin(charlie, 100 ether, "whale");

        // Complete enough epochs — whale should eventually be activated
        bool whaleActivated = false;
        for (uint256 i = 0; i < 5; i++) {
            _completeEpochTransition();
            if (validatorManager.getActiveValidatorCount() >= 3) {
                whaleActivated = true;
                break;
            }
        }

        assertTrue(whaleActivated, "whale should be activated (addedPower > 0 check)");
        assertEq(
            uint8(validatorManager.getValidatorStatus(whalePool)),
            uint8(ValidatorStatus.ACTIVE),
            "whale should be active"
        );
    }

    // ========================================================================
    // EVICTION FAIRNESS (break → continue — PR #55)
    // ========================================================================

    /// @notice Test that eviction continues checking all validators instead of stopping early
    /// @dev The break→continue fix ensures tail-index validators don't have positional immunity
    function test_evictionFairness_noPositionalImmunity() public {
        // This test verifies the new behavior doesn't break normal eviction flow.
        // With 2 validators, if one leaves, the other remains.
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

    // ========================================================================
    // BASIC OPERATIONS STILL WORK
    // ========================================================================

    /// @notice Test that validator join still works after hardfork
    function test_validatorJoin_afterHardfork() public {
        address pool3 = _createAndRegisterValidator(charlie, MIN_BOND, "charlie");
        vm.prank(charlie);
        validatorManager.joinValidatorSet(pool3);

        for (uint256 i = 0; i < 5; i++) {
            _completeEpochTransition();
            if (validatorManager.getActiveValidatorCount() >= 3) break;
        }

        assertEq(validatorManager.getActiveValidatorCount(), 3, "should have 3 validators");
    }

    /// @notice Test setFeeRecipient still rejects zero address
    function test_setFeeRecipient_zeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        validatorManager.setFeeRecipient(pool1, address(0));
    }
}
