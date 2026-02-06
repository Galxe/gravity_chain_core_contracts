use crate::{
    genesis::{GenesisConfig, call_genesis_initialize, calculate_total_stake},
    utils::{
        CONTRACTS, GENESIS_ADDR, SYSTEM_ACCOUNT_INFO, SYSTEM_CALLER, analyze_txn_result,
        execute_revm_sequential, read_hex_from_file,
    },
};

use revm::{
    InMemoryDB,
    db::{BundleState, PlainAccount},
    primitives::{AccountInfo, Env, SpecId, U256},
};
use revm_primitives::{Bytecode, Bytes, TxEnv, hex};
use std::{collections::HashMap, fs::File, io::BufWriter};
use tracing::{debug, error, info, warn};

/// Deploy contracts using BSC-style direct bytecode deployment
fn deploy_bsc_style(byte_code_dir: &str, total_stake: U256) -> InMemoryDB {
    let mut db = InMemoryDB::default();

    // Add system address with sufficient balance to fund Genesis.initialize (payable)
    // SYSTEM_CALLER needs total_stake + buffer to send as msg.value
    let system_caller_balance = total_stake + U256::from(10_000_000) * U256::from(10).pow(U256::from(18));
    db.insert_account_info(SYSTEM_CALLER, AccountInfo {
        balance: system_caller_balance,
        nonce: 1,
        ..AccountInfo::default()
    });

    for (contract_name, target_address) in CONTRACTS {
        let hex_path = format!("{}/{}.hex", byte_code_dir, contract_name);
        let bytecode_hex = read_hex_from_file(&hex_path);

        // For BSC style, we need to extract runtime bytecode from constructor bytecode
        let runtime_bytecode = extract_runtime_bytecode(&bytecode_hex);

        // Set balance for Genesis contract (needs to fund validator stake pools)
        let balance = if contract_name == "Genesis" {
            // Genesis needs to hold all validator stake amounts
            // Add extra buffer for gas
            total_stake + U256::from(1_000_000) * U256::from(10).pow(U256::from(18))
        } else {
            U256::ZERO
        };

        db.insert_account_info(
            target_address,
            AccountInfo {
                code: Some(Bytecode::new_raw(Bytes::from(runtime_bytecode))),
                balance,
                ..AccountInfo::default()
            },
        );

        if balance > U256::ZERO {
            info!(
                "Deployed {} runtime bytecode to {:?} with balance {} ETH",
                contract_name, target_address, balance / U256::from(10).pow(U256::from(18))
            );
        } else {
            info!(
                "Deployed {} runtime bytecode to {:?}",
                contract_name, target_address
            );
        }
    }

    db
}

/// Extract runtime bytecode from constructor bytecode
/// This is a simplified implementation - the bytecode should already be runtime bytecode
fn extract_runtime_bytecode(constructor_bytecode: &str) -> Vec<u8> {
    let bytes = hex::decode(constructor_bytecode.trim()).unwrap_or_default();

    // Simple heuristic: if the bytecode starts with typical constructor patterns,
    // we need to extract the runtime part
    if bytes.len() > 100 && (bytes[0] == 0x60 || bytes[0] == 0x61) {
        // This looks like constructor bytecode
        // For now, we'll use a simplified approach and return the original bytecode
        // In a real implementation, we'd execute the constructor and extract the returned bytecode
        warn!("   [!] Warning: Using constructor bytecode as runtime bytecode");
        bytes
    } else {
        // This looks like runtime bytecode already
        bytes
    }
}

pub fn prepare_env(chain_id: u64) -> Env {
    let mut env = Env::default();
    env.cfg.chain_id = chain_id;
    env.tx.gas_limit = 30_000_000;
    // Set block.timestamp to current time so Genesis.sol's lockedUntil calculation works correctly
    // Genesis.sol calculates: lockedUntil = block.timestamp * 1_000_000 + lockupDuration
    env.block.timestamp = U256::from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("Time went backwards")
            .as_secs(),
    );
    env
}

/// Transaction builder for genesis initialization
struct GenesisTransactionBuilder {
    transactions: Vec<TxEnv>,
}

impl GenesisTransactionBuilder {
    fn new(config: &GenesisConfig) -> Self {
        // Genesis.initialize is the only transaction needed
        // It handles all contract initialization internally
        let transactions = vec![call_genesis_initialize(GENESIS_ADDR, config)];
        Self { transactions }
    }

