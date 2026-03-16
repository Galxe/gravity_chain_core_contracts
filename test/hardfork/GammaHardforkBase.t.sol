// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

// Runtime Configs
import { ValidatorConfig } from "../../src/runtime/ValidatorConfig.sol";
import { StakingConfig } from "../../src/runtime/StakingConfig.sol";
import { EpochConfig } from "../../src/runtime/EpochConfig.sol";
import { ConsensusConfig } from "../../src/runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "../../src/runtime/ExecutionConfig.sol";
import { GovernanceConfig } from "../../src/runtime/GovernanceConfig.sol";
import { VersionConfig } from "../../src/runtime/VersionConfig.sol";
import { RandomnessConfig } from "../../src/runtime/RandomnessConfig.sol";
import { Timestamp } from "../../src/runtime/Timestamp.sol";
import { DKG } from "../../src/runtime/DKG.sol";

// Staking
import { Staking } from "../../src/staking/Staking.sol";
import { ValidatorManagement } from "../../src/staking/ValidatorManagement.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { StakePool } from "../../src/staking/StakePool.sol";

// Blocker
import { Blocker } from "../../src/blocker/Blocker.sol";
import { Reconfiguration } from "../../src/blocker/Reconfiguration.sol";
import { ValidatorPerformanceTracker } from "../../src/blocker/ValidatorPerformanceTracker.sol";

// Oracle
import { NativeOracle } from "../../src/oracle/NativeOracle.sol";
import { JWKManager, IJWKManager } from "../../src/oracle/jwk/JWKManager.sol";
import { OracleTaskConfig } from "../../src/oracle/OracleTaskConfig.sol";

// Governance
import { Governance } from "../../src/governance/Governance.sol";

// Mocks
import { MockBlsPopVerify } from "../utils/MockBlsPopVerify.sol";

