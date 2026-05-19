//! Genesis verification module
//!
//! This module provides functionality to verify an existing genesis.json file
//! by simulating the onchain config reading logic similar to gravity-reth.
//! It helps catch ABI compatibility issues before deployment.

use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_macro::sol;
use alloy_sol_types::SolCall;
use anyhow::{anyhow, Context, Result};
use revm::{db::BundleState, DatabaseCommit, EvmBuilder, StateBuilder};
use revm_primitives::{hex, AccountInfo, Bytecode, ExecutionResult, SpecId, TxEnv};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs};
use tracing::{error, info, warn};

use crate::execute::prepare_env;
use crate::utils::{
    execute_revm_sequential, new_system_call_txn, EPOCH_CONFIG_ADDR, GOVERNANCE_ADDR,
    SYSTEM_CALLER, VALIDATOR_MANAGER_ADDR,
};

// ============================================================================
// GENESIS JSON STRUCTURES (matching reth genesis format)
// ============================================================================

#[derive(Debug, Deserialize, Serialize)]
pub struct GenesisJson {
    pub alloc: HashMap<String, AllocEntry>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct AllocEntry {
    pub balance: Option<String>,
    pub nonce: Option<u64>,
    pub code: Option<String>,
    pub storage: Option<HashMap<String, String>>,
}

// ============================================================================
// ABI DEFINITIONS - Must match gravity-reth exactly
// ============================================================================

sol! {
    /// ValidatorConsensusInfo struct - MUST match gravity-reth types.rs
    /// This is the expected format after the networkAddresses/fullnodeAddresses addition
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

    // EpochConfig.epochIntervalMicros()
    function epochIntervalMicros() external view returns (uint64);

    interface IGovernance {
        function owner() external view returns (address);
        function isInitialized() external view returns (bool);
    }
}

/// Result of genesis verification
#[derive(Debug)]
pub struct VerifyResult {
    pub success: bool,
    pub validator_count: usize,
    pub validators: Vec<ValidatorInfo>,
    pub epoch_interval_micros: Option<u64>,
    pub errors: Vec<String>,
}

#[derive(Debug)]
pub struct ValidatorInfo {
    pub address: Address,
    pub voting_power: U256,
    pub validator_index: u64,
    pub has_network_addresses: bool,
    pub has_fullnode_addresses: bool,
}

/// Verify an existing genesis.json file. If `config_path` is provided, also
/// asserts that `Governance.owner()` equals the config's `governanceOwner`
/// — without that field we can only check the on-chain owner is non-zero and
/// `isInitialized()` is true.
pub fn verify_genesis_file(
    genesis_path: &str,
    config_path: Option<&str>,
) -> Result<VerifyResult> {
    info!("=== Genesis Verification ===");
    info!("Loading genesis file: {}", genesis_path);

    // Load expected governance owner from config if a config path was given.
    // Parse loosely (as serde_json::Value) so this code stays decoupled from
    // GenesisConfig's full schema — verify must keep working even if config
    // adds new required fields.
    let expected_governance_owner: Option<Address> = match config_path {
        Some(path) => {
            let content = fs::read_to_string(path)
                .context(format!("Failed to read config file: {}", path))?;
            let v: serde_json::Value = serde_json::from_str(&content)
                .context("Failed to parse config JSON")?;
            let owner_str = v
                .get("governanceOwner")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow!("Config missing 'governanceOwner' field"))?;
            let parsed: Address = owner_str
                .parse()
                .map_err(|e| anyhow!("Invalid governanceOwner in config {:?}: {}", owner_str, e))?;
            info!("Loaded expected Governance owner from config: {:?}", parsed);
            Some(parsed)
        }
        None => {
            info!("No --config-file provided; will only check non-zero owner + isInitialized");
            None
        }
    };

    // 1. Load genesis.json
    let genesis_content = fs::read_to_string(genesis_path)
        .context(format!("Failed to read genesis file: {}", genesis_path))?;

    let genesis: GenesisJson =
        serde_json::from_str(&genesis_content).context("Failed to parse genesis.json")?;

