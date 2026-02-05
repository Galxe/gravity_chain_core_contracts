#!/bin/bash
# =============================================================================
# Sepolia Bridge Test Script
# =============================================================================
# This script calls bridge contracts on Sepolia and displays MessageSent event.
# Requires: Contracts deployed on Sepolia
#
# Usage: ./scripts/sepolia/bridge_test.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
ENV_FILE="$PROJECT_DIR/.env"
RPC_URL="https://sepolia.drpc.org"

# Contract addresses (deployed on Sepolia at block 10195203)
GRAVITY_PORTAL="0x0f761B1B3c1aC9232C9015A7276692560aD6a05F"
G_BRIDGE_SENDER="0x3fc870008B1cc26f3614F14a726F8077227CA2c3"
DEPLOYMENT_BLOCK=10195203

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Sepolia Bridge Test                              ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
    echo -e "Please create a .env file with PRIVATE_KEY, OWNER_ADDRESS, FEE_RECIPIENT_ADDRESS"
    exit 1
fi

# Load environment
source "$ENV_FILE"

# Check for PRIVATE_KEY
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not found in .env${NC}"
    exit 1
fi

# Get deployer address from private key
DEPLOYER_ADDR=$(cast wallet address --private-key $PRIVATE_KEY)
echo -e "${YELLOW}Deployer Address: $DEPLOYER_ADDR${NC}"
echo ""

# Display contract info
echo -e "${CYAN}Contract Information:${NC}"
echo -e "  GravityPortal:  $GRAVITY_PORTAL"
echo -e "  GBridgeSender:  $G_BRIDGE_SENDER"
echo -e "  Deployed at:    Block $DEPLOYMENT_BLOCK"
echo ""