    fn build(self) -> Vec<TxEnv> {
        info!(
            "Built {} total genesis transactions",
            self.transactions.len()
        );
        self.transactions
    }
}

/// Build genesis transactions
fn build_genesis_transactions(config: &GenesisConfig) -> Vec<TxEnv> {
    GenesisTransactionBuilder::new(config).build()
}

pub fn genesis_generate(
    byte_code_dir: &str,
    output_dir: &str,
    config: &GenesisConfig,
) -> (InMemoryDB, BundleState) {
    info!("=== Starting Genesis deployment and initialization ===");

    // Calculate total stake needed for Genesis contract
    let total_stake = calculate_total_stake(config);
    info!("Total stake required: {} wei", total_stake);

    let db = deploy_bsc_style(byte_code_dir, total_stake);

    let env = prepare_env(config.chain_id);

    let txs = build_genesis_transactions(config);

    let r = execute_revm_sequential(db.clone(), SpecId::LATEST, env.clone(), &txs, None);
    let (result, mut bundle_state) = match r {
        Ok((result, bundle_state)) => {
            info!("=== Genesis initialization successful ===");
            (result, bundle_state)
        }
        Err(e) => {
            panic!(
                "Error: {}",
                format!("{:?}", e.map_db_err(|_| "Database error".to_string()))
            );
        }
    };
    debug!("the bundle state is {:?}", bundle_state);
    let ret = (db, bundle_state.clone());

    for (i, r) in result.iter().enumerate() {
        if !r.is_success() {
            error!("=== Transaction {} failed ===", i + 1);
            println!("Detailed analysis: {}", analyze_txn_result(r));
            panic!("Genesis transaction {} failed", i + 1);
        } else {
            info!("Detailed analysis: {}", analyze_txn_result(r));
        }
    }
    info!(
        "=== All {} transactions completed successfully ===",
        result.len()
    );

    // Add deployed contracts to the final state
    let mut genesis_state = HashMap::new();

    for (contract_name, contract_address) in CONTRACTS {
        let hex_path = format!("{}/{}.hex", byte_code_dir, contract_name);
        let bytecode_hex = read_hex_from_file(&hex_path);
        let runtime_bytecode = extract_runtime_bytecode(&bytecode_hex);

        genesis_state.insert(
            contract_address,
            PlainAccount {
                info: AccountInfo {
                    code: Some(Bytecode::new_raw(Bytes::from(runtime_bytecode))),
                    ..AccountInfo::default()
                },
                storage: Default::default(),
            },
        );

        info!(
            "Added {} to genesis state at {:?}",
            contract_name, contract_address
        );
    }

    // Add any state changes from the bundle_state (from the initialize transaction)
    bundle_state.state.remove(&SYSTEM_CALLER);
    // write bundle state into one json file named bundle_state.json
    serde_json::to_writer_pretty(
        BufWriter::new(File::create(format!("{output_dir}/bundle_state.json")).unwrap()),
        &bundle_state,
    )
    .unwrap();

    info!(
        "bundle state size is {:?}, contracts size {:?}",
        bundle_state.state.len(),
        CONTRACTS.len()
    );
    for (address, account) in bundle_state.state.into_iter() {
        debug!("Address: {:?}, account: {:?}", address, account);
        if let Some(info) = account.info {
            let storage = account
                .storage
                .into_iter()
                .map(|(k, v)| (k, v.present_value()))
                .collect();

            // If this address already exists in genesis_state, merge the storage
            if let Some(existing) = genesis_state.get_mut(&address) {
                existing.storage.extend(storage);
                existing.info = info;
            } else {
                genesis_state.insert(address, PlainAccount { info, storage });
            }
        }
    }

    serde_json::to_writer_pretty(
        BufWriter::new(File::create(format!("{output_dir}/genesis_accounts.json")).unwrap()),
        &genesis_state,
    )
    .unwrap();

    // Create contracts JSON with bytecode
    let contracts_json: HashMap<_, _> = genesis_state
        .iter()
        .filter_map(|(addr, account)| {
            account
                .info
                .code
                .as_ref()
                .map(|code| (*addr, code.bytecode()))
        })
        .collect();

    serde_json::to_writer_pretty(
        BufWriter::new(File::create(format!("{output_dir}/genesis_contracts.json")).unwrap()),
        &contracts_json,
    )
    .unwrap();
    ret
}
