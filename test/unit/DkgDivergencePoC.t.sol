// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ValidatorManagement } from "../../src/staking/ValidatorManagement.sol";
import { IValidatorManagement } from "../../src/staking/IValidatorManagement.sol";
import { Staking } from "../../src/staking/Staking.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { StakingConfig } from "../../src/runtime/StakingConfig.sol";
import { ValidatorConfig } from "../../src/runtime/ValidatorConfig.sol";
import { Timestamp } from "../../src/runtime/Timestamp.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { ValidatorStatus, ValidatorConsensusInfo } from "../../src/foundation/Types.sol";
import { MockBlsPopVerify } from "../utils/MockBlsPopVerify.sol";

/// Minimal Reconfiguration mock: exposes isTransitionInProgress + currentEpoch only.
contract MockReconfiguration {
    uint64 public currentEpoch;
    function isTransitionInProgress() external pure returns (bool) { return false; }
    function incrementEpoch() external { currentEpoch++; }
}

/// @title DkgDivergencePoC
/// @notice PoC for gravity-audit#112 — DKG target validator set diverges from
///         the actual next-epoch validator set when a pending ValidatorConfig
///         change is queued across the reconfiguration boundary.
///
/// ──────────────────────────────────────────────────────────────────────────
/// Flow (origin/main, Reconfiguration.sol):
///   checkAndStartTransition():
///     evictUnderperformingValidators()
///     _startDkgSession():
///         targets = getNextValidatorConsensusInfos()   // STEP A — CURRENT config
///   finishTransition():
///     _applyReconfiguration():
///         ValidatorConfig.applyPendingConfig()         // config flips here
///         onNewEpoch() → _computeNextEpochValidatorSet() // STEP B — NEW config
///
/// STEP A and STEP B run the SAME pure computation with DIFFERENT inputs from
/// ValidatorConfig.  Whenever a queued pending config changes any input the
/// computation reads, the two sets diverge and the off-chain DKG key shares
/// are attributed to a committee that never runs the epoch.
/// ──────────────────────────────────────────────────────────────────────────
///
/// This file demonstrates three independent divergence vectors:
///   1. minimumBond — pending_active passes/fails the min-bond filter.
///   2. votingPowerIncreaseLimitPct — pending_active fits/exceeds the VP cap.
///   3. maximumBond — per-validator voting power cap shifts currentTotal,
///      shifting maxIncrease, indirectly flipping (2).
///
/// Related: PR #70 (this repo) proposes a one-line fix that replaces
///   getNextValidatorConsensusInfos() with getActiveValidators().  That fix
///   fails on all three vectors and introduces a new Critical: PENDING_ACTIVE
///   validators would be excluded from DKG targets, so newly-joining validators
///   activated by onNewEpoch() never receive VRF key shares.
contract DkgDivergencePoC is Test {
    ValidatorManagement public vm_;
    Staking public staking;
    StakingConfig public stakingConfig;
    ValidatorConfig public validatorConfig;
    Timestamp public ts;
    MockReconfiguration public reconfig;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dan   = makeAddr("dan");   // "victim" validator for min/max bond cases
    address eve   = makeAddr("eve");   // second victim for VP-limit case

    uint256 constant MIN_BOND_DEFAULT = 10 ether;
    uint256 constant MAX_BOND_DEFAULT = 1000 ether;
    uint64  constant UNBONDING = 7 days * 1_000_000;
    uint64  constant VP_LIMIT_DEFAULT = 50;    // max allowed by ValidatorConfig
    uint256 constant MAX_SET_SIZE = 100;

    bytes constant POP = hex"abcdef1234567890";
    bytes constant NET = hex"0102030405060708";
    bytes constant FN  = hex"0807060504030201";
    uint256 constant MIN_STAKE = 1 ether;
    uint64  constant LOCKUP = 14 days * 1_000_000;
    uint64  constant T0 = 1_000_000_000_000_000;

    function setUp() public {
        vm.etch(SystemAddresses.STAKE_CONFIG,     address(new StakingConfig()).code);
        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        vm.etch(SystemAddresses.TIMESTAMP,        address(new Timestamp()).code);
        vm.etch(SystemAddresses.STAKING,          address(new Staking()).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER,address(new ValidatorManagement()).code);
        vm.etch(SystemAddresses.RECONFIGURATION,  address(new MockReconfiguration()).code);
        vm.etch(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE, address(new MockBlsPopVerify()).code);

        stakingConfig   = StakingConfig(SystemAddresses.STAKE_CONFIG);
        validatorConfig = ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG);
        ts      = Timestamp(SystemAddresses.TIMESTAMP);
        staking = Staking(SystemAddresses.STAKING);
        vm_     = ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);
        reconfig = MockReconfiguration(SystemAddresses.RECONFIGURATION);

        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP, UNBONDING, 10 ether);
        vm.prank(SystemAddresses.GENESIS);
        validatorConfig.initialize(
            MIN_BOND_DEFAULT, MAX_BOND_DEFAULT, UNBONDING, true,
            VP_LIMIT_DEFAULT, MAX_SET_SIZE, false, 0
        );
        vm.prank(SystemAddresses.BLOCK);
        ts.updateGlobalTime(alice, T0);

        vm.deal(alice, 10_000 ether);
        vm.deal(bob,   10_000 ether);
        vm.deal(carol, 10_000 ether);
        vm.deal(dan,   10_000 ether);
        vm.deal(eve,   10_000 ether);
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    function _createPool(address owner, uint256 amount) internal returns (address pool) {
        uint64 lockedUntil = ts.nowMicroseconds() + LOCKUP;
        vm.prank(owner);
        pool = staking.createPool{ value: amount }(owner, owner, owner, owner, lockedUntil);
    }

    function _register(address owner, uint256 amount, string memory moniker) internal returns (address pool) {
        pool = _createPool(owner, amount);
        bytes memory pub = abi.encodePacked(pool, bytes28(keccak256(abi.encodePacked(pool))));
        vm.prank(owner);
        vm_.registerValidator(pool, moniker, pub, POP, NET, FN);
    }

    function _registerAndJoin(address owner, uint256 amount, string memory moniker) internal returns (address pool) {
        pool = _register(owner, amount, moniker);
        vm.prank(owner);
        vm_.joinValidatorSet(pool);
    }

    function _advanceEpoch() internal {
        vm.prank(SystemAddresses.RECONFIGURATION);
        vm_.onNewEpoch();
        reconfig.incrementEpoch();
    }

    function _contains(ValidatorConsensusInfo[] memory xs, address who) internal pure returns (bool) {
        for (uint256 i = 0; i < xs.length; i++) if (xs[i].validator == who) return true;
        return false;
    }

    /// Wraps ValidatorConfig.setForNextEpoch so individual tests only specify
    /// the parameter they want to queue.
    function _queueValidatorConfig(
        uint256 newMinBond,
        uint256 newMaxBond,
        uint64 newVpLimit
    ) internal {
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            newMinBond, newMaxBond, UNBONDING, true,
            newVpLimit, MAX_SET_SIZE, false, 0
        );
    }

    function _applyValidatorConfig() internal {
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();
    }

    // ========================================================================
    // Scenario 1 — pending minimumBond change
    // ========================================================================

    /// STEP A reads minimumBond=OLD, dan (stake=50) passes.
    /// STEP B reads minimumBond=NEW, dan fails and is reverted to INACTIVE.
    /// Divergence: dan in DKG target, not in actual epoch set.
    function test_CONFIRMED_divergence_via_minimumBond() public {
        _registerAndJoin(alice, 100 ether, "alice");
        _registerAndJoin(bob,   100 ether, "bob");
        _registerAndJoin(carol, 100 ether, "carol");
        _advanceEpoch();

        address pD = _registerAndJoin(dan, 50 ether, "dan");

        // Queue: minimumBond 10 → 60. dan (50) no longer qualifies.
        _queueValidatorConfig(60 ether, MAX_BOND_DEFAULT, VP_LIMIT_DEFAULT);

        // STEP A — what _startDkgSession reads.
        ValidatorConsensusInfo[] memory dkgTargets = vm_.getNextValidatorConsensusInfos();
        assertTrue(_contains(dkgTargets, pD), "STEP A: dan in DKG target (OLD minBond=10)");
        assertEq(dkgTargets.length, 4, "STEP A: 4 validators targeted");

        // STEP B — what _applyReconfiguration commits.
        _applyValidatorConfig();
        _advanceEpoch();
        ValidatorConsensusInfo[] memory actualSet = vm_.getActiveValidators();

        assertFalse(_contains(actualSet, pD), "STEP B: dan NOT in actual set (NEW minBond=60)");
        assertEq(uint8(vm_.getValidator(pD).status), uint8(ValidatorStatus.INACTIVE), "dan reverted INACTIVE");
        assertTrue(dkgTargets.length != actualSet.length, "DKG target and actual epoch set diverged");
    }

    // ========================================================================
    // Scenario 2 — pending votingPowerIncreaseLimitPct change
    // ========================================================================

    /// Governance tightens the VP increase limit AFTER DKG target is computed.
    /// STEP A reads limit=HIGH, both dan and eve (each 30 ETH) fit under the
    /// allowed increase (100 * HIGH%).
    /// STEP B reads limit=LOW, only dan fits; eve is moved to toKeepPending
    /// and stays in PENDING_ACTIVE rather than activating.
    /// Divergence: eve in DKG target, not in actual epoch set.
    function test_CONFIRMED_divergence_via_votingPowerIncreaseLimitPct() public {
        // Current active total = 300 ETH (alice+bob+carol).
        _registerAndJoin(alice, 100 ether, "alice");
        _registerAndJoin(bob,   100 ether, "bob");
        _registerAndJoin(carol, 100 ether, "carol");
        _advanceEpoch();

        address pD = _registerAndJoin(dan, 30 ether, "dan");
        address pE = _registerAndJoin(eve, 30 ether, "eve");

        // Start permissive: VP_LIMIT_HIGH lets both dan+eve in.
        //   maxIncrease_high = 300 * 50% = 150 → 30 + 30 = 60 < 150 ✓
        // Queue: VP_LIMIT_LOW = 10 → maxIncrease_low = 30 → only first fits.
        uint64 VP_LOW = 10;
        _queueValidatorConfig(MIN_BOND_DEFAULT, MAX_BOND_DEFAULT, VP_LOW);

        // STEP A — HIGH limit still active.
        ValidatorConsensusInfo[] memory dkgTargets = vm_.getNextValidatorConsensusInfos();
        assertTrue(_contains(dkgTargets, pD), "STEP A: dan in DKG target");
        assertTrue(_contains(dkgTargets, pE), "STEP A: eve in DKG target");
        assertEq(dkgTargets.length, 5, "STEP A: 5 validators targeted");

        // STEP B — LOW limit now active; only one of dan/eve fits.
        _applyValidatorConfig();
        _advanceEpoch();
        ValidatorConsensusInfo[] memory actualSet = vm_.getActiveValidators();

        assertEq(actualSet.length, 4, "STEP B: only 4 validators activated");
        bool danActive = _contains(actualSet, pD);
        bool eveActive = _contains(actualSet, pE);
        assertTrue(danActive != eveActive, "STEP B: exactly one of dan/eve activates");

        // Whichever of dan/eve was held in pending got DKG key shares but no seat.
        address ghost = danActive ? pE : pD;
        assertFalse(_contains(actualSet, ghost), "ghost validator not in actual set");
        assertTrue(_contains(dkgTargets, ghost), "ghost validator WAS in DKG target");
        assertEq(
            uint8(vm_.getValidator(ghost).status),
            uint8(ValidatorStatus.PENDING_ACTIVE),
            "ghost left in PENDING_ACTIVE by toKeepPending"
        );
    }

    // ========================================================================
    // Scenario 3 — pending maximumBond change
    // ========================================================================

    /// maximumBond caps each validator's voting power inside
    /// _getValidatorVotingPower().  Lowering it before DKG but not applying
    /// until onNewEpoch():
    ///   - shrinks currentTotal at STEP B relative to STEP A
    ///   - shrinks maxIncrease at STEP B
    ///   - changes which pending_active fit
    /// Concretely: three founders stake way above the new cap; dan's 60 ETH
    /// pending stake fits under STEP A's maxIncrease but not under STEP B's.
    function test_CONFIRMED_divergence_via_maximumBond() public {
        // Founders each stake 1000 ETH → currentTotal_A = 3000 ETH (capped by MAX_BOND_DEFAULT=1000).
        _registerAndJoin(alice, 1000 ether, "alice");
        _registerAndJoin(bob,   1000 ether, "bob");
        _registerAndJoin(carol, 1000 ether, "carol");
        _advanceEpoch();

        // dan joins with 60 ETH pending.
        address pD = _registerAndJoin(dan, 60 ether, "dan");

        // Tighten VP_LIMIT so the cap boundary matters (5% of total).
        // Queue: lower maximumBond 1000 → 100 AND limitPct 50 → 5.
        //   STEP A caps: currentTotal_A = 3000, limit 50% → maxIncrease_A = 1500 → dan (60) fits trivially.
        //   STEP B caps: currentTotal_B = min(power,100)*3 = 300, limit 5% → maxIncrease_B = 15
        //                dan (60) no longer fits.
        uint64  VP_LOW    = 5;
        uint256 NEW_MAX_BOND = 100 ether;
        _queueValidatorConfig(MIN_BOND_DEFAULT, NEW_MAX_BOND, VP_LOW);

        // STEP A — old maximumBond and old limit.
        ValidatorConsensusInfo[] memory dkgTargets = vm_.getNextValidatorConsensusInfos();
        assertTrue(_contains(dkgTargets, pD), "STEP A: dan in DKG target");
        assertEq(dkgTargets.length, 4, "STEP A: 4 validators targeted");

        // STEP B — new maximumBond compresses currentTotal, new limit shrinks maxIncrease.
        _applyValidatorConfig();
        _advanceEpoch();
        ValidatorConsensusInfo[] memory actualSet = vm_.getActiveValidators();

        assertFalse(_contains(actualSet, pD), "STEP B: dan NOT in actual set");
        assertEq(
            uint8(vm_.getValidator(pD).status),
            uint8(ValidatorStatus.PENDING_ACTIVE),
            "dan kept PENDING_ACTIVE by toKeepPending"
        );
        assertTrue(dkgTargets.length != actualSet.length, "DKG target and actual epoch set diverged");
    }
}