    info!(
        "Genesis loaded successfully, {} accounts in alloc",
        genesis.alloc.len()
    );

    // 2. Create in-memory EVM with genesis state
    let mut db = revm::InMemoryDB::default();

    for (addr_str, entry) in &genesis.alloc {
        let addr: Address = addr_str
            .parse()
            .context(format!("Invalid address: {}", addr_str))?;

        let balance = entry
            .balance
            .as_ref()
            .map(|b| parse_u256_hex(b))
            .transpose()
            .with_context(|| format!("Failed to parse balance for account {}", addr_str))?
            .unwrap_or(U256::ZERO);

        let nonce = entry.nonce.unwrap_or(0);

        let code = entry
            .code
            .as_ref()
            .map(|c| {
                let hex_str = c.strip_prefix("0x").unwrap_or(c);
                hex::decode(hex_str).unwrap_or_else(|e| {
                    panic!("FATAL: Failed to decode hex bytecode: {}", e)
                })
            })
            .unwrap_or_default();

        let bytecode = if code.is_empty() {
            Bytecode::default()
        } else {
            Bytecode::new_raw(code.into())
        };

        let account_info = AccountInfo {
            balance,
            nonce,
            code_hash: bytecode.hash_slow(),
            code: Some(bytecode),
        };

        db.insert_account_info(addr, account_info);

        // Insert storage
        if let Some(storage) = &entry.storage {
            for (key_str, value_str) in storage {
                let key = parse_u256_hex(key_str).with_context(|| {
                    format!("Failed to parse storage key for account {}", addr_str)
                })?;
                let value = parse_u256_hex(value_str).with_context(|| {
                    format!(
                        "Failed to parse storage value for account {} key {}",
                        addr_str, key_str
                    )
                })?;
                db.insert_account_storage(addr, key, value)
                    .expect("Failed to insert storage");
            }
        }
    }

    // Check if ValidatorManager contract exists
    let vm_addr = VALIDATOR_MANAGER_ADDR;
    let vm_addr_str = format!("{:?}", vm_addr).to_lowercase();
    let has_vm = genesis
        .alloc
        .keys()
        .any(|k| k.to_lowercase() == vm_addr_str);

    if !has_vm {
        return Ok(VerifyResult {
            success: false,
            validator_count: 0,
            validators: vec![],
            epoch_interval_micros: None,
            errors: vec![format!(
                "ValidatorManagement contract not found at expected address: {:?}",
                vm_addr
            )],
        });
    }

    info!("ValidatorManagement contract found at {:?}", vm_addr);

    // 3a. Verify Governance state. Collected separately and merged into the
    // final result so a governance failure doesn't short-circuit the
    // validator/epoch checks — we want a single comprehensive failure report
    // out of one verify run, not the first-failure-wins.
    info!("Verifying Governance state...");
    let governance_errors = verify_governance(&db, expected_governance_owner);

    // 3. First verify epoch interval from EpochConfig
    info!("Verifying epoch interval from EpochConfig...");
    let epoch_interval = verify_epoch_interval(&db);
    match &epoch_interval {
        Some(micros) => {
            let hours = *micros as f64 / 3_600_000_000.0;
            info!("✅ Epoch interval: {} micros ({:.4} hours)", micros, hours);
        }
        None => {
            warn!("⚠️ Could not read epoch interval from EpochConfig");
        }
    }

    // 4. Simulate getActiveValidators() call
    info!("Simulating getActiveValidators() call...");

    let call = getActiveValidatorsCall {};
    let input: Bytes = call.abi_encode().into();
    let tx = new_system_call_txn(vm_addr, input);

    // block.timestamp = 0 is safe here: verify replays only pure view calls
    // (getActiveValidators / epochIntervalMicros) against a sealed genesis.json
    // alloc and does NOT re-run Genesis.initialize; neither probe reads
    // block.timestamp transitively, so the value is unobservable in the
    // returned bytes. If a future probe touches time-dependent code, switch
    // this to a deterministic non-zero constant (or thread through the
    // genesis header timestamp).
    let env = prepare_env(1337, 0);
    let result = execute_revm_sequential(db, SpecId::LATEST, env, &[tx], None);

