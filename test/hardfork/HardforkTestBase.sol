// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";
import { HardforkRegistry } from "./HardforkRegistry.sol";

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
import { JWKManager } from "../../src/oracle/jwk/JWKManager.sol";

// Governance
import { Governance } from "../../src/governance/Governance.sol";

// Mocks
import { MockBlsPopVerify } from "../utils/MockBlsPopVerify.sol";

/// @title HardforkTestBase
/// @notice Generic, reusable base for all hardfork testing.
///         Provides:
///         - Fixture loading from test/hardfork/fixtures/<tag>/*.hex via vm.readFile
///         - Generic hardfork application driven by HardforkRegistry definitions
///         - Storage snapshot/diff verification
///         - Common chain state setup helpers (configs, validators, epochs)
///
///         For a new hardfork:
///         1. Add definition in HardforkRegistry.sol
///         2. `make extract-fixtures TAG=<from-tag>`
///         3. Create test contracts extending this base
abstract contract HardforkTestBase is Test {
    // ========================================================================
    // TYPED CONTRACT REFERENCES
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
    // CONSTANTS
    // ========================================================================

    uint64 constant INITIAL_TIME = 1_000_000_000_000_000;
    uint64 constant TWO_HOURS = 7_200_000_000;
    uint64 constant ONE_HOUR = 3_600_000_000;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000;
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000;
    uint256 constant MIN_STAKE = 1 ether;
    uint256 constant MIN_BOND = 10 ether;
    uint256 constant MAX_BOND = 1000 ether;
    uint64 constant VOTING_POWER_INCREASE_LIMIT = 20;
    uint256 constant MAX_VALIDATOR_SET_SIZE = 100;
    uint256 constant MIN_PROPOSAL_STAKE = 100 ether;

    bytes constant CONSENSUS_POP = hex"abcdef1234567890";
    bytes constant NETWORK_ADDRESSES = hex"0102030405060708";
    bytes constant FULLNODE_ADDRESSES = hex"0807060504030201";
    bytes constant SAMPLE_DKG_TRANSCRIPT = hex"deadbeef1234567890abcdef";

    string constant FIXTURE_BASE_DIR = "test/hardfork/fixtures/";

    // Test addresses
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");

    // Track StakePool addresses for hardfork upgrades
    address[] public stakePoolAddresses;

    // Storage snapshot for pre/post comparison
    mapping(address => mapping(bytes32 => bytes32)) internal _storageSnapshot;
    address[] internal _snapshotAddresses;
    bytes32[][] internal _snapshotSlots;

    // ========================================================================
    // FIXTURE LOADING
    // ========================================================================

    /// @notice Load runtime bytecode from a fixture hex file
    /// @param tag Git tag name (e.g., "gravity-testnet-v1.0.0")
    /// @param contractName Contract name (e.g., "StakingConfig")
    function _loadFixtureBytecode(string memory tag, string memory contractName) internal view returns (bytes memory) {
        string memory path = string.concat(FIXTURE_BASE_DIR, tag, "/", contractName, ".hex");
        string memory hexStr = vm.readFile(path);
        return vm.parseBytes(hexStr);
    }

    /// @notice Deploy all system contracts using fixture bytecodes from a specific tag
    function _deployFromFixtures(string memory tag) internal {
        // All contracts that have fixture bytecodes
        string[19] memory contracts = [
            "StakingConfig", "ValidatorConfig", "Staking", "ValidatorManagement",
            "Reconfiguration", "NativeOracle", "Blocker", "ValidatorPerformanceTracker",
            "GovernanceConfig", "Governance", "StakePool", "EpochConfig",
            "ConsensusConfig", "ExecutionConfig", "VersionConfig", "RandomnessConfig",
            "Timestamp", "DKG", "JWKManager"
        ];
        address[19] memory addrs = [
            SystemAddresses.STAKE_CONFIG, SystemAddresses.VALIDATOR_CONFIG,
            SystemAddresses.STAKING, SystemAddresses.VALIDATOR_MANAGER,
            SystemAddresses.RECONFIGURATION, SystemAddresses.NATIVE_ORACLE,
            SystemAddresses.BLOCK, SystemAddresses.PERFORMANCE_TRACKER,
            SystemAddresses.GOVERNANCE_CONFIG, SystemAddresses.GOVERNANCE,
            address(0), // StakePool — not a system address, skip
            SystemAddresses.EPOCH_CONFIG, SystemAddresses.CONSENSUS_CONFIG,
            SystemAddresses.EXECUTION_CONFIG, SystemAddresses.VERSION_CONFIG,
            SystemAddresses.RANDOMNESS_CONFIG, SystemAddresses.TIMESTAMP,
            SystemAddresses.DKG, SystemAddresses.JWK_MANAGER
        ];

        for (uint256 i = 0; i < contracts.length; i++) {
            if (addrs[i] == address(0)) continue; // skip StakePool
            vm.etch(addrs[i], _loadFixtureBytecode(tag, contracts[i]));
        }

        // Mock BLS precompile
        vm.etch(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE, address(new MockBlsPopVerify()).code);

        _bindContractReferences();
    }

    /// @notice Deploy all system contracts using currently compiled (new) bytecodes
    function _deployFromCurrentBytecodes() internal {
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        vm.etch(SystemAddresses.EPOCH_CONFIG, address(new EpochConfig()).code);
        vm.etch(SystemAddresses.CONSENSUS_CONFIG, address(new ConsensusConfig()).code);
        vm.etch(SystemAddresses.EXECUTION_CONFIG, address(new ExecutionConfig()).code);
        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);
        vm.etch(SystemAddresses.VERSION_CONFIG, address(new VersionConfig()).code);
        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(new RandomnessConfig()).code);
        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);
        vm.etch(SystemAddresses.DKG, address(new DKG()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new Reconfiguration()).code);
        vm.etch(SystemAddresses.BLOCK, address(new Blocker()).code);
        vm.etch(SystemAddresses.PERFORMANCE_TRACKER, address(new ValidatorPerformanceTracker()).code);
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        vm.etch(SystemAddresses.JWK_MANAGER, address(new JWKManager()).code);
        vm.etch(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE, address(new MockBlsPopVerify()).code);

        _bindContractReferences();
    }

    /// @notice Bind typed Solidity references to system addresses
    function _bindContractReferences() internal {
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);
        validatorConfig = ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);
        epochConfig = EpochConfig(SystemAddresses.EPOCH_CONFIG);
        governanceConfig = GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);
        staking = Staking(SystemAddresses.STAKING);
        validatorManager = ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);
        dkg = DKG(SystemAddresses.DKG);
        reconfig = Reconfiguration(SystemAddresses.RECONFIGURATION);
        blocker = Blocker(SystemAddresses.BLOCK);
        nativeOracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
    }

    // ========================================================================
    // HARDFORK APPLICATION (Registry-driven)
    // ========================================================================

    /// @notice Apply a hardfork using a registry definition
    /// @dev Replaces bytecodes for all contracts in the definition, then applies post-actions
    function _applyHardfork(HardforkRegistry.HardforkDef memory def) internal {
        // --- Tier 1: System contracts ---
        for (uint256 i = 0; i < def.upgrades.length; i++) {
            bytes memory newCode = _compileNewBytecode(def.upgrades[i].name);
            vm.etch(def.upgrades[i].addr, newCode);
        }

        // --- Tier 2: StakePool instances (upgrade via factory reference deploy) ---
        if (stakePoolAddresses.length > 0) {
            uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION;
            vm.prank(david);
            address refPool = staking.createPool{ value: MIN_STAKE }(david, david, david, david, lockedUntil);
            bytes memory newPoolCode = refPool.code;

            for (uint256 i = 0; i < stakePoolAddresses.length; i++) {
                vm.etch(stakePoolAddresses[i], newPoolCode);
            }
        }

        // --- Tier 3: Post-actions (storage patches) ---
        for (uint256 i = 0; i < def.postActions.length; i++) {
            HardforkRegistry.PostAction memory action = def.postActions[i];
            if (action.isDynamic) {
                // Apply to all tracked StakePool instances
                for (uint256 j = 0; j < stakePoolAddresses.length; j++) {
                    vm.store(stakePoolAddresses[j], action.slot, action.value);
                }
            } else {
                vm.store(action.target, action.slot, action.value);
            }
        }
    }

    /// @notice Compile current bytecode for a contract by name
    function _compileNewBytecode(string memory name) internal returns (bytes memory) {
        // Use keccak to dispatch — Solidity can't switch on strings
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("StakingConfig")) return address(new StakingConfig()).code;
        if (h == keccak256("ValidatorConfig")) return address(new ValidatorConfig()).code;
        if (h == keccak256("ValidatorManagement")) return address(new ValidatorManagement()).code;
        if (h == keccak256("Reconfiguration")) return address(new Reconfiguration()).code;
        if (h == keccak256("NativeOracle")) return address(new NativeOracle()).code;
        if (h == keccak256("Staking")) return address(new Staking()).code;
        if (h == keccak256("Blocker")) return address(new Blocker()).code;
        if (h == keccak256("ValidatorPerformanceTracker")) return address(new ValidatorPerformanceTracker()).code;
        if (h == keccak256("GovernanceConfig")) return address(new GovernanceConfig()).code;
        if (h == keccak256("Governance")) return address(new Governance(address(1))).code;
        revert(string.concat("Unknown contract: ", name));
    }

    // ========================================================================
    // STORAGE SNAPSHOT & VERIFICATION
    // ========================================================================

    /// @notice Snapshot storage values at specific slots for later comparison
    function _snapshotStorage(address addr, bytes32[] memory slots) internal {
        _snapshotAddresses.push(addr);
        _snapshotSlots.push(slots);
        for (uint256 i = 0; i < slots.length; i++) {
            _storageSnapshot[addr][slots[i]] = vm.load(addr, slots[i]);
        }
    }

    /// @notice Verify that all snapshotted storage values are preserved
    function _verifyStoragePreserved() internal view {
        for (uint256 i = 0; i < _snapshotAddresses.length; i++) {
            address addr = _snapshotAddresses[i];
            bytes32[] memory slots = _snapshotSlots[i];
            for (uint256 j = 0; j < slots.length; j++) {
                bytes32 before = _storageSnapshot[addr][slots[j]];
                bytes32 after_ = vm.load(addr, slots[j]);
                assertEq(after_, before, string.concat(
                    "Storage changed at ", vm.toString(addr),
                    " slot ", vm.toString(slots[j])
                ));
            }
        }
    }

    // ========================================================================
    // CHAIN INITIALIZATION HELPERS
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

        uint32[] memory sourceTypes = new uint32[](1);
        sourceTypes[0] = 1;
        address[] memory callbacks = new address[](1);
        callbacks[0] = SystemAddresses.JWK_MANAGER;
        nativeOracle.initialize(sourceTypes, callbacks);
        vm.stopPrank();
    }

    function _initializeReconfigAndBlocker() internal {
        vm.startPrank(SystemAddresses.GENESIS);
        ValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER).initialize(0);
        reconfig.initialize();
        blocker.initialize();
        vm.stopPrank();
    }

    function _setInitialTimestamp() internal {
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIME);
    }

    function _fundTestAccounts() internal {
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(charlie, 100_000 ether);
        vm.deal(david, 100_000 ether);
    }

    // ========================================================================
    // VALIDATOR & STAKING HELPERS
    // ========================================================================

    function _createStakePool(address owner, uint256 stakeAmount) internal returns (address pool) {
        uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION;
        vm.prank(owner);
        pool = staking.createPool{ value: stakeAmount }(owner, owner, owner, owner, lockedUntil);
        stakePoolAddresses.push(pool);
    }

    function _createAndRegisterValidator(
        address owner, uint256 stakeAmount, string memory moniker
    ) internal returns (address pool) {
        pool = _createStakePool(owner, stakeAmount);
        bytes memory uniquePubkey = abi.encodePacked(pool, bytes28(keccak256(abi.encodePacked(pool))));
        vm.prank(owner);
        validatorManager.registerValidator(
            pool, moniker, uniquePubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function _createRegisterAndJoin(
        address owner, uint256 stakeAmount, string memory moniker
    ) internal returns (address pool) {
        pool = _createAndRegisterValidator(owner, stakeAmount, moniker);
        vm.prank(owner);
        validatorManager.joinValidatorSet(pool);
    }

    // ========================================================================
    // TIME & EPOCH HELPERS
    // ========================================================================

    function _advanceTime(uint64 micros) internal {
        uint64 currentTime = timestamp.nowMicroseconds();
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, currentTime + micros);
    }

    function _simulateBlockPrologue() internal returns (bool) {
        vm.prank(SystemAddresses.BLOCK);
        return reconfig.checkAndStartTransition();
    }

    function _simulateFinishReconfiguration(bytes memory dkgTranscript) internal {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        reconfig.finishTransition(dkgTranscript);
    }

    function _processEpoch() internal {
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorManager.onNewEpoch();
    }

    function _completeEpochTransition() internal {
        _advanceTime(TWO_HOURS + 1);
        _simulateBlockPrologue();
        _simulateFinishReconfiguration(SAMPLE_DKG_TRANSCRIPT);
    }

    // ========================================================================
    // INTERNAL HELPERS
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
}
