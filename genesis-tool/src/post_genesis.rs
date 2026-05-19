use alloy_sol_macro::sol;
use alloy_sol_types::SolCall;
use revm::{DatabaseRef, InMemoryDB, db::BundleState};
use revm_primitives::{Address, ExecutionResult, SpecId, TxEnv, hex};
use tracing::{error, info};

use crate::{
    execute::{prepare_env, resolve_block_timestamp},
    genesis::{
        GenesisConfig, call_get_active_validators, print_active_validators_result,
    },
    utils::{GOVERNANCE_ADDR, execute_revm_sequential, new_system_call_txn},
};

sol! {
    interface IGovernance {
        function owner() external view returns (address);
        function isInitialized() external view returns (bool);
    }
}

/// Generic template for handling execution results
///
/// This function provides a common structure for all print_* functions,
/// reducing code duplication and making the codebase more maintainable.
///
/// The `success_handler` returns `Result<(), String>` so that semantic
/// failures discovered during decoding (e.g. validator-count mismatch
/// against the input config) propagate as `Err` rather than silently
/// logging — otherwise `run_generate` would exit 0 on a broken artifact
/// and ship it through CI.
pub fn handle_execution_result<F>(result: &ExecutionResult, function_name: &str, success_handler: F) -> Result<(), String>
where
    F: FnOnce(&[u8]) -> Result<(), String>,
{
    match result {
        ExecutionResult::Success { output, .. } => {
            let output_bytes = match output {
                revm_primitives::Output::Call(bytes) => bytes,
                revm_primitives::Output::Create(bytes, _) => bytes,
            };

            info!("=== {} call successful ===", function_name);
            info!("Output length: {} bytes", output_bytes.len());
            if output_bytes.len() <= 256 {
                info!("Raw output: 0x{}", hex::encode(output_bytes));
            } else {
                info!("Raw output (truncated): 0x{}...", hex::encode(&output_bytes[..64]));
            }

            success_handler(output_bytes)
        }
        ExecutionResult::Revert { output, .. } => {
            error!("{} call reverted", function_name);
            error!("Revert output: 0x{}", hex::encode(output));
            Err(format!("{} call reverted: 0x{}", function_name, hex::encode(output)))
        }
        ExecutionResult::Halt { reason, .. } => {
            error!("{} call halted: {:?}", function_name, reason);
            Err(format!("{} call halted: {:?}", function_name, reason))
        }
    }
}

/// Generic template for verification functions
fn execute_verification<F>(
    db: impl DatabaseRef,
    bundle_state: BundleState,
    transaction: TxEnv,
    verification_name: &str,
    chain_id: u64,
    block_timestamp_secs: u64,
    result_handler: F,
) -> Result<(), String>
where
    F: FnOnce(&ExecutionResult) -> Result<(), String>,
{
    let env = prepare_env(chain_id, block_timestamp_secs);
    let r = execute_revm_sequential(db, SpecId::LATEST, env, &[transaction], Some(bundle_state));
    
    match r {
        Ok((result, _)) => {
            if let Some(execution_result) = result.get(0) {
                result_handler(execution_result)?;
            }
            Ok(())
        }
        Err(e) => {
            let err_msg = format!("{:?}", e.map_db_err(|_| "Database error".to_string()));
            error!("verify {} error: {}", verification_name, err_msg);
            Err(format!("verify {} error: {}", verification_name, err_msg))
        }
    }
}

fn verify_active_validators(db: impl DatabaseRef, bundle_state: BundleState, config: &GenesisConfig) -> Result<(), String> {
    let get_validators_txn = call_get_active_validators();
    execute_verification(
        db,
        bundle_state,
        get_validators_txn,
        "active validators",
        config.chain_id,
        resolve_block_timestamp(config),
        |result| print_active_validators_result(result, config),
    )
}