    match result {
        Ok((results, _)) => {
            if let Some(exec_result) = results.first() {
                let mut result = process_execution_result(exec_result, epoch_interval)?;
                if !governance_errors.is_empty() {
                    result.success = false;
                    result.errors.extend(governance_errors);
                }
                return Ok(result);
            }
            Err(anyhow!("No execution result returned"))
        }
        Err(e) => Err(anyhow!("EVM execution failed: {:?}", e)),
    }
}

/// Inspect the planted Governance contract. Always asserts the contract is
/// initialized and its `owner()` is non-zero; if `expected_owner` is provided
/// (because the caller passed `--config-file`), also asserts strict equality.
///
/// Returns a list of human-readable error strings — empty if all checks pass.
/// This shape mirrors the way other accumulating checks in this module work:
/// one verify invocation should surface every problem, not just the first.
fn verify_governance(
    db: &revm::InMemoryDB,
    expected_owner: Option<Address>,
) -> Vec<String> {
    let mut errors = Vec::new();

    // --- isInitialized() ---
    let init_call = IGovernance::isInitializedCall {};
    let init_input: Bytes = init_call.abi_encode().into();
    let init_tx = new_system_call_txn(GOVERNANCE_ADDR, init_input);
    // See note above on the getActiveValidators call site: block.timestamp = 0
    // is safe for these view-call ABI probes.
    let env = prepare_env(1337, 0);
    match execute_revm_sequential(db.clone(), SpecId::LATEST, env, &[init_tx], None) {
        Ok((results, _)) => match results.first() {
            Some(ExecutionResult::Success { output, .. }) => {
                let bytes = match output {
                    revm_primitives::Output::Call(b) => b,
                    revm_primitives::Output::Create(b, _) => b,
                };
                match IGovernance::isInitializedCall::abi_decode_returns(bytes, false) {
                    Ok(d) if d._0 => info!("✅ Governance.isInitialized() = true"),
                    Ok(_) => {
                        let msg = "Governance.isInitialized() returned false — Genesis.initialize did not run".to_string();
                        error!("❌ {}", msg);
                        errors.push(msg);
                    }
                    Err(e) => {
                        let msg = format!("Failed to decode Governance.isInitialized(): {:?}", e);
                        error!("❌ {}", msg);
                        errors.push(msg);
                    }
                }
            }
            Some(other) => {
                let msg = format!("Governance.isInitialized() did not succeed: {:?}", other);
                error!("❌ {}", msg);
                errors.push(msg);
            }
            None => {
                let msg = "Governance.isInitialized() returned no execution result".to_string();
                error!("❌ {}", msg);
                errors.push(msg);
            }
        },
        Err(e) => {
            let msg = format!("Governance.isInitialized() EVM error: {:?}", e);
            error!("❌ {}", msg);
            errors.push(msg);
        }
    }

    // --- owner() ---
    let owner_call = IGovernance::ownerCall {};
    let owner_input: Bytes = owner_call.abi_encode().into();
    let owner_tx = new_system_call_txn(GOVERNANCE_ADDR, owner_input);
    let env = prepare_env(1337, 0);
    match execute_revm_sequential(db.clone(), SpecId::LATEST, env, &[owner_tx], None) {
        Ok((results, _)) => match results.first() {
            Some(ExecutionResult::Success { output, .. }) => {
                let bytes = match output {
                    revm_primitives::Output::Call(b) => b,
                    revm_primitives::Output::Create(b, _) => b,
                };
                match IGovernance::ownerCall::abi_decode_returns(bytes, false) {
                    Ok(decoded) => {
                        let actual = decoded._0;
                        if actual == Address::ZERO {
                            // owner = 0 is structurally invalid: Governance.initialize
                            // rejects address(0), and renounceOwnership reverts. If we
                            // see it here, the artifact is broken regardless of config.
                            let msg = "Governance.owner() = address(0) — Governance is unmanageable".to_string();
                            error!("❌ {}", msg);
                            errors.push(msg);
                        } else {
                            info!("Governance.owner() = {:?}", actual);
                        }
                        if let Some(expected) = expected_owner {
                            if actual != expected {
                                let msg = format!(
                                    "Governance owner mismatch: config governanceOwner={:?}, on-chain owner()={:?}",
                                    expected, actual
                                );
                                error!("❌ {}", msg);
                                errors.push(msg);
                            } else {
                                info!("✅ Governance.owner() matches config");
                            }
                        }
                    }
                    Err(e) => {
                        let msg = format!("Failed to decode Governance.owner(): {:?}", e);
                        error!("❌ {}", msg);
                        errors.push(msg);
                    }
                }
            }
            Some(other) => {
                let msg = format!("Governance.owner() did not succeed: {:?}", other);
                error!("❌ {}", msg);
                errors.push(msg);
            }
            None => {
                let msg = "Governance.owner() returned no execution result".to_string();
                error!("❌ {}", msg);
                errors.push(msg);
            }
        },
        Err(e) => {
            let msg = format!("Governance.owner() EVM error: {:?}", e);
            error!("❌ {}", msg);
            errors.push(msg);
        }
    }

    errors
}

