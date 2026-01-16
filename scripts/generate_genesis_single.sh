#!/bin/bash

# ============================================================================
# Single Node Genesis Generation Script
# ============================================================================
# This script generates a genesis configuration for a single-node setup
# using genesis_config_single.json.
# ============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Config file path
SINGLE_CONFIG="$PROJECT_ROOT/genesis-tool/config/genesis_config_single.json"

# Run the main genesis generation script with single config
exec "$SCRIPT_DIR/generate_genesis.sh" -c "$SINGLE_CONFIG" "$@"