/// Verify that `Governance.owner()` and `Governance.isInitialized()` reflect
/// the values the config asked for. Without this, a typo or zero address in
/// `governanceOwner` is silently baked into a sealed genesis artifact and
/// only surfaces after launch — when `renounceOwnership` is already disabled
/// and the executor set is unmanageable for the lifetime of the chain.
fn verify_governance_owner(
    db: impl DatabaseRef,
    bundle_state: BundleState,
    config: &GenesisConfig,
) -> Result<(), String> {
    let expected_owner: Address = config
        .governance_owner
        .parse()
        .map_err(|e| format!("Invalid governanceOwner address in config {:?}: {}", config.governance_owner, e))?;
    verify_governance_owner_at(
        db,
        bundle_state,
        expected_owner,
        config.chain_id,
        resolve_block_timestamp(config),
    )
}

/// Primitive-typed variant of `verify_governance_owner`. Exists so unit tests
/// can drive the on-chain check without constructing a full `GenesisConfig`.
fn verify_governance_owner_at(
    db: impl DatabaseRef,
    bundle_state: BundleState,
    expected_owner: Address,
    chain_id: u64,
    block_timestamp_secs: u64,
) -> Result<(), String> {
    let owner_txn = new_system_call_txn(
        GOVERNANCE_ADDR,
        IGovernance::ownerCall {}.abi_encode().into(),
    );

    execute_verification(
        db,
        bundle_state,
        owner_txn,
        "governance owner",
        chain_id,
        block_timestamp_secs,
        |result| {
            handle_execution_result(result, "Governance.owner()", |output_bytes| {
                let decoded = IGovernance::ownerCall::abi_decode_returns(output_bytes, false)
                    .map_err(|e| format!("Failed to decode Governance.owner(): {:?}", e))?;
                let actual_owner = decoded._0;
                if actual_owner != expected_owner {
                    let msg = format!(
                        "Governance owner mismatch: config governanceOwner={:?}, on-chain owner()={:?}",
                        expected_owner, actual_owner
                    );
                    error!("❌ {}", msg);
                    return Err(msg);
                }
                info!("✅ Governance.owner() = {:?} matches config", actual_owner);
                Ok(())
            })
        },
    )
}

/// Verify `Governance.isInitialized() == true` so a missing/skipped Genesis
/// initialize call cannot ship as a "valid" artifact.
fn verify_governance_initialized(
    db: impl DatabaseRef,
    bundle_state: BundleState,
    config: &GenesisConfig,
) -> Result<(), String> {
    verify_governance_initialized_at(
        db,
        bundle_state,
        config.chain_id,
        resolve_block_timestamp(config),
    )
}

fn verify_governance_initialized_at(
    db: impl DatabaseRef,
    bundle_state: BundleState,
    chain_id: u64,
    block_timestamp_secs: u64,
) -> Result<(), String> {
    let txn = new_system_call_txn(
        GOVERNANCE_ADDR,
        IGovernance::isInitializedCall {}.abi_encode().into(),
    );

    execute_verification(
        db,
        bundle_state,
        txn,
        "governance isInitialized",
        chain_id,
        block_timestamp_secs,
        |result| {
            handle_execution_result(result, "Governance.isInitialized()", |output_bytes| {
                let decoded = IGovernance::isInitializedCall::abi_decode_returns(output_bytes, false)
                    .map_err(|e| format!("Failed to decode Governance.isInitialized(): {:?}", e))?;
                if !decoded._0 {
                    let msg = "Governance.isInitialized() returned false — Genesis.initialize did not run".to_string();
                    error!("❌ {}", msg);
                    return Err(msg);
                }
                info!("✅ Governance.isInitialized() = true");
                Ok(())
            })
        },
    )
}

