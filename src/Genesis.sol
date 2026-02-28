// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "./foundation/SystemAddresses.sol";
import { requireAllowed } from "./foundation/SystemAccessControl.sol";
import { Errors } from "./foundation/Errors.sol";

// Config Interfaces
import { ValidatorConfig } from "./runtime/ValidatorConfig.sol";
import { StakingConfig } from "./runtime/StakingConfig.sol";
import { EpochConfig } from "./runtime/EpochConfig.sol";
import { ConsensusConfig } from "./runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "./runtime/ExecutionConfig.sol";
import { GovernanceConfig } from "./runtime/GovernanceConfig.sol";
import { VersionConfig } from "./runtime/VersionConfig.sol";
import { RandomnessConfig } from "./runtime/RandomnessConfig.sol";

// System Interfaces
import { Staking } from "./staking/Staking.sol";
import { ValidatorManagement } from "./staking/ValidatorManagement.sol";
import { IValidatorManagement, GenesisValidator } from "./staking/IValidatorManagement.sol";
import { Reconfiguration } from "./blocker/Reconfiguration.sol";
import { Blocker } from "./blocker/Blocker.sol";
import { ValidatorPerformanceTracker } from "./blocker/ValidatorPerformanceTracker.sol";
import { NativeOracle } from "./oracle/NativeOracle.sol";
import { JWKManager, IJWKManager } from "./oracle/jwk/JWKManager.sol";
import { OracleTaskConfig } from "./oracle/OracleTaskConfig.sol";
import { GBridgeReceiver } from "./oracle/evm/native_token_bridge/GBridgeReceiver.sol";

