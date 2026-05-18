use revm::{DatabaseRef, InMemoryDB, db::BundleState};
use revm_primitives::{ExecutionResult, SpecId, TxEnv, hex};
use tracing::{error, info};

use crate::{
    execute::{prepare_env, resolve_block_timestamp},
    genesis::{
        GenesisConfig, call_get_active_validators, print_active_validators_result,
    },
    utils::execute_revm_sequential,
};

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

pub fn verify_result(
    db: InMemoryDB,
    bundle_state: BundleState,
    config: &GenesisConfig,
) -> Result<(), String> {
    verify_active_validators(db.clone(), bundle_state.clone(), config)?;
    // Add more verification steps as needed:
    // - verify_jwks()
    // - verify_epoch_config()
    // - verify_randomness_config()
    // etc.
    Ok(())
}
