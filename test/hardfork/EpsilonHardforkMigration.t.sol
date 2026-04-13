// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { HardforkTestBase } from "./HardforkTestBase.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";
import { GBridgeReceiver } from "../../src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { ValidatorConfig } from "../../src/runtime/ValidatorConfig.sol";
import { ConsensusConfig } from "../../src/runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "../../src/runtime/ExecutionConfig.sol";
import { VersionConfig } from "../../src/runtime/VersionConfig.sol";
import { RandomnessConfig } from "../../src/runtime/RandomnessConfig.sol";

/// @title EpsilonHardforkMigration
/// @notice End-to-end v1.3 → v1.4 migration test.
///
///         Strategy:
///         1. Etch v1.3 bytecodes from `fixtures/gravity-testnet-v1.3/` onto every
///            system contract address.
///         2. Initialize via the v1.3 ABI (uint256 autoEvictThreshold) using raw calls.
///         3. Drive a small amount of state (set a pending config, apply it).
///         4. Apply the Epsilon hardfork via _applyHardfork(epsilon(...)).
///         5. Assert: storage values preserved, new uint64 selector works, old uint256
///            selector reverts, and the contract still reports as initialized.
///
///         This is the test that catches the kind of storage-layout regression
///         described in PR #63: if `_initialized` shifts from slot 12 to slot 13 the
///         post-hardfork `validatorConfig.minimumBond()` would still work but
///         `setForNextEpoch` (which calls `_requireInitialized()`) would revert.
contract EpsilonHardforkMigrationTest is HardforkTestBase {
    address public constant GBRIDGE_RECEIVER_ADDR = address(0xBEEF1234);

    address internal constant TRUSTED_BRIDGE = address(0xBEEF);
    uint256 internal constant TRUSTED_SOURCE_ID = 1;

    string internal constant FROM_TAG = "gravity-testnet-v1.3";

    function setUp() public {
        // Step 1: deploy all 19 system contracts from v1.3 fixture bytecodes
        _deployFromFixtures(FROM_TAG);

        // Step 2: deploy a v1.3 GBridgeReceiver instance at the chosen address.
        //         (v1.3 GBridgeReceiver is identical in interface to a current build
        //         except for `isProcessed`/`AlreadyProcessed`; constructor signature
        //         is unchanged, so we can reuse the current contract for setup —
        //         the etch in _applyHardfork will replace it with the real v1.4 code.)
        bytes memory v13ReceiverCode = _loadFixtureBytecode(FROM_TAG, "GBridgeReceiver");
        // Some older tags don't ship GBridgeReceiver in the fixture set; if absent,
        // fall back to constructing a current instance as a stand-in.
        if (v13ReceiverCode.length == 0) {
            GBridgeReceiver tmp = new GBridgeReceiver(TRUSTED_BRIDGE, TRUSTED_SOURCE_ID);
            vm.etch(GBRIDGE_RECEIVER_ADDR, address(tmp).code);
        } else {
            vm.etch(GBRIDGE_RECEIVER_ADDR, v13ReceiverCode);
        }

        // Step 3: initialize via the v1.3 ABI. ValidatorConfig.initialize on v1.3 had
        //         the trailing parameter as `uint256 _autoEvictThreshold` (now
        //         `uint64 _autoEvictThresholdPct` in v1.4). We use a raw call so the
        //         current Solidity binding doesn't enforce the new signature.
        vm.startPrank(SystemAddresses.GENESIS);

        // StakingConfig.initialize(uint256, uint64, uint64) — unchanged across versions
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY);

        // ValidatorConfig — call v1.3 signature explicitly
        (bool ok, ) = SystemAddresses.VALIDATOR_CONFIG.call(
            abi.encodeWithSignature(
                "initialize(uint256,uint256,uint64,bool,uint64,uint256,bool,uint256)",
                MIN_BOND,
                MAX_BOND,
                UNBONDING_DELAY,
                true,
                VOTING_POWER_INCREASE_LIMIT,
                MAX_VALIDATOR_SET_SIZE,
                false,
                uint256(0)
            )
        );
        require(ok, "v1.3 ValidatorConfig.initialize failed");

        epochConfig.initialize(TWO_HOURS);
        ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG).initialize(hex"00");
        ExecutionConfig(SystemAddresses.EXECUTION_CONFIG).initialize(hex"00");
        VersionConfig(SystemAddresses.VERSION_CONFIG).initialize(1);
        governanceConfig.initialize(50, MIN_PROPOSAL_STAKE, 7 days * 1_000_000);
        RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).initialize(_createV2Config());

        uint32[] memory sourceTypes = new uint32[](1);
        sourceTypes[0] = 1;
        address[] memory callbacks = new address[](1);
        callbacks[0] = SystemAddresses.JWK_MANAGER;
        nativeOracle.initialize(sourceTypes, callbacks);
        vm.stopPrank();

        _initializeReconfigAndBlocker();
        _setInitialTimestamp();
        _fundTestAccounts();
    }

    function test_migration_validatorConfigStillInitialized() public {
        // Pre-condition: under v1.3 bytecode, isInitialized() is true
        assertTrue(validatorConfig.isInitialized(), "v1.3 should report initialized");
        uint256 minBondBefore = validatorConfig.minimumBond();
        bool autoEvictBefore = validatorConfig.autoEvictEnabled();

        // Apply Epsilon hardfork
        _applyEpsilonHardfork();

        // Post-condition: contract MUST still report initialized.
        // If the storage layout regression were unfixed, this would return false
        // because _initialized would be read from the wrong slot.
        assertTrue(validatorConfig.isInitialized(), "v1.4 must still report initialized after etch");

        // And the existing config values must round-trip
        assertEq(validatorConfig.minimumBond(), minBondBefore);
        assertEq(validatorConfig.autoEvictEnabled(), autoEvictBefore);

        // The new field that didn't exist in v1.3 reads as 0 (its slot offset was
        // unused space in v1.3 — now packed with autoEvictEnabled in slot 4)
        assertEq(validatorConfig.autoEvictThresholdPct(), 0);
    }

    function test_migration_setForNextEpochWorksPostHardfork() public {
        _applyEpsilonHardfork();

        // setForNextEpoch goes through _requireInitialized() — it would revert if
        // _initialized had drifted to slot 13. This is the most direct test of the
        // PR #63 storage-layout regression.
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND * 2, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, true, 60
        );
        assertTrue(validatorConfig.hasPendingConfig());

        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        assertEq(validatorConfig.minimumBond(), MIN_BOND * 2);
        assertEq(validatorConfig.autoEvictThresholdPct(), 60);
    }

    function test_migration_oldAutoEvictThresholdSelectorRemoved() public {
        // Pre: v1.3 exposed autoEvictThreshold()(uint256)
        (bool okBefore, ) = SystemAddresses.VALIDATOR_CONFIG.call(abi.encodeWithSignature("autoEvictThreshold()"));
        assertTrue(okBefore, "v1.3 should expose autoEvictThreshold()");

        _applyEpsilonHardfork();

        // Post: v1.4 must NOT expose it
        (bool okAfter, ) = SystemAddresses.VALIDATOR_CONFIG.call(abi.encodeWithSignature("autoEvictThreshold()"));
        assertFalse(okAfter, "v1.4 must not expose autoEvictThreshold()");
    }

    function test_migration_isProcessedSelectorRemoved() public {
        // The v1.3 GBridgeReceiver fixture exposes isProcessed(uint128). After
        // Epsilon, the selector should not be reachable.
        _applyEpsilonHardfork();

        (bool ok, ) = GBRIDGE_RECEIVER_ADDR.call(abi.encodeWithSignature("isProcessed(uint128)", uint128(1)));
        assertFalse(ok, "post-hardfork: isProcessed should not be in dispatcher");
    }

    function _applyEpsilonHardfork() internal {
        HardforkRegistry.HardforkDef memory def = HardforkRegistry.epsilon(GBRIDGE_RECEIVER_ADDR);
        _applyHardfork(def);
    }
}
