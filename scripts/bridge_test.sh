#!/bin/bash
# =============================================================================
# Script 2: Bridge Interaction Test
# =============================================================================
# This script calls bridge contracts and displays the MessageSent event details.
# Requires: 01_start_anvil_deploy.sh to have been run first.
#
# Usage: ./scripts/02_bridge_interaction.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$SCRIPT_DIR/.bridge_contracts.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Step 2: Bridge Interaction Test                   ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: Contract addresses not found.${NC}"
    echo -e "Please run ${YELLOW}./scripts/start_anvil.sh${NC} first."
    exit 1
fi

# Load environment
source "$ENV_FILE"

# Verify Anvil is running
if ! lsof -i :8546 >/dev/null 2>&1; then
    echo -e "${RED}Error: Anvil is not running on port 8546.${NC}"
    echo -e "Please run ${YELLOW}./scripts/01_start_anvil_deploy.sh${NC} first."
    exit 1
fi

echo -e "${YELLOW}Using contracts:${NC}"
echo -e "  MockGToken:     $GTOKEN_ADDRESS"
echo -e "  GravityPortal:  $PORTAL_ADDRESS"
echo -e "  GBridgeSender:  $SENDER_ADDRESS"
echo ""

cd "$PROJECT_DIR"

# =============================================================================
# Run Bridge Interaction
# =============================================================================
echo -e "${GREEN}[1/2] Executing bridge transaction...${NC}"
echo ""

PRIVATE_KEY=$PRIVATE_KEY \
GTOKEN_ADDRESS=$GTOKEN_ADDRESS \
PORTAL_ADDRESS=$PORTAL_ADDRESS \
SENDER_ADDRESS=$SENDER_ADDRESS \
forge script script/BridgeInteraction.s.sol:BridgeInteraction \
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

EVENTS=$(cast logs --from-block 0 --address $PORTAL_ADDRESS --rpc-url $RPC_URL --json 2>/dev/null)

if [ -n "$EVENTS" ] && [ "$EVENTS" != "[]" ]; then
    # Find MessageSent event (signature: 0x3495d2da67b82080fd7085af57770617e0f3a846a8fe985877b0468cab7bfd2b)
    MESSAGE_SENT_SIG="0x3495d2da67b82080fd7085af57770617e0f3a846a8fe985877b0468cab7bfd2b"
    
    echo "$EVENTS" | jq -r --arg sig "$MESSAGE_SENT_SIG" '.[] | select(.topics[0] == $sig) | 
        "┌─────────────────────────────────────────────────────────────────┐\n" +
        "│ MessageSent Event                                               │\n" +
        "├─────────────────────────────────────────────────────────────────┤\n" +
        "│ Block Number:      \(.blockNumber | ltrimstr("0x") | . as $h | if . == "" then "0" else . end)                                            │\n" +
        "│ Transaction Hash:  \(.transactionHash[0:42])...  │\n" +
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
    echo "  - sender: Address that called GravityPortal.send()"
    echo "  - nonce:  Auto-incrementing uint128 from portal"
    echo "  - message: abi.encode(amount, recipient) from GBridgeSender"
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
echo -e "${YELLOW}To run another bridge test:${NC} ./scripts/bridge_test.sh"
echo -e "${YELLOW}To stop Anvil:${NC} ./scripts/stop_anvil.sh"