/// Verify epoch interval by calling EpochConfig.epochIntervalMicros()
fn verify_epoch_interval(db: &revm::InMemoryDB) -> Option<u64> {
    let call = epochIntervalMicrosCall {};
    let input: Bytes = call.abi_encode().into();
    let tx = new_system_call_txn(EPOCH_CONFIG_ADDR, input);

    // See note above on the getActiveValidators call site: block.timestamp = 0
    // is safe for these view-call ABI probes.
    let env = prepare_env(1337, 0);
    let result = execute_revm_sequential(db.clone(), SpecId::LATEST, env, &[tx], None);

    match result {
        Ok((results, _)) => {
            if let Some(ExecutionResult::Success { output, .. }) = results.first() {
                let output_bytes = match output {
                    revm_primitives::Output::Call(bytes) => bytes,
                    revm_primitives::Output::Create(bytes, _) => bytes,
                };

                if let Ok(decoded) =
                    epochIntervalMicrosCall::abi_decode_returns(output_bytes, false)
                {
                    return Some(decoded._0);
                }
            }
            None
        }
        Err(_) => None,
    }
}

fn process_execution_result(
    result: &ExecutionResult,
    epoch_interval_micros: Option<u64>,
) -> Result<VerifyResult> {
    match result {
        ExecutionResult::Success { output, .. } => {
            let output_bytes = match output {
                revm_primitives::Output::Call(bytes) => bytes,
                revm_primitives::Output::Create(bytes, _) => bytes,
            };

            info!("getActiveValidators() call successful");
            info!("Output length: {} bytes", output_bytes.len());

            // Try to decode with the new ABI (7 fields)
            match getActiveValidatorsCall::abi_decode_returns(output_bytes, false) {
                Ok(decoded) => {
                    let validators = &decoded._0;
                    info!(
                        "✅ ABI decode successful! {} validators found",
                        validators.len()
                    );

                    let mut validator_infos = Vec::new();
                    for (i, v) in validators.iter().enumerate() {
                        info!("--- Validator {} ---", i);
                        info!("  Address: {:?}", v.validator);
                        info!("  Voting Power: {}", v.votingPower);
                        info!("  Index: {}", v.validatorIndex);
                        info!("  Network Addresses: {} bytes", v.networkAddresses.len());
                        info!("  Fullnode Addresses: {} bytes", v.fullnodeAddresses.len());

                        validator_infos.push(ValidatorInfo {
                            address: v.validator,
                            voting_power: v.votingPower,
                            validator_index: v.validatorIndex,
                            has_network_addresses: !v.networkAddresses.is_empty(),
                            has_fullnode_addresses: !v.fullnodeAddresses.is_empty(),
                        });
                    }

                    info!("🎉 Genesis verification PASSED - ABI is compatible with gravity-reth");

                    Ok(VerifyResult {
                        success: true,
                        validator_count: validators.len(),
                        validators: validator_infos,
                        epoch_interval_micros,
                        errors: vec![],
                    })
                }
                Err(decode_err) => {
                    error!("❌ ABI decode FAILED: {:?}", decode_err);
                    error!("This indicates the genesis.json was created with old contracts");
                    error!("Solution: Recompile contracts and regenerate genesis.json");

                    // Try to provide more diagnostic info
                    if output_bytes.len() > 64 {
                        warn!(
                            "First 64 bytes of output: 0x{}",
                            hex::encode(&output_bytes[..64])
                        );
                    }

                    Ok(VerifyResult {
                        success: false,
                        validator_count: 0,
                        validators: vec![],
                        epoch_interval_micros,
                        errors: vec![
                            format!("ABI decode failed: {:?}", decode_err),
                            "This likely means the genesis.json was created with old contracts lacking networkAddresses/fullnodeAddresses fields".to_string(),
                        ],
                    })
                }
            }
        }
        ExecutionResult::Revert { output, .. } => {
            error!("getActiveValidators() call reverted");
            error!("Revert output: 0x{}", hex::encode(output));

            Ok(VerifyResult {
                success: false,
                validator_count: 0,
                validators: vec![],
                epoch_interval_micros,
                errors: vec![format!("Call reverted: 0x{}", hex::encode(output))],
            })
        }
        ExecutionResult::Halt { reason, .. } => {
            error!("getActiveValidators() call halted: {:?}", reason);

            Ok(VerifyResult {
                success: false,
                validator_count: 0,
                validators: vec![],
                epoch_interval_micros,
                errors: vec![format!("Call halted: {:?}", reason)],
            })
        }
    }
}

