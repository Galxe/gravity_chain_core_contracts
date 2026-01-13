use alloy_primitives::address;

use alloy_sol_macro::sol;
use alloy_sol_types::SolEvent;
use revm::{
    DatabaseCommit, DatabaseRef, EvmBuilder, StateBuilder,
    db::{BundleState, states::bundle_state::BundleRetention},
    primitives::{Address, EVMError, Env, ExecutionResult, SpecId, TxEnv, U256},
};
use revm_primitives::{AccountInfo, Bytes, KECCAK_EMPTY, TxKind, hex, uint};
use std::u64;
use tracing::info;

pub const DEAD_ADDRESS: Address = address!("000000000000000000000000000000000000dEaD");

// ============================================================================
// System Addresses (aligned with gravity_chain_core_contracts/src/foundation/SystemAddresses.sol)
// Address ranges:
//   0x1625F0xxx: Consensus Engine
//   0x1625F1xxx: Runtime Configurations
//   0x1625F2xxx: Staking & Validator
//   0x1625F3xxx: Governance
//   0x1625F4xxx: Oracle
//   0x1625F5xxx: Precompiles
// ============================================================================

// Consensus Engine (0x1625F0xxx)
/// VM/runtime system caller address
pub const SYSTEM_CALLER: Address = address!("00000000000000000000000000000001625F0000");

/// Genesis initialization contract
pub const GENESIS_ADDR: Address = address!("00000000000000000000000000000001625F0001");

// Runtime Configurations (0x1625F1xxx)
/// On-chain timestamp oracle
pub const TIMESTAMP_ADDR: Address = address!("00000000000000000000000000000001625F1000");

/// Staking configuration contract
pub const STAKE_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1001");

/// Validator configuration contract
pub const VALIDATOR_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1002");

/// Randomness configuration contract
pub const RANDOMNESS_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1003");

/// Governance configuration contract
pub const GOVERNANCE_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1004");

/// Epoch configuration contract
pub const EPOCH_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1005");

/// Version configuration contract
pub const VERSION_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1006");

/// Consensus configuration contract
pub const CONSENSUS_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1007");

/// Execution configuration contract
pub const EXECUTION_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1008");

/// Oracle task configuration contract
pub const ORACLE_TASK_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F1009");

/// On-demand oracle task configuration contract
pub const ON_DEMAND_ORACLE_TASK_CONFIG_ADDR: Address = address!("00000000000000000000000000000001625F100A");

// Staking & Validator (0x1625F2xxx)
/// Governance staking contract
pub const STAKING_ADDR: Address = address!("00000000000000000000000000000001625F2000");

/// Validator set management contract
pub const VALIDATOR_MANAGER_ADDR: Address = address!("00000000000000000000000000000001625F2001");

/// DKG (Distributed Key Generation) contract
pub const DKG_ADDR: Address = address!("00000000000000000000000000000001625F2002");

/// Reconfiguration contract
pub const RECONFIGURATION_ADDR: Address = address!("00000000000000000000000000000001625F2003");

/// Block prologue/epilogue handler
pub const BLOCK_ADDR: Address = address!("00000000000000000000000000000001625F2004");

// Governance (0x1625F3xxx)
/// Governance contract
pub const GOVERNANCE_ADDR: Address = address!("00000000000000000000000000000001625F3000");

// Oracle (0x1625F4xxx)
/// Native Oracle contract
pub const NATIVE_ORACLE_ADDR: Address = address!("00000000000000000000000000000001625F4000");

/// JWK (JSON Web Key) manager
pub const JWK_MANAGER_ADDR: Address = address!("00000000000000000000000000000001625F4001");

/// Oracle request queue contract
pub const ORACLE_REQUEST_QUEUE_ADDR: Address = address!("00000000000000000000000000000001625F4002");

// Precompiles (0x1625F5xxx)
/// Native mint precompile
pub const NATIVE_MINT_PRECOMPILE_ADDR: Address = address!("00000000000000000000000000000001625F5000");

// ============================================================================
// CONTRACTS ARRAY - All contracts to deploy at genesis
// Note: StakePool is created dynamically during Genesis.initialize, not pre-deployed
// ============================================================================

pub const CONTRACTS: [(&str, Address); 20] = [
    ("Genesis", GENESIS_ADDR),
    ("Reconfiguration", RECONFIGURATION_ADDR),
    ("StakingConfig", STAKE_CONFIG_ADDR),
    ("Staking", STAKING_ADDR),
    ("ValidatorManagement", VALIDATOR_MANAGER_ADDR),
    ("Governance", GOVERNANCE_ADDR),
    ("ValidatorConfig", VALIDATOR_CONFIG_ADDR),
    ("Blocker", BLOCK_ADDR),
    ("Timestamp", TIMESTAMP_ADDR),
    ("JWKManager", JWK_MANAGER_ADDR),
    ("NativeOracle", NATIVE_ORACLE_ADDR),
    ("RandomnessConfig", RANDOMNESS_CONFIG_ADDR),
    ("DKG", DKG_ADDR),
    ("GovernanceConfig", GOVERNANCE_CONFIG_ADDR),
    ("EpochConfig", EPOCH_CONFIG_ADDR),
    ("VersionConfig", VERSION_CONFIG_ADDR),
    ("ConsensusConfig", CONSENSUS_CONFIG_ADDR),
    ("ExecutionConfig", EXECUTION_CONFIG_ADDR),
    ("OracleTaskConfig", ORACLE_TASK_CONFIG_ADDR),
    ("OnDemandOracleTaskConfig", ON_DEMAND_ORACLE_TASK_CONFIG_ADDR),
];

