#!/bin/bash

# =============================================================================
# Gravity Chain Genesis Generation Script
# =============================================================================
# This script generates a complete genesis configuration for the Gravity Chain.
# It compiles smart contracts, extracts bytecode, runs the genesis-tool binary,
# and creates the final genesis.json file.
# =============================================================================

set -e  # Exit on any error

# Color codes for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

log_debug() {
    echo -e "${CYAN}[DEBUG]${NC} $1"
}

# Get script directory (project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Directory paths
GENESIS_TOOL_DIR="$PROJECT_ROOT/genesis-tool"
SCRIPTS_HELPER_DIR="$SCRIPT_DIR/helpers"
OUT_DIR="$PROJECT_ROOT/out"
OUTPUT_DIR="$PROJECT_ROOT/output"
CONFIG_DIR="$GENESIS_TOOL_DIR/config"

# Error handling
trap 'log_error "Script failed at line $LINENO"; exit 1' ERR

# Function to detect operating system
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Function to check if command exists
check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 is not installed or not in PATH"
        exit 1
    fi
}

# Function to check if directory exists
check_directory() {
    if [ ! -d "$1" ]; then
        log_error "Directory $1 does not exist"
        exit 1
    fi
}

# Function to check if file exists
check_file() {
    if [ ! -f "$1" ]; then
        log_error "File $1 does not exist"
        exit 1
    fi
}

# Function to create directory if it doesn't exist
create_directory() {
    if [ ! -d "$1" ]; then
        log_info "Creating directory: $1"
        mkdir -p "$1"
    fi
}

# Function to check command execution result
check_result() {
    if [ $? -eq 0 ]; then
        log_success "$1"
    else
        log_error "$1 failed"
        exit 1
    fi
}

# Default values
DEFAULT_EPOCH_INTERVAL_HOURS=2
EPOCH_INTERVAL_HOURS=$DEFAULT_EPOCH_INTERVAL_HOURS

# Function to show help
show_help() {
    echo "Gravity Chain Genesis Generation Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -i, --interval HOURS    Set epoch interval in hours (default: $DEFAULT_EPOCH_INTERVAL_HOURS)"
    echo "  -c, --config FILE       Genesis config file (default: genesis-tool/config/genesis_config.json)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Description:"
    echo "  This script generates a complete genesis configuration for the Gravity Chain."
    echo "  It compiles smart contracts, extracts bytecode, and creates genesis files."
    echo ""
    echo "Examples:"
    echo "  $0                      # Use default settings"
    echo "  $0 -i 4                 # Use 4-hour epoch interval"
    echo "  $0 -c custom.json       # Use custom config file"
    echo ""
}

