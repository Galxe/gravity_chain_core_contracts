use alloy_sol_macro::sol;
use alloy_sol_types::SolCall;
use revm_primitives::{hex, Address, Bytes, ExecutionResult, TxEnv, U256};
use serde::{Deserialize, Serialize};
use tracing::{error, info};

use crate::{
    post_genesis::handle_execution_result,
    utils::{
        new_system_call_txn, new_system_call_txn_with_value, GENESIS_ADDR, VALIDATOR_MANAGER_ADDR,
    },
};

/// Derive 32-byte AccountAddress from BLS consensus public key using SHA3-256
/// This matches the derivation used in gravity-reth for validator identity
fn derive_account_address_from_consensus_pubkey(consensus_pubkey: &[u8]) -> [u8; 32] {
    use tiny_keccak::{Hasher, Sha3};

    let mut hasher = Sha3::v256();
    hasher.update(consensus_pubkey);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

// ============================================================================
// JSON CONFIG STRUCTURES - Matching new Genesis.sol GenesisInitParams
// ============================================================================

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct GenesisConfig {
    /// Chain ID for the network (default: 1 = Mainnet)
    #[serde(rename = "chainId", default = "default_chain_id")]
    pub chain_id: u64,

    #[serde(rename = "validatorConfig")]
    pub validator_config: ValidatorConfigParams,

    #[serde(rename = "stakingConfig")]
    pub staking_config: StakingConfigParams,

    #[serde(rename = "governanceConfig")]
    pub governance_config: GovernanceConfigParams,

    #[serde(rename = "epochIntervalMicros")]
    pub epoch_interval_micros: u64,

    #[serde(rename = "majorVersion")]
    pub major_version: u64,

    #[serde(rename = "consensusConfig")]
    pub consensus_config: String, // hex bytes

    #[serde(rename = "executionConfig")]
    pub execution_config: String, // hex bytes

    #[serde(rename = "randomnessConfig")]
    pub randomness_config: RandomnessConfigData,

    #[serde(rename = "oracleConfig")]
    pub oracle_config: OracleInitParams,

    #[serde(rename = "jwkConfig")]
    pub jwk_config: JWKInitParams,

    pub validators: Vec<InitialValidator>,
}

fn default_chain_id() -> u64 {
    1337
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ValidatorConfigParams {
    #[serde(rename = "minimumBond")]
    pub minimum_bond: String,

    #[serde(rename = "maximumBond")]
    pub maximum_bond: String,

    #[serde(rename = "unbondingDelayMicros")]
    pub unbonding_delay_micros: u64,

    #[serde(rename = "allowValidatorSetChange")]
    pub allow_validator_set_change: bool,

    #[serde(rename = "votingPowerIncreaseLimitPct")]
    pub voting_power_increase_limit_pct: u64,

    #[serde(rename = "maxValidatorSetSize")]
    pub max_validator_set_size: String,

    #[serde(rename = "autoEvictEnabled", default)]
    pub auto_evict_enabled: bool,

    #[serde(rename = "autoEvictThreshold", default)]
    pub auto_evict_threshold: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct StakingConfigParams {
    #[serde(rename = "minimumStake")]
    pub minimum_stake: String,

    #[serde(rename = "lockupDurationMicros")]
    pub lockup_duration_micros: u64,

    #[serde(rename = "unbondingDelayMicros")]
    pub unbonding_delay_micros: u64,

    #[serde(rename = "minimumProposalStake")]
    pub minimum_proposal_stake: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct GovernanceConfigParams {
    #[serde(rename = "minVotingThreshold")]
    pub min_voting_threshold: String,

    #[serde(rename = "requiredProposerStake")]
    pub required_proposer_stake: String,

    #[serde(rename = "votingDurationMicros")]
    pub voting_duration_micros: u64,

    #[serde(rename = "executionDelayMicros")]
    pub execution_delay_micros: u64,

    #[serde(rename = "executionWindowMicros")]
    pub execution_window_micros: u64,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RandomnessConfigData {
    pub variant: u8, // 0 = Off, 1 = V2

    #[serde(rename = "configV2")]
    pub config_v2: ConfigV2Data,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ConfigV2Data {
    #[serde(rename = "secrecyThreshold")]
    pub secrecy_threshold: u128,

    #[serde(rename = "reconstructionThreshold")]
    pub reconstruction_threshold: u128,

    #[serde(rename = "fastPathSecrecyThreshold")]
    pub fast_path_secrecy_threshold: u128,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct OracleInitParams {
    #[serde(rename = "sourceTypes")]
    pub source_types: Vec<u32>,

    pub callbacks: Vec<String>, // addresses as hex strings

    #[serde(default)]
    pub tasks: Vec<OracleTaskParams>,

    #[serde(rename = "bridgeConfig", default)]
    pub bridge_config: BridgeConfig,
}

#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct OracleTaskParams {
    #[serde(rename = "sourceType")]
    pub source_type: u32,

    #[serde(rename = "sourceId")]
    pub source_id: u64,

    #[serde(rename = "taskName")]
    pub task_name: String, // string, will be hashed or passed as bytes32? User said bytes32.
    // But JSON config usually has strings.
    // Genesis.sol expects bytes32.
    // We should probably accept a string and keccak256 it?
    // Or string and 0-pad?
    // User instructions: "OracleTaskConfig.setTask(..., bytes32 taskName, ...)"
    // jwk_consensus_config used keccak256("events").
    // Implementation plan said: "URI...".
    // Let's assume input is string. If it starts with "0x", parse as bytes32.
    // Otherwise keccak256 it?
    // Actually, `uri_parser` said `task_type` defaults to "events".
    // So `keccak256("events")` is likely.
    pub config: String, // The URI string
}

#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct BridgeConfig {
    pub deploy: bool,

    #[serde(rename = "trustedBridge")]
    pub trusted_bridge: String, // address

    #[serde(rename = "trustedSourceId", default)]
    pub trusted_source_id: u64,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct JWKInitParams {
    pub issuers: Vec<String>, // hex-encoded bytes
    pub jwks: Vec<Vec<RSA_JWK_Json>>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RSA_JWK_Json {
    pub kid: String,
    pub kty: String,
    pub alg: String,
    pub e: String,
    pub n: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct InitialValidator {
    pub operator: String,
    pub owner: String,

    #[serde(rename = "stakeAmount")]
    pub stake_amount: String,

    pub moniker: String,

    #[serde(rename = "consensusPubkey")]
    pub consensus_pubkey: String, // hex bytes

    #[serde(rename = "consensusPop")]
    pub consensus_pop: String, // hex bytes

    #[serde(rename = "networkAddresses")]
    pub network_addresses: String, // human-readable format: /ip4/127.0.0.1/tcp/2024/noise-ik/.../handshake/0

    #[serde(rename = "fullnodeAddresses")]
    pub fullnode_addresses: String, // human-readable format: /ip4/127.0.0.1/tcp/2024/noise-ik/.../handshake/0

    #[serde(rename = "votingPower")]
    pub voting_power: String,
}

// ============================================================================
// SOLIDITY ABI DEFINITIONS - Matching new Genesis.sol
// ============================================================================

sol! {
    struct SolValidatorConfigParams {
        uint256 minimumBond;
        uint256 maximumBond;
        uint64 unbondingDelayMicros;
        bool allowValidatorSetChange;
        uint64 votingPowerIncreaseLimitPct;
        uint256 maxValidatorSetSize;
        bool autoEvictEnabled;
        uint256 autoEvictThreshold;
    }

    struct SolStakingConfigParams {
        uint256 minimumStake;
        uint64 lockupDurationMicros;
        uint64 unbondingDelayMicros;
        uint256 minimumProposalStake;
    }

    struct SolGovernanceConfigParams {
        uint128 minVotingThreshold;
        uint256 requiredProposerStake;
        uint64 votingDurationMicros;
        uint64 executionDelayMicros;
        uint64 executionWindowMicros;
    }

    struct SolConfigV2Data {
        uint128 secrecyThreshold;
        uint128 reconstructionThreshold;
        uint128 fastPathSecrecyThreshold;
    }

    struct SolRandomnessConfigData {
        uint8 variant;
        SolConfigV2Data configV2;
    }

    struct SolOracleTaskParams {
        uint32 sourceType;
        uint256 sourceId;
        bytes32 taskName;
        bytes config;
    }

    struct SolBridgeConfig {
        bool deploy;
        address trustedBridge;
        uint256 trustedSourceId;
    }

    struct SolOracleInitParams {
        uint32[] sourceTypes;
        address[] callbacks;
        SolOracleTaskParams[] tasks;
        SolBridgeConfig bridgeConfig;
    }

    struct SolRSA_JWK {
        string kid;
        string kty;
        string alg;
        string e;
        string n;
    }

    struct SolJWKInitParams {
        bytes[] issuers;
        SolRSA_JWK[][] jwks;
    }

    struct SolInitialValidator {
        address operator;
        address owner;
        uint256 stakeAmount;
        string moniker;
        bytes consensusPubkey;
        bytes consensusPop;
        bytes networkAddresses;
        bytes fullnodeAddresses;
        uint256 votingPower;
    }

    struct SolGenesisInitParams {
        SolValidatorConfigParams validatorConfig;
        SolStakingConfigParams stakingConfig;
        SolGovernanceConfigParams governanceConfig;
        uint64 epochIntervalMicros;
        uint64 majorVersion;
        bytes consensusConfig;
        bytes executionConfig;
        SolRandomnessConfigData randomnessConfig;
        SolOracleInitParams oracleConfig;
        SolJWKInitParams jwkConfig;
        SolInitialValidator[] validators;
    }

    contract Genesis {
        function initialize(SolGenesisInitParams calldata params) external payable;
    }
}

// ============================================================================
// CONVERSION FUNCTIONS
// ============================================================================

fn parse_u256(s: &str) -> U256 {
    s.parse::<U256>()
        .expect(&format!("Invalid U256 string: {}", s))
}

fn parse_u128(s: &str) -> u128 {
    s.parse::<u128>()
        .expect(&format!("Invalid u128 string: {}", s))
}

fn parse_address(s: &str) -> Address {
    s.parse::<Address>()
        .expect(&format!("Invalid address: {}", s))
}

fn parse_hex_bytes(s: &str) -> Vec<u8> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    if s.is_empty() {
        return Vec::new();
    }
    hex::decode(s).expect(&format!("Invalid hex string: {}", s))
}

/// BCS encode a string (for network addresses)
/// BCS string encoding: length prefix (uleb128) + UTF-8 bytes
fn bcs_encode_string(s: &str) -> Vec<u8> {
    bcs::to_bytes(s).expect(&format!("Failed to BCS encode string: {}", s))
}

pub fn convert_config_to_sol(config: &GenesisConfig) -> SolGenesisInitParams {
    // Convert ValidatorConfig
    let validator_config = SolValidatorConfigParams {
        minimumBond: parse_u256(&config.validator_config.minimum_bond),
        maximumBond: parse_u256(&config.validator_config.maximum_bond),
        unbondingDelayMicros: config.validator_config.unbonding_delay_micros,
        allowValidatorSetChange: config.validator_config.allow_validator_set_change,
        votingPowerIncreaseLimitPct: config.validator_config.voting_power_increase_limit_pct,
        maxValidatorSetSize: parse_u256(&config.validator_config.max_validator_set_size),
        autoEvictEnabled: config.validator_config.auto_evict_enabled,
        autoEvictThreshold: if config.validator_config.auto_evict_threshold.is_empty() {
            U256::ZERO
        } else {
            parse_u256(&config.validator_config.auto_evict_threshold)
        },
    };

    // Convert StakingConfig
    let staking_config = SolStakingConfigParams {
        minimumStake: parse_u256(&config.staking_config.minimum_stake),
        lockupDurationMicros: config.staking_config.lockup_duration_micros,
        unbondingDelayMicros: config.staking_config.unbonding_delay_micros,
        minimumProposalStake: parse_u256(&config.staking_config.minimum_proposal_stake),
    };

    // Convert GovernanceConfig
    let governance_config = SolGovernanceConfigParams {
        minVotingThreshold: parse_u128(&config.governance_config.min_voting_threshold),
        requiredProposerStake: parse_u256(&config.governance_config.required_proposer_stake),
        votingDurationMicros: config.governance_config.voting_duration_micros,
        executionDelayMicros: config.governance_config.execution_delay_micros,
        executionWindowMicros: config.governance_config.execution_window_micros,
    };

    // Convert RandomnessConfig
    let randomness_config = SolRandomnessConfigData {
        variant: config.randomness_config.variant,
        configV2: SolConfigV2Data {
            secrecyThreshold: config.randomness_config.config_v2.secrecy_threshold,
            reconstructionThreshold: config.randomness_config.config_v2.reconstruction_threshold,
            fastPathSecrecyThreshold: config
                .randomness_config
                .config_v2
                .fast_path_secrecy_threshold,
        },
    };

    // Convert OracleConfig
    let oracle_config = SolOracleInitParams {
        sourceTypes: config.oracle_config.source_types.clone(),
        callbacks: config
            .oracle_config
            .callbacks
            .iter()
            .map(|s| parse_address(s))
            .collect(),
        tasks: config
            .oracle_config
            .tasks
            .iter()
            .map(|t| {
                // Handle taskName: if it starts with 0x, parse as bytes32, else keccak256 hash of string
                let task_name_bytes = if t.task_name.starts_with("0x") {
                    let s = t.task_name.strip_prefix("0x").unwrap();
                    let bytes = hex::decode(s).expect("Invalid hex for taskName");
                    let mut b32 = [0u8; 32];
                    if bytes.len() > 32 {
                        panic!("taskName hex too long");
                    }
                    b32[..bytes.len()].copy_from_slice(&bytes);
                    b32
                } else {
                    use tiny_keccak::{Hasher, Keccak};
                    let mut hasher = Keccak::v256();
                    let mut output = [0u8; 32];
                    hasher.update(t.task_name.as_bytes());
                    hasher.finalize(&mut output);
                    output
                };

                SolOracleTaskParams {
                    sourceType: t.source_type,
                    sourceId: U256::from(t.source_id),
                    taskName: task_name_bytes.into(),
                    config: t.config.as_bytes().to_vec().into(), // encode string as bytes
                }
            })
            .collect(),
        bridgeConfig: SolBridgeConfig {
            deploy: config.oracle_config.bridge_config.deploy,
            trustedBridge: if config.oracle_config.bridge_config.trusted_bridge.is_empty() {
                Address::ZERO
            } else {
                parse_address(&config.oracle_config.bridge_config.trusted_bridge)
            },
            trustedSourceId: U256::from(config.oracle_config.bridge_config.trusted_source_id),
        },
    };

    // Convert JWKConfig
    let jwk_config = SolJWKInitParams {
        issuers: config
            .jwk_config
            .issuers
            .iter()
            .map(|s| parse_hex_bytes(s).into())
            .collect(),
        jwks: config
            .jwk_config
            .jwks
            .iter()
            .map(|provider_jwks| {
                provider_jwks
                    .iter()
                    .map(|jwk| SolRSA_JWK {
                        kid: jwk.kid.clone(),
                        kty: jwk.kty.clone(),
                        alg: jwk.alg.clone(),
                        e: jwk.e.clone(),
                        n: jwk.n.clone(),
                    })
                    .collect()
            })
            .collect(),
    };

    // Convert Validators
    let validators: Vec<SolInitialValidator> = config
        .validators
        .iter()
        .map(|v| SolInitialValidator {
            operator: parse_address(&v.operator),
            owner: parse_address(&v.owner),
            stakeAmount: parse_u256(&v.stake_amount),
            moniker: v.moniker.clone(),
            consensusPubkey: parse_hex_bytes(&v.consensus_pubkey).into(),
            consensusPop: parse_hex_bytes(&v.consensus_pop).into(),
            // BCS encode network addresses from human-readable format
            networkAddresses: bcs_encode_string(&v.network_addresses).into(),
            fullnodeAddresses: bcs_encode_string(&v.fullnode_addresses).into(),
            votingPower: parse_u256(&v.voting_power),
        })
        .collect();

    SolGenesisInitParams {
        validatorConfig: validator_config,
        stakingConfig: staking_config,
        governanceConfig: governance_config,
        epochIntervalMicros: config.epoch_interval_micros,
        majorVersion: config.major_version,
        consensusConfig: parse_hex_bytes(&config.consensus_config).into(),
        executionConfig: parse_hex_bytes(&config.execution_config).into(),
        randomnessConfig: randomness_config,
        oracleConfig: oracle_config,
        jwkConfig: jwk_config,
        validators,
    }
}

/// Calculate total stake amount needed for Genesis.initialize (payable)
pub fn calculate_total_stake(config: &GenesisConfig) -> U256 {
    config
        .validators
        .iter()
        .map(|v| parse_u256(&v.stake_amount))
        .fold(U256::ZERO, |acc, stake| acc + stake)
}

pub fn call_genesis_initialize(genesis_address: Address, config: &GenesisConfig) -> TxEnv {
    let sol_params = convert_config_to_sol(config);
    let total_stake = calculate_total_stake(config);

    info!("=== Genesis Initialize Parameters ===");
    info!("Genesis address: {:?}", genesis_address);
    info!("Total stake value: {} wei", total_stake);
    info!("Validator count: {}", config.validators.len());
    info!("Epoch interval: {} micros", config.epoch_interval_micros);
    info!("Major version: {}", config.major_version);
    info!("Randomness variant: {}", config.randomness_config.variant);
    info!(
        "Oracle source types: {:?}",
        config.oracle_config.source_types
    );
    info!("JWK issuers count: {}", config.jwk_config.issuers.len());
    info!(
        "Bridge config: deploy={}, trustedBridge={}",
        config.oracle_config.bridge_config.deploy,
        if config.oracle_config.bridge_config.trusted_bridge.is_empty() {
            "(not set)".to_string()
        } else {
            config.oracle_config.bridge_config.trusted_bridge.clone()
        }
    );
    if !config.oracle_config.tasks.is_empty() {
        info!("Oracle tasks count: {}", config.oracle_config.tasks.len());
        for (i, task) in config.oracle_config.tasks.iter().enumerate() {
            info!(
                "  Task {}: sourceType={}, sourceId={}, taskName={}",
                i, task.source_type, task.source_id, task.task_name
            );
        }
    }

    let call_data = Genesis::initializeCall { params: sol_params }.abi_encode();

    info!("Call data length: {}", call_data.len());

    // Genesis.initialize is payable - need to send total stake amount
    new_system_call_txn_with_value(genesis_address, call_data.into(), total_stake)
}

// ============================================================================
// VALIDATOR SET QUERY (for verification)
// ============================================================================

sol! {
    interface IValidatorManagement {
        #[derive(Debug)]
        struct ValidatorConsensusInfo {
            address validator;
            bytes consensusPubkey;
            bytes consensusPop;
            uint256 votingPower;
            uint64 validatorIndex;
            bytes networkAddresses;
            bytes fullnodeAddresses;
        }

        function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory);
    }
}

pub fn call_get_active_validators() -> TxEnv {
    let call_data = IValidatorManagement::getActiveValidatorsCall {}.abi_encode();
    new_system_call_txn(VALIDATOR_MANAGER_ADDR, call_data.into())
}

pub fn print_active_validators_result(result: &ExecutionResult, config: &GenesisConfig) {
    handle_execution_result(result, "getActiveValidators", |output_bytes| {
        let decoded =
            IValidatorManagement::getActiveValidatorsCall::abi_decode_returns(output_bytes, false)
                .expect("Failed to decode getActiveValidators result");

        let validators = &decoded._0;
        info!("Active validators count: {}", validators.len());

        // Validate against config
        if validators.len() != config.validators.len() {
            error!(
                "❌ Validator count mismatch! Expected: {}, Actual: {}",
                config.validators.len(),
                validators.len()
            );
            return;
        }

        for (i, validator) in validators.iter().enumerate() {
            // Derive account address from consensus pubkey using SHA3-256
            let account_address =
                derive_account_address_from_consensus_pubkey(&validator.consensusPubkey);

            info!("--- Validator {} ---", i + 1);
            info!("  ETH Address: {:?}", validator.validator);
            info!(
                "  Account Address (from consensus pubkey): 0x{}",
                hex::encode(account_address)
            );
            info!(
                "  Consensus Pubkey: 0x{}",
                hex::encode(&validator.consensusPubkey)
            );
            info!("  Index: {}", validator.validatorIndex);
            info!("  Voting Power: {}", validator.votingPower);
        }

        info!(
            "🎉 All {} validators initialized successfully!",
            validators.len()
        );
    });
}
