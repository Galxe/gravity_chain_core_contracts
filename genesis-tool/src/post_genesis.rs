use revm::{DatabaseRef, InMemoryDB, db::BundleState};
use revm_primitives::{ExecutionResult, SpecId, TxEnv, hex};
use tracing::{error, info};

use crate::{
    execute::prepare_env,
    genesis::{
        GenesisConfig, call_get_active_validators, print_active_validators_result,
    },
    utils::execute_revm_sequential,
};

/// Generic template for handling execution results
///
/// This function provides a common structure for all print_* functions,
/// reducing code duplication and making the codebase more maintainable.
pub fn handle_execution_result<F>(result: &ExecutionResult, function_name: &str, success_handler: F)
where
    F: FnOnce(&[u8]),
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

            success_handler(output_bytes);
        }
        ExecutionResult::Revert { output, .. } => {
            error!("{} call reverted", function_name);
            error!("Revert output: 0x{}", hex::encode(output));
        }
        ExecutionResult::Halt { reason, .. } => {
            error!("{} call halted: {:?}", function_name, reason);
        }
    }
}

/// Generic template for verification functions
fn execute_verification<F>(
    db: impl DatabaseRef,
    bundle_state: BundleState,
    transaction: TxEnv,
    verification_name: &str,
    result_handler: F,
) where
    F: FnOnce(&ExecutionResult),
{
    let env = prepare_env();
    let r = execute_revm_sequential(db, SpecId::LATEST, env, &[transaction], Some(bundle_state));
    
    match r {
        Ok((result, _)) => {
            if let Some(execution_result) = result.get(0) {
                result_handler(execution_result);
            }
        }
        Err(e) => {
            error!(
                "verify {} error: {:?}",
                verification_name,
                e.map_db_err(|_| "Database error".to_string())
            );
        }
    }
}

fn verify_active_validators(db: impl DatabaseRef, bundle_state: BundleState, config: &GenesisConfig) {
    let get_validators_txn = call_get_active_validators();
    execute_verification(
        db,
        bundle_state,
        get_validators_txn,
        "active validators",
        |result| print_active_validators_result(result, config),
    );
}

pub fn verify_result(
    db: InMemoryDB,
    bundle_state: BundleState,
    config: &GenesisConfig,
) {
    verify_active_validators(db.clone(), bundle_state.clone(), config);
    // Add more verification steps as needed:
    // - verify_jwks()
    // - verify_epoch_config()
    // - verify_randomness_config()
    // etc.
}
