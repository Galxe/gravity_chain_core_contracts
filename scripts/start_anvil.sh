#!/bin/bash
# =============================================================================
# Script 1: Start Anvil and Deploy Bridge Contracts
# =============================================================================
# This script starts a local Anvil testnet and deploys the bridge contracts.
# Contract addresses are saved to .bridge_contracts.env for other scripts.
#
# Usage: ./scripts/01_start_anvil_deploy.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$SCRIPT_DIR/.bridge_contracts.env"

# Anvil default private key (Account 0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RPC_URL="http://localhost:8546"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Step 1: Start Anvil & Deploy Contracts                 ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if Anvil is already running on port 8546
if lsof -i :8546 >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Port 8546 is already in use. Stopping existing process...${NC}"
    "$SCRIPT_DIR/stop_anvil.sh" 2>/dev/null || true
    sleep 1
fi

# =============================================================================
# Step 1: Start Anvil
# =============================================================================
echo -e "${GREEN}[1/2] Starting Anvil local testnet on port 8546 (block-time: 1s)...${NC}"
anvil --port 8546 --block-time 1 &
ANVIL_PID=$!
sleep 2

# Verify Anvil is running
if ! kill -0 $ANVIL_PID 2>/dev/null; then
    echo -e "${RED}Error: Failed to start Anvil${NC}"
    exit 1
fi
echo -e "  Anvil running at $RPC_URL (PID: $ANVIL_PID)"
echo ""

cd "$PROJECT_DIR"

# =============================================================================
# Step 2: Deploy Contracts
# =============================================================================
echo -e "${GREEN}[2/2] Deploying contracts...${NC}"
echo ""

DEPLOY_OUTPUT=$(PRIVATE_KEY=$PRIVATE_KEY forge script script/DeployBridgeLocal.s.sol:DeployBridgeLocal \
    --rpc-url $RPC_URL \
    --broadcast 2>&1)

# Parse deployed contract addresses
GTOKEN_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "MockGToken deployed at:" | awk '{print $NF}')
PORTAL_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "GravityPortal deployed at:" | awk '{print $NF}')
SENDER_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "GBridgeSender deployed at:" | awk '{print $NF}')

if [ -z "$GTOKEN_ADDRESS" ] || [ -z "$PORTAL_ADDRESS" ] || [ -z "$SENDER_ADDRESS" ]; then
    echo -e "${RED}Error: Failed to parse contract addresses from deployment output${NC}"
    echo "$DEPLOY_OUTPUT"
    exit 1
fi

# Save to env file for other scripts
cat > "$ENV_FILE" << EOF
# Bridge Contract Addresses (auto-generated)
ANVIL_PID=$ANVIL_PID
RPC_URL=$RPC_URL
PRIVATE_KEY=$PRIVATE_KEY
GTOKEN_ADDRESS=$GTOKEN_ADDRESS
PORTAL_ADDRESS=$PORTAL_ADDRESS
SENDER_ADDRESS=$SENDER_ADDRESS
EOF

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Deployment Complete                         ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Anvil:${NC}"
echo -e "  PID: $ANVIL_PID"
echo -e "  RPC: $RPC_URL"
echo ""
echo -e "${YELLOW}Contract Addresses:${NC}"
echo -e "  MockGToken:     $GTOKEN_ADDRESS"
echo -e "  GravityPortal:  $PORTAL_ADDRESS"
echo -e "  GBridgeSender:  $SENDER_ADDRESS"
echo ""
echo -e "${GREEN}Ready! Run ${YELLOW}./scripts/bridge_test.sh${GREEN} to test bridge.${NC}"
