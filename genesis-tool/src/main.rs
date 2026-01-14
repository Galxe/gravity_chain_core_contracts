use anyhow::Result;
use clap::{Parser, Subcommand};
use genesis_tool::{execute, genesis::GenesisConfig, post_genesis, verify};
use serde_json;
use std::fs;
use tracing::{Level, info};

// Custom guard to ensure proper log flushing
struct LogGuard {
    _guard: Option<tracing_appender::non_blocking::WorkerGuard>,
    has_file_logging: bool,
}

impl LogGuard {
    fn new(guard: Option<tracing_appender::non_blocking::WorkerGuard>) -> Self {
        let has_file_logging = guard.is_some();
        Self {
            _guard: guard,
            has_file_logging,
        }
    }

    fn flush_and_wait(&self) {
        if self.has_file_logging {
            tracing::info!("Ensuring all logs are written to file...");
            std::thread::sleep(std::time::Duration::from_millis(1000));
        }
    }
}

impl Drop for LogGuard {
    fn drop(&mut self) {
        if self.has_file_logging {
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    }
}

#[derive(Parser, Debug)]
#[command(author, version, about = "Gravity Genesis Tool", long_about = None)]
struct Args {
    /// Enable debug logging
    #[arg(short, long, global = true)]
    debug: bool,

    /// Log file path (optional)
    #[arg(short, long, global = true)]
    log_file: Option<String>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Generate a new genesis.json file
    Generate {
        /// Byte code directory (containing .hex files for each contract)
        #[arg(short, long)]
        byte_code_dir: String,

        /// Genesis configuration file (new format with nested config structs)
        #[arg(short, long, default_value = "generate/new_genesis_config.json")]
        config_file: String,

        /// Output directory
        #[arg(short, long)]
        output: String,
    },
    /// Verify an existing genesis.json file for ABI compatibility
    Verify {
        /// Path to the genesis.json file to verify
        #[arg(short, long)]
        genesis_file: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // Initialize logging
    let level = if args.debug {
        Level::DEBUG
    } else {
        Level::INFO
    };

    // Set up logging and create log guard for proper cleanup
    let log_guard = if let Some(log_file_path) = &args.log_file {
        // Create log file directory if it doesn't exist
        if let Some(parent) = std::path::Path::new(log_file_path).parent() {
            if !parent.exists() {
                fs::create_dir_all(parent)?;
            }
        }

        // Set up logging to file
        let file_appender = tracing_appender::rolling::never("", log_file_path);
        let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

        tracing_subscriber::fmt()
            .with_max_level(level)
            .with_writer(non_blocking)
            .with_ansi(false)
            .init();

        info!("Logging to file: {}", log_file_path);
        LogGuard::new(Some(guard))
    } else {
        // Console-only logging
        tracing_subscriber::fmt().with_max_level(level).init();
        LogGuard::new(None)
    };

    // Set up panic hook to ensure logs are flushed before panic
    let has_file_logging = log_guard.has_file_logging;
    let original_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic_info| {
        if has_file_logging {
            eprintln!("PANIC occurred! Ensuring all logs are written...");
            tracing::error!("PANIC: {}", panic_info);
            tracing::error!("Flushing logs before panic exit...");
            std::thread::sleep(std::time::Duration::from_millis(1200));
            eprintln!("Log flush attempt completed");
        }
        original_hook(panic_info);
    }));

    // Run the appropriate command
    let result = match &args.command {
        Commands::Generate { byte_code_dir, config_file, output } => {
            run_generate(byte_code_dir, config_file, output).await
        }
        Commands::Verify { genesis_file } => {
            run_verify(genesis_file)
        }
    };

    // Ensure logs are flushed before exiting
    info!("Main execution completed");
    log_guard.flush_and_wait();

    result
}

async fn run_generate(byte_code_dir: &str, config_file: &str, output: &str) -> Result<()> {
    info!("Starting Gravity Genesis Generate");
    info!("Reading Genesis configuration from: {}", config_file);
    
    let config_content = fs::read_to_string(config_file)?;
    let config: GenesisConfig = serde_json::from_str(&config_content)?;
    
    info!("Genesis configuration loaded successfully");
    info!("Validator count: {}", config.validators.len());
    info!("Epoch interval: {} micros", config.epoch_interval_micros);
    info!("Major version: {}", config.major_version);

    if !fs::metadata(output).is_ok() {
        fs::create_dir_all(output).unwrap();
    }
    info!("Output directory: {}", output);

    let (db, bundle_state) = execute::genesis_generate(
        byte_code_dir,
        output,
        &config,
    );

    post_genesis::verify_result(
        db,
        bundle_state,
        &config,
    );

    info!("Gravity Genesis Generate completed successfully");
    Ok(())
}

fn run_verify(genesis_file: &str) -> Result<()> {
    info!("Starting Gravity Genesis Verify");
    
    let result = verify::verify_genesis_file(genesis_file)?;
    verify::print_verify_summary(&result);
    
    if result.success {
        info!("Gravity Genesis Verify completed successfully");
        Ok(())
    } else {
        Err(anyhow::anyhow!("Genesis verification failed"))
    }
}