pub const SYSTEM_ACCOUNT_INFO: AccountInfo = AccountInfo {
    balance: uint!(1_000_000_000_000_000_000_U256),
    nonce: 1,
    code_hash: KECCAK_EMPTY,
    code: None,
};

sol! {
    event Log(string message, uint256 value);
}

pub fn analyze_txn_result(result: &ExecutionResult) -> String {
    match result {
        ExecutionResult::Revert { gas_used, output } => {
            let mut reason = format!("Revert with gas used: {}", gas_used);

            if let Some(selector) = output.get(0..4) {
                reason.push_str(&format!("\nFunction selector: 0x{}", hex::encode(selector)));

                match selector {
                    [0x49, 0xfd, 0x36, 0xf2] => reason.push_str(" (OnlySystemCaller)"),
                    [0x97, 0xb8, 0x83, 0x54] => reason.push_str(" (UnknownParam)"),
                    [0x0a, 0x5a, 0x60, 0x41] => reason.push_str(" (InvalidValue)"),
                    [0x11, 0x6c, 0x64, 0xa8] => reason.push_str(" (OnlyCoinbase)"),
                    [0x83, 0xf1, 0xb1, 0xd3] => reason.push_str(" (OnlyZeroGasPrice)"),
                    [0xf2, 0x2c, 0x43, 0x90] => reason.push_str(" (OnlySystemContract)"),
                    [0x08, 0xc3, 0x79, 0xa0] => reason.push_str(" (Error(string))"),
                    [0x4e, 0x48, 0x7b, 0x71] => reason.push_str(" (Panic(uint256))"),
                    _ => reason.push_str(" (Unknown error selector)"),
                }
            }

            if output.len() > 4 {
                reason.push_str(&format!(
                    "\nAdditional data: 0x{}",
                    hex::encode(&output[4..])
                ));
            }

            reason
        }
        ExecutionResult::Success { gas_used, logs, .. } => {
            let mut log_msg = String::new();
            for log in logs {
                if let Ok(parsed) = Log::decode_log(log, true) {
                    log_msg.push_str(&format!(
                        "txn event Log: {:?}, {:?}.",
                        parsed.message, parsed.value
                    ));
                }
            }
            format!("Success with gas used: {}, {}", gas_used, log_msg)
        }
        ExecutionResult::Halt { reason, gas_used } => {
            format!("Halt: {:?} with gas used: {}", reason, gas_used)
        }
    }
}

pub const MINER_ADDRESS: usize = 999;

/// Simulate the sequential execution of transactions with detailed logging
pub(crate) fn execute_revm_sequential<DB>(
    db: DB,
    spec_id: SpecId,
    env: Env,
    txs: &[TxEnv],
    pre_bundle: Option<BundleState>,
) -> Result<(Vec<ExecutionResult>, BundleState), EVMError<DB::Error>>
where
    DB: DatabaseRef,
{
    let db = if let Some(pre_bundle) = pre_bundle {
        StateBuilder::new()
            .with_bundle_prestate(pre_bundle)
            .with_database_ref(db)
            .build()
    } else {
        StateBuilder::new()
            .with_bundle_update()
            .with_database_ref(db)
            .build()
    };
    let mut evm = EvmBuilder::default()
        .with_db(db)
        .with_spec_id(spec_id)
        .with_env(Box::new(env))
        .build();

    let mut results = Vec::with_capacity(txs.len());
    for (i, tx) in txs.iter().enumerate() {
        info!("=== Executing transaction {} ===", i + 1);
        info!("Transaction details:");
        info!("  Caller: {:?}", tx.caller);
        info!("  To: {:?}", tx.transact_to);
        info!("  Value: {:?}", tx.value);
        info!("  Data length: {}", tx.data.len());
        if tx.data.len() >= 4 {
            info!("  Function selector: 0x{}", hex::encode(&tx.data[0..4]));
        }

        *evm.tx_mut() = tx.clone();

        let result_and_state = evm.transact()?;
        info!("transaction evm state {:?}", result_and_state.state);
        evm.db_mut().commit(result_and_state.state);

        info!(
            "Transaction result: {}",
            analyze_txn_result(&result_and_state.result)
        );
        results.push(result_and_state.result);
        info!("=== Transaction {} completed ===", i + 1);
    }
    evm.db_mut().merge_transitions(BundleRetention::Reverts);

    Ok((results, evm.db_mut().take_bundle()))
}

pub fn new_system_call_txn(contract: Address, input: Bytes) -> TxEnv {
    TxEnv {
        caller: SYSTEM_CALLER,
        gas_limit: u64::MAX,
        gas_price: U256::ZERO,
        transact_to: TxKind::Call(contract),
        value: U256::ZERO,
        data: input,
        ..Default::default()
    }
}

/// Create a system call transaction with a specific value (for payable functions)
pub fn new_system_call_txn_with_value(contract: Address, input: Bytes, value: U256) -> TxEnv {
    TxEnv {
        caller: SYSTEM_CALLER,
        gas_limit: u64::MAX,
        gas_price: U256::ZERO,
        transact_to: TxKind::Call(contract),
        value,
        data: input,
        ..Default::default()
    }
}

pub fn new_system_create_txn(hex_code: &str, args: Bytes) -> TxEnv {
    let mut data = hex::decode(hex_code).expect("Invalid hex string");
    data.extend_from_slice(&args);
    TxEnv {
        caller: SYSTEM_CALLER,
        gas_limit: u64::MAX,
        gas_price: U256::ZERO,
        transact_to: TxKind::Create,
        value: U256::ZERO,
        data: data.into(),
        ..Default::default()
    }
}

pub fn read_hex_from_file(path: &str) -> String {
    std::fs::read_to_string(path).expect(&format!("Failed to open {}", path))
}