# Function to parse command line arguments
parse_arguments() {
    CONFIG_FILE="$CONFIG_DIR/genesis_config.json"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--interval)
                EPOCH_INTERVAL_HOURS="$2"
                if ! [[ "$EPOCH_INTERVAL_HOURS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || (( $(echo "$EPOCH_INTERVAL_HOURS <= 0" | bc -l) )); then
                    log_error "Invalid epoch interval: $EPOCH_INTERVAL_HOURS. Must be a positive number."
                    exit 1
                fi
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--template)
                GENESIS_TEMPLATE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Main script
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Detect and log operating system
    local os=$(detect_os)
    log_info "Detected operating system: $os"
    log_info "Project root: $PROJECT_ROOT"
    
    log_step "Starting Gravity Genesis generation process..."
    log_info "Epoch interval: ${EPOCH_INTERVAL_HOURS} hours"
    log_info "Config file: $CONFIG_FILE"
    
    # Check required commands
    log_info "Checking required commands..."
    check_command "forge"
    check_command "python3"
    check_command "cargo"
    log_success "All required commands are available"
    
    # Check if we're in the right directory
    log_info "Checking project structure..."
    check_directory "$PROJECT_ROOT/src"
    check_directory "$GENESIS_TOOL_DIR"
    check_file "$CONFIG_FILE"
    log_success "Project structure is valid"
    
    # Step 1: Foundry build
    log_step "Step 1: Building contracts with Foundry..."
    cd "$PROJECT_ROOT"
    
    # Remove out directory to avoid solc compilation cache issues
    if [ -d "$OUT_DIR" ]; then
        log_info "Removing out directory to avoid solc compilation cache issues..."
        rm -rf "$OUT_DIR"
    fi
    
    log_info "Running forge build..."
    forge build
    check_result "forge build"
    
    # Verify out directory contents
    log_info "Verifying build output..."
    check_directory "$OUT_DIR"
    if [ -z "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
        log_error "out directory is empty after build"
        exit 1
    fi
    log_success "Build output verified"
    
    # Step 2: Extract bytecode
    log_step "Step 2: Extracting bytecode from compiled contracts..."
    check_file "$SCRIPTS_HELPER_DIR/extract_bytecode.py"
    log_info "Running bytecode extraction..."
    python3 "$SCRIPTS_HELPER_DIR/extract_bytecode.py" --out-dir "$OUT_DIR" --output-dir "$OUT_DIR"
    check_result "bytecode extraction"
    
    # Verify bytecode files were created
    log_info "Verifying bytecode files..."
    expected_contracts=(
        "Genesis"
        "Reconfiguration"
        "StakingConfig"
        "Staking"
        "ValidatorManagement"
        "Governance"
        "ValidatorConfig"
        "Blocker"
        "Timestamp"
        "JWKManager"
        "NativeOracle"
        "RandomnessConfig"
        "DKG"
        "GovernanceConfig"
        "EpochConfig"
        "VersionConfig"
        "ConsensusConfig"
        "ExecutionConfig"
        "OracleTaskConfig"
        "OnDemandOracleTaskConfig"
    )
    for contract in "${expected_contracts[@]}"; do
        if [ ! -f "$OUT_DIR/${contract}.hex" ]; then
            log_error "Missing bytecode file: $OUT_DIR/${contract}.hex"
            exit 1
        fi
    done
    log_success "All bytecode files verified"
    
    # Step 3: Generate genesis with Rust binary
    log_step "Step 3: Generating genesis accounts and contracts..."
    create_directory "$OUTPUT_DIR"
    
    # Convert epoch interval hours to microseconds and update config
    # 1 hour = 3600 seconds = 3,600,000,000 microseconds
    EPOCH_INTERVAL_MICROS=$(echo "$EPOCH_INTERVAL_HOURS * 3600000000" | bc | cut -d'.' -f1)
    log_info "Epoch interval: ${EPOCH_INTERVAL_HOURS} hours = ${EPOCH_INTERVAL_MICROS} microseconds"
    
    # Create a modified config with the updated epoch interval
    MODIFIED_CONFIG_FILE="$OUTPUT_DIR/genesis_config_modified.json"
    log_info "Creating modified config with epoch interval..."
    python3 -c "
import json
import sys

with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)

config['epochIntervalMicros'] = $EPOCH_INTERVAL_MICROS

with open('$MODIFIED_CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)

print(f'Updated epoch_interval_micros to {$EPOCH_INTERVAL_MICROS}')
"
    
    log_info "Building and running genesis-tool binary..."
    cd "$GENESIS_TOOL_DIR"
    cargo run --release -- generate \
        --byte-code-dir "$OUT_DIR" \
        --config-file "$MODIFIED_CONFIG_FILE" \
        --output "$OUTPUT_DIR" \
        --log-file "$OUTPUT_DIR/genesis_generation.log"
    check_result "genesis generation"
    
    # Verify output files
    log_info "Verifying genesis output files..."
    check_file "$OUTPUT_DIR/genesis_accounts.json"
    check_file "$OUTPUT_DIR/genesis_contracts.json"
    check_file "$OUTPUT_DIR/bundle_state.json"
    log_success "Genesis files generated successfully"
    
    # Step 4: Combine account allocation
    log_step "Step 4: Combining account allocation..."
    cd "$PROJECT_ROOT"
    check_file "$SCRIPTS_HELPER_DIR/combine_account_alloc.py"
    log_info "Running account allocation combination..."
    python3 "$SCRIPTS_HELPER_DIR/combine_account_alloc.py" "$OUTPUT_DIR/genesis_contracts.json" "$OUTPUT_DIR/genesis_accounts.json"
    check_result "account allocation combination"
    
    # Verify combined file
    log_info "Verifying combined allocation file..."
    check_file "$PROJECT_ROOT/account_alloc.json"
    log_success "Combined allocation file created"
    
    # Step 4.5: Fix hex string lengths
    log_step "Step 4.5: Fixing hex string lengths..."
    check_file "$SCRIPTS_HELPER_DIR/fix_hex_length.py"
    
    log_info "Fixing hex string lengths in account_alloc.json..."
    python3 "$SCRIPTS_HELPER_DIR/fix_hex_length.py" "$PROJECT_ROOT/account_alloc.json"
    check_result "hex string length fixing"
    
    log_success "Hex string lengths fixed successfully"
    
    # Step 5: Generate final genesis.json
    log_step "Step 5: Generating final genesis.json..."
    check_file "$SCRIPTS_HELPER_DIR/genesis_generate.py"
    check_file "$CONFIG_DIR/genesis_template.json"
    check_file "$PROJECT_ROOT/account_alloc.json"
    
    # Determine which template to use
    TEMPLATE_FILE="${GENESIS_TEMPLATE:-$CONFIG_DIR/genesis_template.json}"
    check_file "$TEMPLATE_FILE"
    
    log_info "Running final genesis generation using template: $TEMPLATE_FILE"
    python3 "$SCRIPTS_HELPER_DIR/genesis_generate.py" \
        --template "$TEMPLATE_FILE" \
        --account-alloc "$PROJECT_ROOT/account_alloc.json" \
        --output "$PROJECT_ROOT/genesis.json"
    check_result "final genesis generation"
    
    # Verify final genesis file
    log_info "Verifying final genesis file..."
    check_file "$PROJECT_ROOT/genesis.json"
    log_success "Final genesis.json created"
    
    # Final summary
    log_step "Genesis generation completed successfully!"
    log_info "Generated files:"
    log_info "  - genesis.json (main genesis file)"
    log_info "  - account_alloc.json (combined account allocation)"
    log_info "  - output/genesis_accounts.json (account states)"
    log_info "  - output/genesis_contracts.json (contract bytecodes)"
    log_info "  - output/bundle_state.json (bundle state)"
    log_info "  - output/genesis_generation.log (generation logs)"
    
    log_success "All steps completed successfully!"
}

# Run main function
main "$@"