/// Parse a 0x-prefixed (or bare) hex string into a U256.
///
/// Returns `Err` on malformed input rather than silently defaulting to zero.
/// The `verify` subcommand is the independent release-gate check, so a
/// trivially malformed balance/storage value (e.g. a decimal string) must
/// surface as a verification failure — not a silent zero that lets a
/// corrupted alloc pass review.
fn parse_u256_hex(s: &str) -> Result<U256> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    if stripped.is_empty() {
        return Ok(U256::ZERO);
    }
    U256::from_str_radix(stripped, 16)
        .map_err(|e| anyhow!("invalid hex U256 value {:?}: {}", s, e))
}

/// Print verification summary
pub fn print_verify_summary(result: &VerifyResult) {
    println!("\n========================================");
    println!("       GENESIS VERIFICATION RESULT");
    println!("========================================\n");

    if result.success {
        println!("✅ STATUS: PASSED\n");

        // Display epoch interval
        if let Some(micros) = result.epoch_interval_micros {
            let hours = micros as f64 / 3_600_000_000.0;
            println!("Epoch Interval: {} micros ({:.4} hours)", micros, hours);
        }

        println!("Validators: {}", result.validator_count);
        println!("\nValidator Details:");
        for (i, v) in result.validators.iter().enumerate() {
            println!("  [{}] {:?}", i, v.address);
            println!(
                "      Power: {}, Index: {}",
                v.voting_power, v.validator_index
            );
            println!(
                "      Network Addrs: {}, Fullnode Addrs: {}",
                if v.has_network_addresses {
                    "✓"
                } else {
                    "✗"
                },
                if v.has_fullnode_addresses {
                    "✓"
                } else {
                    "✗"
                }
            );
        }
        println!("\n🎉 Genesis is compatible with gravity-reth!");
    } else {
        println!("❌ STATUS: FAILED\n");
        println!("Errors:");
        for err in &result.errors {
            println!("  - {}", err);
        }
        println!("\n🔧 Fix: Recompile contracts and regenerate genesis.json");
        println!("   cd /path/to/gravity_chain_core_contracts");
        println!("   forge build");
        println!("   ./scripts/generate_genesis.sh");
    }

    println!("\n========================================\n");
}
