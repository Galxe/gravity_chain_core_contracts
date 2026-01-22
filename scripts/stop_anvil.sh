#!/bin/bash
# =============================================================================
# Script 3: Stop Anvil
# =============================================================================
# This script stops the Anvil testnet running on port 8546.
#
# Usage: ./scripts/03_stop_anvil.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.bridge_contracts.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Stopping Anvil on port 8546...${NC}"

# Method 1: Kill by PID from env file
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    if [ -n "$ANVIL_PID" ] && kill -0 $ANVIL_PID 2>/dev/null; then
        kill $ANVIL_PID 2>/dev/null
        echo -e "${GREEN}Killed Anvil process (PID: $ANVIL_PID)${NC}"
    fi
    rm -f "$ENV_FILE"
fi

# Method 2: Kill by port (fallback)
PIDS=$(lsof -ti :8546 2>/dev/null)
if [ -n "$PIDS" ]; then
    echo "$PIDS" | xargs kill 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}Stopped processes on port 8546${NC}"
fi

# Method 3: Kill anvil by name (fallback)
pkill -f "anvil.*--port 8546" 2>/dev/null || true

# Verify
if lsof -i :8546 >/dev/null 2>&1; then
    echo -e "${RED}Warning: Port 8546 still in use${NC}"
else
    echo -e "${GREEN}Anvil stopped successfully${NC}"
fi