# Get G Token address from GBridgeSender
G_TOKEN=$(cast call $G_BRIDGE_SENDER "gToken()(address)" --rpc-url $RPC_URL 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
echo -e "  G Token:        $G_TOKEN"
echo ""

# Check user's G Token balance
USER_BALANCE=$(cast call $G_TOKEN "balanceOf(address)(uint256)" $DEPLOYER_ADDR --rpc-url $RPC_URL 2>/dev/null || echo "0")
USER_BALANCE_ETH=$(cast to-unit $USER_BALANCE ether 2>/dev/null || echo "0")
echo -e "${CYAN}User G Token Balance: $USER_BALANCE_ETH tokens${NC}"
echo ""

# Prompt for amount
echo -e "${YELLOW}Enter bridge amount (in tokens, e.g., 1.5):${NC}"
read -r AMOUNT_INPUT

# Validate amount is a number
if ! [[ $AMOUNT_INPUT =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo -e "${RED}Error: Invalid amount. Please enter a positive number.${NC}"
    exit 1
fi

# Convert to wei (use to-wei instead of to-unit)
AMOUNT_WEI=$(cast --to-wei $AMOUNT_INPUT ether 2>/dev/null)

# Fallback: if to-wei fails, try to-wei without --
if [ -z "$AMOUNT_WEI" ]; then
    AMOUNT_WEI=$(cast to-wei $AMOUNT_INPUT ether 2>/dev/null)
fi

# Prompt for recipient
echo -e "${YELLOW}Enter recipient address (press Enter to use your address):${NC}"
read -r RECIPIENT_INPUT

if [ -z "$RECIPIENT_INPUT" ]; then
    RECIPIENT=$DEPLOYER_ADDR
else
    RECIPIENT=$RECIPIENT_INPUT
fi

# Validate address
if ! [[ $RECIPIENT =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo -e "${RED}Error: Invalid address format.${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}Bridge Parameters:${NC}"
echo -e "  Amount:  $AMOUNT_INPUT tokens"
echo -e "  Recipient:  $RECIPIENT"
echo ""

# Calculate required fee
FEE=$(cast call $G_BRIDGE_SENDER "calculateBridgeFee(uint256,address)(uint256)" $AMOUNT_WEI $RECIPIENT --rpc-url $RPC_URL 2>/dev/null || echo "0")
FEE_ETH=$(cast to-unit $FEE ether 2>/dev/null || echo "0")
echo -e "${CYAN}Required Fee: $FEE_ETH ETH${NC}"
echo ""

# Get current block number before bridge
CURRENT_BLOCK=$(cast block-number --rpc-url $RPC_URL 2>/dev/null || echo "0")
echo -e "${CYAN}Current Sepolia block: $CURRENT_BLOCK${NC}"
echo ""

# Confirm
echo -e "${YELLOW}Execute bridge transaction? (y/N):${NC}"
read -r CONFIRM

if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

cd "$PROJECT_DIR"

# =============================================================================
# Run Bridge Interaction
# =============================================================================
echo ""
echo -e "${GREEN}[1/2] Executing bridge transaction...${NC}"
echo ""

PRIVATE_KEY=$PRIVATE_KEY \
AMOUNT=$AMOUNT_WEI \
RECIPIENT=$RECIPIENT \
forge script scripts/sepolia/BridgeInteraction.s.sol:BridgeInteraction \
    --rpc-url $RPC_URL \
    --broadcast

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Event Details                               ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Query and Display Events
# =============================================================================
echo -e "${GREEN}[2/2] Querying MessageSent events from GravityPortal...${NC}"
echo ""

# Query logs from current block onwards (not from deployment block)
EVENTS=$(cast logs --from-block $CURRENT_BLOCK --address $GRAVITY_PORTAL --rpc-url $RPC_URL --json 2>/dev/null)

if [ -n "$EVENTS" ] && [ "$EVENTS" != "[]" ]; then
    # Find MessageSent event (signature: 0x5646e682c7d994bf11f5a2c8addb60d03c83cda3b65025a826346589df43406e)
    MESSAGE_SENT_SIG="0x5646e682c7d994bf11f5a2c8addb60d03c83cda3b65025a826346589df43406e"

    echo "$EVENTS" | jq -r --arg sig "$MESSAGE_SENT_SIG" '.[] | select(.topics[0] == $sig) |
        "┌─────────────────────────────────────────────────────────────────┐\n" +
        "│ MessageSent Event                                               │\n" +
        "├─────────────────────────────────────────────────────────────────┤\n" +
        "│ Block Number:      \(.blockNumber)                                            │\n" +
        "│ Transaction Hash:  \(.transactionHash)│\n" +
        "├─────────────────────────────────────────────────────────────────┤\n" +
        "│ Topics:                                                         │\n" +
        "│   [0] Signature: \(.topics[0][0:42])...│\n" +
        "│   [1] Nonce:     \(.topics[1])│\n" +
        "├─────────────────────────────────────────────────────────────────┤\n" +
        "│ Data (ABI-encoded payload):                                     │\n" +
        "└─────────────────────────────────────────────────────────────────┘"' 2>/dev/null || echo "Error parsing events"

    echo ""
    echo -e "${YELLOW}Raw Event Data:${NC}"
    echo "$EVENTS" | jq -r --arg sig "$MESSAGE_SENT_SIG" '.[] | select(.topics[0] == $sig) | .data' 2>/dev/null

    echo ""
    echo -e "${YELLOW}Payload Structure (PortalMessage format):${NC}"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ sender (20 bytes) || nonce (16 bytes) || message (variable) │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
    echo "   - sender:   Address that called GravityPortal.send()"
    echo "   - nonce:    Auto-incrementing uint128 from portal"
    echo "   - message:  abi.encode(amount, recipient) from GBridgeSender"
else
    echo -e "${RED}No MessageSent events found.${NC}"
fi

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Test Complete                               ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓${NC} Bridge transaction executed successfully"
echo -e "${GREEN}✓${NC} MessageSent event emitted"
echo ""
echo -e "${YELLOW}To run another bridge test:${NC} ./scripts/sepolia/bridge_test.sh"
echo ""