/// @title Genesis
/// @author Gravity Team
/// @notice Single entry point for initializing the Gravity Chain system
/// @dev Deployed at SystemAddresses.GENESIS. Callable only once by SYSTEM_CALLER.
contract Genesis {
    // ========================================================================
    // TYPES
    // ========================================================================

    struct ValidatorConfigParams {
        uint256 minimumBond;
        uint256 maximumBond;
        uint64 unbondingDelayMicros;
        bool allowValidatorSetChange;
        uint64 votingPowerIncreaseLimitPct;
        uint256 maxValidatorSetSize;
        bool autoEvictEnabled;
        uint256 autoEvictThreshold;
    }

    struct StakingConfigParams {
        uint256 minimumStake;
        uint64 lockupDurationMicros;
        uint64 unbondingDelayMicros;
        uint256 minimumProposalStake;
    }

    struct GovernanceConfigParams {
        uint128 minVotingThreshold;
        uint256 requiredProposerStake;
        uint64 votingDurationMicros;
    }

    struct OracleTaskParams {
        uint32 sourceType;
        uint256 sourceId;
        bytes32 taskName;
        bytes config;
    }

    struct BridgeConfig {
        bool deploy;
        address trustedBridge;
        uint256 trustedSourceId;
    }

    struct OracleInitParams {
        uint32[] sourceTypes;
        address[] callbacks;
        OracleTaskParams[] tasks;
        BridgeConfig bridgeConfig;
    }

    struct JWKInitParams {
        bytes[] issuers;
        IJWKManager.RSA_JWK[][] jwks;
    }

    struct InitialValidator {
        address operator;
        address owner; // Used for owner, voter, and feeRecipient
        uint256 stakeAmount;
        string moniker;
        bytes consensusPubkey;
        bytes consensusPop;
        bytes networkAddresses;
        bytes fullnodeAddresses;
        uint256 votingPower;
    }

    struct GenesisInitParams {
        ValidatorConfigParams validatorConfig;
        StakingConfigParams stakingConfig;
        GovernanceConfigParams governanceConfig;
        uint64 epochIntervalMicros;
        uint64 majorVersion;
        bytes consensusConfig;
        bytes executionConfig;
        RandomnessConfig.RandomnessConfigData randomnessConfig;
        OracleInitParams oracleConfig;
        JWKInitParams jwkConfig;
        InitialValidator[] validators;
        /// @notice Lockup expiration timestamp for initial validator stake pools (microseconds)
        uint64 initialLockedUntilMicros;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    event GenesisCompleted(uint256 validatorCount, uint64 timestamp);

    // ========================================================================
    // STATE
    // ========================================================================

    bool private _isInitialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the entire system
    /// @dev Can only be called once by SYSTEM_CALLER (or deployer in test env)
    function initialize(
        GenesisInitParams calldata params
    ) external payable {
        // In production, this should be SYSTEM_CALLER.
        // For flexibility during deployment/testing, we allow the deployer (msg.sender)
        // if this is the first call. But standard pattern enforces access.
        // Given SystemAccessControl, we should stick to a specific allowed caller.
        // Since GENESIS calls other contracts, and those contracts check msg.sender == GENESIS,
        // THIS function's caller restriction is about who triggers genesis.
        // Typically it's the chain starter or SYSTEM_CALLER (if called via upgrade/migration).
        // We'll allow SYSTEM_CALLER.
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        if (_isInitialized) {
            revert Errors.AlreadyInitialized();
        }

        // 1. Initialize Configs
        _initializeConfigs(params);

        // 2. Initialize Oracles
        _initializeOracles(params.oracleConfig, params.jwkConfig);

        // 3. Create Stake Pools & Prepare Validator Data
        GenesisValidator[] memory genesisValidators =
            _createPoolsAndValidators(params.validators, params.initialLockedUntilMicros);

        // 4. Initialize Validator Management
        ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).initialize(genesisValidators);

        // 5. Initialize Performance Tracker (before Reconfiguration, since first epoch needs tracking)
        ValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER).initialize(params.validators.length);
        // 6. Initialize Reconfiguration
        Reconfiguration(SystemAddresses.RECONFIGURATION).initialize();

        // 7. Initialize Blocker
        Blocker(SystemAddresses.BLOCK).initialize();

        _isInitialized = true;
        emit GenesisCompleted(params.validators.length, uint64(block.timestamp));
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    function _initializeConfigs(
        GenesisInitParams calldata params
    ) internal {
        ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG)
            .initialize(
                params.validatorConfig.minimumBond,
                params.validatorConfig.maximumBond,
                params.validatorConfig.unbondingDelayMicros,
                params.validatorConfig.allowValidatorSetChange,
                params.validatorConfig.votingPowerIncreaseLimitPct,
                params.validatorConfig.maxValidatorSetSize,
                params.validatorConfig.autoEvictEnabled,
                params.validatorConfig.autoEvictThreshold
            );

        StakingConfig(SystemAddresses.STAKE_CONFIG)
            .initialize(
                params.stakingConfig.minimumStake,
                params.stakingConfig.lockupDurationMicros,
                params.stakingConfig.unbondingDelayMicros,
                params.stakingConfig.minimumProposalStake
            );

        EpochConfig(SystemAddresses.EPOCH_CONFIG).initialize(params.epochIntervalMicros);

        ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG).initialize(params.consensusConfig);

        ExecutionConfig(SystemAddresses.EXECUTION_CONFIG).initialize(params.executionConfig);

        GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG)
            .initialize(
                params.governanceConfig.minVotingThreshold,
                params.governanceConfig.requiredProposerStake,
                params.governanceConfig.votingDurationMicros
            );

        VersionConfig(SystemAddresses.VERSION_CONFIG).initialize(params.majorVersion);

        RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).initialize(params.randomnessConfig);
    }

    function _initializeOracles(
        OracleInitParams calldata oracleConfig,
        JWKInitParams calldata jwkConfig
    ) internal {
        // Collect sourceTypes and callbacks
        uint256 length = oracleConfig.sourceTypes.length;
        uint32[] memory sourceTypes;
        address[] memory callbacks;

        if (oracleConfig.bridgeConfig.deploy) {
            // Deploy GBridgeReceiver
            GBridgeReceiver receiver =
                new GBridgeReceiver(oracleConfig.bridgeConfig.trustedBridge, oracleConfig.bridgeConfig.trustedSourceId);

            // Construct new arrays with extra slot for GBridgeReceiver (sourceType=0)
            sourceTypes = new uint32[](length + 1);
            callbacks = new address[](length + 1);

            for (uint256 i = 0; i < length; i++) {
                sourceTypes[i] = oracleConfig.sourceTypes[i];
                callbacks[i] = oracleConfig.callbacks[i];
            }

            sourceTypes[length] = 0; // Blockchain Events
            callbacks[length] = address(receiver);
        } else {
            sourceTypes = oracleConfig.sourceTypes;
            callbacks = oracleConfig.callbacks;
        }

        if (sourceTypes.length > 0) {
            NativeOracle(SystemAddresses.NATIVE_ORACLE).initialize(sourceTypes, callbacks);
        }

        if (jwkConfig.issuers.length > 0) {
            JWKManager(SystemAddresses.JWK_MANAGER).initialize(jwkConfig.issuers, jwkConfig.jwks);
        }

        // Set Tasks
        for (uint256 i = 0; i < oracleConfig.tasks.length; i++) {
            OracleTaskParams calldata task = oracleConfig.tasks[i];
            OracleTaskConfig(SystemAddresses.ORACLE_TASK_CONFIG)
                .setTask(task.sourceType, task.sourceId, task.taskName, task.config);
        }
    }

    function _createPoolsAndValidators(
        InitialValidator[] calldata validators,
        uint64 initialLockedUntilMicros
    ) internal returns (GenesisValidator[] memory) {
        uint256 len = validators.length;
        GenesisValidator[] memory genesisValidators = new GenesisValidator[](len);

        for (uint256 i; i < len;) {
            InitialValidator calldata v = validators[i];

            // Create Stake Pool
            // The Genesis contract must hold enough funds to create these pools if msg.value is used.
            // OR `Genesis.initialize` must be payable and receive enough funds.
            // We transfer `v.stakeAmount` to the pool.

            // Note: Staking.createPool is payable.
            // We need to ensure we have enough value.
            // We call it with {value: v.stakeAmount}.

            address pool = Staking(SystemAddresses.STAKING).createPool{ value: v.stakeAmount }(
                v.owner, // owner
                v.owner, // staker (initially same as owner)
                v.operator, // operator
                v.owner, // voter (initially same as owner)
                initialLockedUntilMicros
            );

            // Construct GenesisValidator struct
            genesisValidators[i] = GenesisValidator({
                stakePool: pool,
                moniker: v.moniker,
                consensusPubkey: v.consensusPubkey,
                consensusPop: v.consensusPop,
                networkAddresses: v.networkAddresses,
                fullnodeAddresses: v.fullnodeAddresses,
                feeRecipient: v.owner, // Default to owner
                votingPower: v.votingPower
            });

            unchecked {
                ++i;
            }
        }

        return genesisValidators;
    }
}