pub fn verify_result(
    db: InMemoryDB,
    bundle_state: BundleState,
    config: &GenesisConfig,
) -> Result<(), String> {
    verify_active_validators(db.clone(), bundle_state.clone(), config)?;
    verify_governance_initialized(db.clone(), bundle_state.clone(), config)?;
    verify_governance_owner(db.clone(), bundle_state.clone(), config)?;
    // Add more verification steps as needed:
    // - verify_jwks()
    // - verify_epoch_config()
    // - verify_randomness_config()
    // etc.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use revm_primitives::{AccountInfo, Bytecode, Bytes, U256};

    // The verifier hits Governance via the SYSTEM_CALLER account. revm needs
    // that caller to exist (with enough nonce headroom) before it will run
    // the call; otherwise the txn aborts before our stub bytecode executes
    // and we'd be testing the wrong thing.
    fn plant_system_caller(db: &mut InMemoryDB) {
        let info = AccountInfo {
            balance: U256::from(1_000_000_000_000_000_000_u128),
            nonce: 1,
            code_hash: revm_primitives::KECCAK_EMPTY,
            code: None,
        };
        db.insert_account_info(crate::utils::SYSTEM_CALLER, info);
    }

    /// Plant raw EVM bytecode at `addr`. The bytecode ignores calldata, so the
    /// same stub works for any function selector — sufficient for tests that
    /// only call one method per planted contract.
    fn plant_code(db: &mut InMemoryDB, addr: Address, code: Vec<u8>) {
        let bytecode = Bytecode::new_raw(Bytes::from(code));
        let info = AccountInfo {
            balance: U256::ZERO,
            nonce: 1,
            code_hash: bytecode.hash_slow(),
            code: Some(bytecode),
        };
        db.insert_account_info(addr, info);
    }

    /// Stub bytecode that always ABI-returns `addr` as a 32-byte word.
    /// PUSH20 addr; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN
    fn stub_returning_address(addr: Address) -> Vec<u8> {
        let mut code = Vec::with_capacity(29);
        code.push(0x73);
        code.extend_from_slice(addr.as_slice());
        code.extend_from_slice(&[0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3]);
        code
    }

    /// Stub bytecode that always ABI-returns a single uint256 word `value`.
    fn stub_returning_uint(value: u8) -> Vec<u8> {
        vec![0x60, value, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3]
    }

    #[test]
    fn governance_owner_matches_passes() {
        let owner: Address = "0x000000000000000000000000000000000000dEaD"
            .parse()
            .unwrap();
        let mut db = InMemoryDB::default();
        plant_system_caller(&mut db);
        plant_code(&mut db, GOVERNANCE_ADDR, stub_returning_address(owner));

        let result = verify_governance_owner_at(db, BundleState::default(), owner, 1337, 1_700_000_000);
        assert!(result.is_ok(), "expected Ok, got {:?}", result);
    }

    #[test]
    fn governance_owner_mismatch_fails() {
        let on_chain: Address = "0x000000000000000000000000000000000000dEaD"
            .parse()
            .unwrap();
        let expected: Address = "0x000000000000000000000000000000000000bEEf"
            .parse()
            .unwrap();
        let mut db = InMemoryDB::default();
        plant_system_caller(&mut db);
        plant_code(&mut db, GOVERNANCE_ADDR, stub_returning_address(on_chain));

        let result =
            verify_governance_owner_at(db, BundleState::default(), expected, 1337, 1_700_000_000);
        let err = result.expect_err("expected Err on owner mismatch");
        assert!(
            err.to_lowercase().contains("mismatch"),
            "error should mention mismatch, got: {}",
            err
        );
        // The error must surface BOTH addresses so a CI log makes the gap
        // diagnosable without re-running the tool.
        assert!(err.contains("dead"), "error should include on-chain owner, got: {}", err);
        assert!(err.contains("beef"), "error should include expected owner, got: {}", err);
    }

    #[test]
    fn governance_initialized_true_passes() {
        let mut db = InMemoryDB::default();
        plant_system_caller(&mut db);
        plant_code(&mut db, GOVERNANCE_ADDR, stub_returning_uint(1));

        let result =
            verify_governance_initialized_at(db, BundleState::default(), 1337, 1_700_000_000);
        assert!(result.is_ok(), "expected Ok, got {:?}", result);
    }

    #[test]
    fn governance_initialized_false_fails() {
        let mut db = InMemoryDB::default();
        plant_system_caller(&mut db);
        plant_code(&mut db, GOVERNANCE_ADDR, stub_returning_uint(0));

        let result =
            verify_governance_initialized_at(db, BundleState::default(), 1337, 1_700_000_000);
        let err = result.expect_err("expected Err when isInitialized=false");
        assert!(
            err.contains("initialize did not run") || err.contains("returned false"),
            "error should explain the missing initialize, got: {}",
            err
        );
    }
}
