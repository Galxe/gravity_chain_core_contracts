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
import { NativeOracle } from "./oracle/NativeOracle.sol";
import { JWKManager, IJWKManager } from "./oracle/jwk/JWKManager.sol";

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

    struct OracleInitParams {
        uint32[] sourceTypes;
        address[] callbacks;
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
        GenesisValidator[] memory genesisValidators = _createPoolsAndValidators(params.validators);

        // 4. Initialize Validator Management
        ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).initialize(genesisValidators);

        // 5. Initialize Reconfiguration
        Reconfiguration(SystemAddresses.RECONFIGURATION).initialize();

        // 6. Initialize Blocker
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
                params.validatorConfig.maxValidatorSetSize
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
        if (oracleConfig.sourceTypes.length > 0) {
            NativeOracle(SystemAddresses.NATIVE_ORACLE).initialize(oracleConfig.sourceTypes, oracleConfig.callbacks);
        }

        if (jwkConfig.issuers.length > 0) {
            JWKManager(SystemAddresses.JWK_MANAGER).initialize(jwkConfig.issuers, jwkConfig.jwks);
        }
    }

    function _createPoolsAndValidators(
        InitialValidator[] calldata validators
    ) internal returns (GenesisValidator[] memory) {
        uint256 len = validators.length;
        GenesisValidator[] memory genesisValidators = new GenesisValidator[](len);

        uint64 lockupDuration = StakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        // Initial lockedUntil implies genesis timestamp is 0 or handled by Staking contract?
        // Staking.createPool takes lockedUntil.
        // We assume genesis timestamp is effectively 0 (or whatever block.timestamp is).
        // Since we are at genesis, we should probably set lockedUntil based on current block timestamp + duration.
        // However, Blocker initializes timestamp to 0.
        // We'll use block.timestamp which should be the genesis block time.
        // Note: Blocker.initialize logic calls updateGlobalTime(0, 0).
        // But Staking.createPool uses Timestamp contract? No, it takes lockedUntil as arg.
        // We can just use a fixed offset?
        // Actually, we should probably rely on the implementation details.
        // Let's use 0 + lockupDuration for simplicity as this effectively starts from time 0.
        // Or better, query Timestamp? Timestamp is not initialized yet (Blocker init comes last).
        // So we assume genesis time is 0.
        // lockedUntil must be in the future relative to block.timestamp
        // Convert block.timestamp (seconds) to microseconds and add lockup duration
        uint64 initialLockedUntil = uint64(block.timestamp * 1_000_000) + lockupDuration;

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
                initialLockedUntil
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
