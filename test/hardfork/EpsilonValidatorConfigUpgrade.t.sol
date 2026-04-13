// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EpsilonHardforkBase } from "./EpsilonHardforkBase.t.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { ValidatorConfig } from "../../src/runtime/ValidatorConfig.sol";

/// @title EpsilonValidatorConfigUpgrade
/// @notice Verifies PR #63 ValidatorConfig changes preserve hardfork storage compatibility.
///
///         The risk: PR #63 introduced two new fields (`autoEvictThresholdPct` at the
///         contract level *and* inside `PendingConfig`) plus renamed the original
///         `autoEvictThreshold` to `__deprecated_autoEvictThreshold`. If declared in
///         the wrong order, the new uint64 field would land on a fresh slot and grow
///         `PendingConfig` from 6 → 7 slots, shifting the trailing `hasPendingConfig`
///         and `_initialized` slots from slot 12 → slot 13. After bytecode replacement,
///         the v1.4 code would read `_initialized` from slot 13 (which was zero in v1.3)
///         → contract appears un-initialized → bricked.
///
///         The fix: declare `autoEvictThresholdPct` immediately after `autoEvictEnabled`
///         (both contract-level and inside `PendingConfig`) so it packs into the same
///         storage slot. This preserves the v1.3 6-slot PendingConfig footprint.
contract EpsilonValidatorConfigUpgradeTest is EpsilonHardforkBase {
    // ────────────────────────────────────────────────────────────────────────
    // Storage layout invariants — these slot positions MUST match v1.3
    // ────────────────────────────────────────────────────────────────────────

    /// @dev v1.3 layout: `hasPendingConfig` lives at slot 12 offset 0 (packed with
    ///      `_initialized` at offset 1). v1.4 must NOT shift this to slot 13.
    uint256 internal constant SLOT_HAS_PENDING_AND_INITIALIZED = 12;

    /// @dev v1.3 layout: `_pendingConfig` starts at slot 6 and occupies 6 slots
    ///      (192 bytes). v1.4 must keep the same footprint.
    uint256 internal constant PENDING_CONFIG_START_SLOT = 6;
    uint256 internal constant PENDING_CONFIG_SLOT_COUNT = 6;

    function test_initializedSlot_didNotShiftToSlot13() public view {
        // After setUp() + _initializeAllConfigs(), `_initialized` is true.
        // It MUST live at slot 12 offset 1 (packed with `hasPendingConfig`),
        // not at slot 13 — otherwise the v1.3 → v1.4 hardfork bricks the contract.
        bytes32 slot12 = vm.load(SystemAddresses.VALIDATOR_CONFIG, bytes32(SLOT_HAS_PENDING_AND_INITIALIZED));
        // Offset 1 byte 1 must be 0x01 (true)
        uint8 initializedByte = uint8(uint256(slot12) >> 8) & 0xFF;
        assertEq(initializedByte, 1, "_initialized must be at slot 12 offset 1, not slot 13");

        // Slot 13 should be untouched by `_initialized`. Either it's used by something
        // else benign or it's all-zero. Crucially the LSB (where `_initialized` would
        // land if mispositioned) should NOT be 1.
        bytes32 slot13 = vm.load(SystemAddresses.VALIDATOR_CONFIG, bytes32(uint256(13)));
        uint8 slot13Byte0 = uint8(uint256(slot13)) & 0xFF;
        uint8 slot13Byte1 = uint8(uint256(slot13) >> 8) & 0xFF;
        assertEq(slot13Byte0, 0, "slot 13 offset 0 must not hold a stray hasPendingConfig (v1.4 layout drift)");
        assertEq(slot13Byte1, 0, "slot 13 offset 1 must not hold a stray _initialized (v1.4 layout drift)");
    }

    function test_pendingConfig_slotFootprint_matchesV13() public {
        // Set a pending config so we can sanity-check that all 6 slots are used and
        // that no 7th slot leaks beyond the documented footprint.
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, true, 50
        );

        // Slots 6..11 should now contain the pending config; slot 12 (hasPendingConfig)
        // should be flipped to 0x01 in offset 0.
        for (uint256 i = 0; i < PENDING_CONFIG_SLOT_COUNT; i++) {
            bytes32 v = vm.load(SystemAddresses.VALIDATOR_CONFIG, bytes32(PENDING_CONFIG_START_SLOT + i));
            // We don't assert exact content (depends on packing) — just that the area
            // is *active* by checking that at least the first slot (minimumBond) is non-zero.
            if (i == 0) {
                assertGt(uint256(v), 0, "pending minimumBond must be set in slot 6");
            }
        }

        // The 7th slot (slot 12) MUST be the contract-level packed (hasPendingConfig, _initialized),
        // NOT pending struct overflow.
        bytes32 slot12 = vm.load(SystemAddresses.VALIDATOR_CONFIG, bytes32(SLOT_HAS_PENDING_AND_INITIALIZED));
        uint8 hasPendingByte = uint8(uint256(slot12)) & 0xFF;
        assertEq(hasPendingByte, 1, "hasPendingConfig must flip to 1 at slot 12 offset 0");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Survives bytecode re-etch (the hardfork apply path)
    // ────────────────────────────────────────────────────────────────────────

    function test_storagePreservedAcrossHardforkEtch() public {
        // Set non-default state pre-hardfork
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, true, 60
        );
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        uint256 minBondBefore = validatorConfig.minimumBond();
        bool autoEvictBefore = validatorConfig.autoEvictEnabled();
        uint64 pctBefore = validatorConfig.autoEvictThresholdPct();
        bool initializedBefore = validatorConfig.isInitialized();

        // Apply the Epsilon hardfork (re-etch ValidatorConfig bytecode)
        _applyEpsilonHardfork();

        // Every state read must return the exact same value
        assertEq(validatorConfig.minimumBond(), minBondBefore);
        assertEq(validatorConfig.autoEvictEnabled(), autoEvictBefore);
        assertEq(validatorConfig.autoEvictThresholdPct(), pctBefore);
        assertEq(validatorConfig.isInitialized(), initializedBefore);
        assertTrue(initializedBefore, "must have been initialized before hardfork");
    }

    function test_setForNextEpochStillWorksAfterHardfork() public {
        _applyEpsilonHardfork();

        // After the hardfork we should still be able to set + apply a new pending config
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND * 3, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, true, 75
        );
        assertTrue(validatorConfig.hasPendingConfig());

        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        assertEq(validatorConfig.minimumBond(), MIN_BOND * 3);
        assertEq(validatorConfig.autoEvictThresholdPct(), 75);
        assertFalse(validatorConfig.hasPendingConfig());
    }

    // ────────────────────────────────────────────────────────────────────────
    // ABI surface change
    // ────────────────────────────────────────────────────────────────────────

    function test_oldAutoEvictThresholdSelector_removed() public {
        _applyEpsilonHardfork();
        // The old v1.3 selector `autoEvictThreshold()(uint256)` should not be in
        // the dispatcher; the field is now `__deprecated_autoEvictThreshold` (private).
        (bool ok,) = SystemAddresses.VALIDATOR_CONFIG.call(abi.encodeWithSignature("autoEvictThreshold()"));
        assertFalse(ok, "autoEvictThreshold() selector must not be reachable post-hardfork");
    }
}
