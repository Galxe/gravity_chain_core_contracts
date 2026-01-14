//! Genesis verification module
//! 
//! This module provides functionality to verify an existing genesis.json file
//! by simulating the onchain config reading logic similar to gravity-reth.
//! It helps catch ABI compatibility issues before deployment.

use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_macro::sol;
use alloy_sol_types::SolCall;
use anyhow::{Context, Result, anyhow};
use revm::{DatabaseCommit, EvmBuilder, StateBuilder, db::BundleState};
use revm_primitives::{AccountInfo, Bytecode, ExecutionResult, SpecId, TxEnv, hex};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs};
use tracing::{error, info, warn};

use crate::execute::prepare_env;
use crate::utils::{VALIDATOR_MANAGER_ADDR, SYSTEM_CALLER, execute_revm_sequential, new_system_call_txn};

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
}

/// Result of genesis verification
#[derive(Debug)]
pub struct VerifyResult {
    pub success: bool,
    pub validator_count: usize,
    pub validators: Vec<ValidatorInfo>,
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

/// Verify an existing genesis.json file
pub fn verify_genesis_file(genesis_path: &str) -> Result<VerifyResult> {
    info!("=== Genesis Verification ===");
    info!("Loading genesis file: {}", genesis_path);
    
    // 1. Load genesis.json
    let genesis_content = fs::read_to_string(genesis_path)
        .context(format!("Failed to read genesis file: {}", genesis_path))?;
    
    let genesis: GenesisJson = serde_json::from_str(&genesis_content)
        .context("Failed to parse genesis.json")?;
    
    info!("Genesis loaded successfully, {} accounts in alloc", genesis.alloc.len());
    
    // 2. Create in-memory EVM with genesis state
    let mut db = revm::InMemoryDB::default();
    
    for (addr_str, entry) in &genesis.alloc {
        let addr: Address = addr_str.parse()
            .context(format!("Invalid address: {}", addr_str))?;
        
        let balance = entry.balance.as_ref()
            .map(|b| parse_u256_hex(b))
            .unwrap_or(U256::ZERO);
        
        let nonce = entry.nonce.unwrap_or(0);
        
        let code = entry.code.as_ref()
            .map(|c| {
                let hex_str = c.strip_prefix("0x").unwrap_or(c);
                hex::decode(hex_str).expect("Invalid bytecode hex")
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
                let key = parse_u256_hex(key_str);
                let value = parse_u256_hex(value_str);
                db.insert_account_storage(addr, key, value)
                    .expect("Failed to insert storage");
            }
        }
    }
    
    // Check if ValidatorManager contract exists
    let vm_addr = VALIDATOR_MANAGER_ADDR;
    let vm_addr_str = format!("{:?}", vm_addr).to_lowercase();
    let has_vm = genesis.alloc.keys()
        .any(|k| k.to_lowercase() == vm_addr_str);
    
    if !has_vm {
        return Ok(VerifyResult {
            success: false,
            validator_count: 0,
            validators: vec![],
            errors: vec![format!(
                "ValidatorManagement contract not found at expected address: {:?}",
                vm_addr
            )],
        });
    }
    
    info!("ValidatorManagement contract found at {:?}", vm_addr);
    
    // 3. Simulate getActiveValidators() call
    info!("Simulating getActiveValidators() call...");
    
    let call = getActiveValidatorsCall {};
    let input: Bytes = call.abi_encode().into();
    let tx = new_system_call_txn(vm_addr, input);
    
    let env = prepare_env();
    let result = execute_revm_sequential(
        db,
        SpecId::LATEST,
        env,
        &[tx],
        None,
    );
    
    match result {
        Ok((results, _)) => {
            if let Some(exec_result) = results.first() {
                return process_execution_result(exec_result);
            }
            Err(anyhow!("No execution result returned"))
        }
        Err(e) => {
            Err(anyhow!("EVM execution failed: {:?}", e))
        }
    }
}

fn process_execution_result(result: &ExecutionResult) -> Result<VerifyResult> {
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
                    info!("✅ ABI decode successful! {} validators found", validators.len());
                    
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
                        errors: vec![],
                    })
                }
                Err(decode_err) => {
                    error!("❌ ABI decode FAILED: {:?}", decode_err);
                    error!("This indicates the genesis.json was created with old contracts");
                    error!("Solution: Recompile contracts and regenerate genesis.json");
                    
                    // Try to provide more diagnostic info
                    if output_bytes.len() > 64 {
                        warn!("First 64 bytes of output: 0x{}", hex::encode(&output_bytes[..64]));
                    }
                    
                    Ok(VerifyResult {
                        success: false,
                        validator_count: 0,
                        validators: vec![],
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
                errors: vec![format!("Call reverted: 0x{}", hex::encode(output))],
            })
        }
        ExecutionResult::Halt { reason, .. } => {
            error!("getActiveValidators() call halted: {:?}", reason);
            
            Ok(VerifyResult {
                success: false,
                validator_count: 0,
                validators: vec![],
                errors: vec![format!("Call halted: {:?}", reason)],
            })
        }
    }
}

fn parse_u256_hex(s: &str) -> U256 {
    let s = s.strip_prefix("0x").unwrap_or(s);
    if s.is_empty() {
        return U256::ZERO;
    }
    U256::from_str_radix(s, 16).unwrap_or(U256::ZERO)
}

/// Print verification summary
pub fn print_verify_summary(result: &VerifyResult) {
    println!("\n========================================");
    println!("       GENESIS VERIFICATION RESULT");
    println!("========================================\n");
    
    if result.success {
        println!("✅ STATUS: PASSED\n");
        println!("Validators: {}", result.validator_count);
        println!("\nValidator Details:");
        for (i, v) in result.validators.iter().enumerate() {
            println!("  [{}] {:?}", i, v.address);
            println!("      Power: {}, Index: {}", v.voting_power, v.validator_index);
            println!("      Network Addrs: {}, Fullnode Addrs: {}", 
                if v.has_network_addresses { "✓" } else { "✗" },
                if v.has_fullnode_addresses { "✓" } else { "✗" }
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