/// @title GammaHardforkBase
/// @notice Base contract providing common infrastructure for Gamma hardfork testing.
///         Sets up a running chain state (simulating v1.0.0) and provides
///         `_applyGammaHardfork()` to simulate the Reth-side bytecode replacement.
///
/// Two initialization modes:
///   1. Default (setUp): deploys NEW bytecode at all system addresses, initializes configs,
///      creates validators — then `_applyGammaHardfork()` is a no-op (for testing new features directly).
///   2. With v1.0.0 fixtures (Phase A1): loads old bytecodes from `fixtures/v1.0.0/*.bin`,
///      initializes state, then `_applyGammaHardfork()` replaces with new bytecodes.
abstract contract GammaHardforkBase is Test {
    // ========================================================================
    // CONTRACTS
    // ========================================================================

    StakingConfig public stakingConfig;
    ValidatorConfig public validatorConfig;
    Staking public staking;
    ValidatorManagement public validatorManager;
    Reconfiguration public reconfig;
    Blocker public blocker;
    Timestamp public timestamp;
    DKG public dkg;
    EpochConfig public epochConfig;
    GovernanceConfig public governanceConfig;
    NativeOracle public nativeOracle;

    // ========================================================================
    // TEST CONSTANTS
    // ========================================================================

    uint64 constant INITIAL_TIME = 1_000_000_000_000_000; // ~31 years in microseconds
    uint64 constant TWO_HOURS = 7_200_000_000; // 2 hours in microseconds
    uint64 constant ONE_HOUR = 3_600_000_000;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000;
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000;
    uint256 constant MIN_STAKE = 1 ether;
    uint256 constant MIN_BOND = 10 ether;
    uint256 constant MAX_BOND = 1000 ether;
    uint64 constant VOTING_POWER_INCREASE_LIMIT = 20;
    uint256 constant MAX_VALIDATOR_SET_SIZE = 100;
    uint256 constant MIN_PROPOSAL_STAKE = 100 ether;

    // Sample consensus key data
    bytes constant CONSENSUS_PUBKEY =
        hex"9112af1a4ef4038dfe24c5371e40b5bcfce16146bfc4ab819244ce57f5d002c4c3f06eca7273e733c0f78aada8c13deb";
    bytes constant CONSENSUS_POP = hex"abcdef1234567890";
    bytes constant NETWORK_ADDRESSES = hex"0102030405060708";
    bytes constant FULLNODE_ADDRESSES = hex"0807060504030201";
    bytes constant SAMPLE_DKG_TRANSCRIPT = hex"deadbeef1234567890abcdef";

    // ReentrancyGuard ERC-7201 namespaced storage slot
    bytes32 constant REENTRANCY_GUARD_SLOT =
        bytes32(0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00);

    // Test addresses
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");

    // Track StakePool addresses for hardfork upgrades
    address[] public stakePoolAddresses;

    // ========================================================================
    // SETUP
    // ========================================================================

    function setUp() public virtual {
        _deployAndEtchAllSystemContracts();
        _initializeAllConfigs();
        // Blocker.initialize() calls updateGlobalTime(SYSTEM_CALLER, 0) which
        // requires timestamp==0, so must be called BEFORE _setInitialTimestamp()
        _initializeReconfigAndBlocker();
        _setInitialTimestamp();
        _fundTestAccounts();
    }

    // ========================================================================
    // SYSTEM CONTRACT DEPLOYMENT
    // ========================================================================

    /// @notice Deploy and etch all system contracts at their fixed addresses
    function _deployAndEtchAllSystemContracts() internal {
        // Runtime Configs
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        validatorConfig = ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.EPOCH_CONFIG, address(new EpochConfig()).code);
        epochConfig = EpochConfig(SystemAddresses.EPOCH_CONFIG);

        vm.etch(SystemAddresses.CONSENSUS_CONFIG, address(new ConsensusConfig()).code);
        vm.etch(SystemAddresses.EXECUTION_CONFIG, address(new ExecutionConfig()).code);

        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);
        governanceConfig = GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);

        vm.etch(SystemAddresses.VERSION_CONFIG, address(new VersionConfig()).code);

        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(new RandomnessConfig()).code);

        // Staking & Validator
        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);
        validatorManager = ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);

        vm.etch(SystemAddresses.DKG, address(new DKG()).code);
        dkg = DKG(SystemAddresses.DKG);

        // Blocker
        vm.etch(SystemAddresses.RECONFIGURATION, address(new Reconfiguration()).code);
        reconfig = Reconfiguration(SystemAddresses.RECONFIGURATION);

        vm.etch(SystemAddresses.BLOCK, address(new Blocker()).code);
        blocker = Blocker(SystemAddresses.BLOCK);

        vm.etch(SystemAddresses.PERFORMANCE_TRACKER, address(new ValidatorPerformanceTracker()).code);

        // Oracle
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        nativeOracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);

        vm.etch(SystemAddresses.JWK_MANAGER, address(new JWKManager()).code);

        // Mock precompile
        vm.etch(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE, address(new MockBlsPopVerify()).code);
    }

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    function _initializeAllConfigs() internal {
        vm.startPrank(SystemAddresses.GENESIS);

        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_PROPOSAL_STAKE);
        validatorConfig.initialize(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
        );
        epochConfig.initialize(TWO_HOURS);
        ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG).initialize(hex"00");
        ExecutionConfig(SystemAddresses.EXECUTION_CONFIG).initialize(hex"00");
        VersionConfig(SystemAddresses.VERSION_CONFIG).initialize(1);
        governanceConfig.initialize(50, MIN_PROPOSAL_STAKE, 7 days * 1_000_000);
        RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).initialize(_createV2Config());

        // Initialize NativeOracle with JWK callback
        uint32[] memory sourceTypes = new uint32[](1);
        sourceTypes[0] = 1; // JWK source type
        address[] memory callbacks = new address[](1);
        callbacks[0] = SystemAddresses.JWK_MANAGER;
        nativeOracle.initialize(sourceTypes, callbacks);

        vm.stopPrank();
    }

    function _setInitialTimestamp() internal {
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIME);
    }

    function _initializeReconfigAndBlocker() internal {
        vm.startPrank(SystemAddresses.GENESIS);
        ValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER).initialize(0);
        reconfig.initialize();
        blocker.initialize();
        vm.stopPrank();
    }

    function _fundTestAccounts() internal {
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(charlie, 100_000 ether);
        vm.deal(david, 100_000 ether);
    }

    // ========================================================================
    // GAMMA HARDFORK SIMULATION
    // ========================================================================

    /// @notice Simulate the Gamma hardfork: replace all system contract bytecodes
    /// @dev Mirrors gravity-reth's `apply_gamma()` logic
    function _applyGammaHardfork() internal {
        // --- Tier 1: System contracts with fixed addresses ---
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new Reconfiguration()).code);
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        vm.etch(SystemAddresses.BLOCK, address(new Blocker()).code);
        vm.etch(SystemAddresses.PERFORMANCE_TRACKER, address(new ValidatorPerformanceTracker()).code);
        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);

        // Governance has a constructor arg — use address(1) to satisfy Ownable validation
        // Only the code is etched; storage (owner, proposals, etc.) is preserved
        vm.etch(SystemAddresses.GOVERNANCE, address(new Governance(address(1))).code);

        // --- Tier 2: StakePool instances ---
        // Deploy a fresh pool via the factory to extract the new runtime bytecode
        // (StakePool constructor has complex args and calls system contracts)
        bytes memory newPoolCode;
        if (stakePoolAddresses.length > 0) {
            uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION;
            vm.prank(david);
            address refPool = staking.createPool{ value: MIN_STAKE }(david, david, david, david, lockedUntil);
            newPoolCode = refPool.code;
        }
        for (uint256 i = 0; i < stakePoolAddresses.length; i++) {
            vm.etch(stakePoolAddresses[i], newPoolCode);
            // Initialize ReentrancyGuard slot to NOT_ENTERED (1)
            vm.store(stakePoolAddresses[i], REENTRANCY_GUARD_SLOT, bytes32(uint256(1)));
        }
    }

    /// @notice Apply Gamma with v1.0.0 fixture bytecodes loaded from disk
    /// @dev Used in Phase A1 tests — setUp loads old bytecodes, then this replaces with new
    function _applyGammaHardforkFromFixtures() internal {
        // Same as _applyGammaHardfork() — the "new" bytecodes are the currently compiled ones
        _applyGammaHardfork();
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _createV2Config() internal pure returns (RandomnessConfig.RandomnessConfigData memory) {
        uint64 half = uint64(1) << 63;
        uint64 twoThirds = uint64(((uint256(1) << 64) * 2) / 3);
        return RandomnessConfig.RandomnessConfigData({
            variant: RandomnessConfig.ConfigVariant.V2,
            configV2: RandomnessConfig.ConfigV2Data({
                secrecyThreshold: half,
                reconstructionThreshold: twoThirds,
                fastPathSecrecyThreshold: twoThirds
            })
        });
    }

    /// @notice Create a stake pool and track its address for hardfork upgrades
    function _createStakePool(address owner, uint256 stakeAmount) internal returns (address pool) {
        uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION;
        vm.prank(owner);
        pool = staking.createPool{ value: stakeAmount }(owner, owner, owner, owner, lockedUntil);
        stakePoolAddresses.push(pool);
    }

    /// @notice Create stake pool + register as validator
    function _createAndRegisterValidator(
        address owner,
        uint256 stakeAmount,
        string memory moniker
    ) internal returns (address pool) {
        pool = _createStakePool(owner, stakeAmount);
        bytes memory uniquePubkey = abi.encodePacked(pool, bytes28(keccak256(abi.encodePacked(pool))));
        vm.prank(owner);
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

    /// @notice Advance the system timestamp
    function _advanceTime(uint64 micros) internal {
        uint64 currentTime = timestamp.nowMicroseconds();
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, currentTime + micros);
    }

    /// @notice Simulate block prologue (check for epoch transition)
    function _simulateBlockPrologue() internal returns (bool epochTransitionStarted) {
        vm.prank(SystemAddresses.BLOCK);
        return reconfig.checkAndStartTransition();
    }

    /// @notice Simulate completing DKG and finishing reconfiguration
    function _simulateFinishReconfiguration(bytes memory dkgTranscript) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        reconfig.finishTransition(dkgTranscript);
    }

    /// @notice Process epoch (onNewEpoch)
    function _processEpoch() internal {
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorManager.onNewEpoch();
    }

    /// @notice Run a full epoch transition cycle
    function _completeEpochTransition() internal {
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);
    }

    /// @notice Set up a basic running chain with 2 active validators
    function _setupRunningChainWith2Validators() internal returns (address pool1, address pool2) {
        pool1 = _createRegisterAndJoin(alice, MIN_BOND, "alice");
        pool2 = _createRegisterAndJoin(bob, MIN_BOND * 2, "bob");
        _processEpoch();
    }
}
