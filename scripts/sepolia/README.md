# Sepolia Deployment Scripts

This directory contains Foundry deployment scripts for deploying Gravity bridge contracts to Sepolia testnet.

## Prerequisites

1. **Foundry** installed
2. **Sepolia testnet ETH** in your wallet
3. **Private key** configured (never commit to git!)

## Setup Environment Variables

Create a `.env` file in the project root (or set environment variables directly):

```bash
# Required: Your wallet private key (with Sepolia ETH)
PRIVATE_KEY=0x...

# Configuration addresses (can also be set in the deployment scripts)
OWNER_ADDRESS=0x...
FEE_RECIPIENT_ADDRESS=0x...
G_TOKEN_ADDRESS=0x...       # For GBridgeSender deployment
GRAVITY_PORTAL_ADDRESS=0x... # For separate GBridgeSender deployment
```

## Deployment Flow

The contracts must be deployed in this order:

1. **GravityPortal** - Message portal for sending messages to Gravity chain
2. **G Token (ERC20)** - Your G token contract (deployed separately)
3. **GBridgeSender** - Bridge sender that locks G tokens and bridges to Gravity

## Quick Deploy (All at Once)

If you have the G Token contract already deployed:

```bash
forge script scripts/sepolia/DeployBridge.s.sol \
  --rpc-url https://sepolia.drpc.org \
  --broadcast
```

This will deploy both GravityPortal and GBridgeSender.

## Step-by-Step Deployment

### 1. Deploy GravityPortal Only

```bash
forge script scripts/sepolia/DeployBridge.s.sol \
  --rpc-url https://sepolia.drpc.org \
  --broadcast
```

The script will skip GBridgeSender if `G_TOKEN_ADDRESS` is not set.

### 2. Deploy G Token Contract

Deploy your G ERC20 token contract separately (not included in this script).

### 3. Deploy GBridgeSender

After deploying G Token, deploy GBridgeSender:

```bash
forge script scripts/sepolia/DeployGBridgeSender.s.sol \
  --rpc-url https://sepolia.drpc.org \
  --broadcast
```

## Alternative RPC URLs

Recommended RPC for Sepolia:
- `https://sepolia.drpc.org` (used in examples)

Other public RPCs:
- `https://eth-sepolia.publicstack.com`
- `https://rpc.sepolia.org`
- `https://sepolia.infura.io/v3/YOUR_INFURA_KEY`
- `https://sepolia.alchemyapi.io/v2/YOUR_ALCHEMY_KEY`

## Configuration

### GravityPortal Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `initialBaseFee` | 0.00001 ETH | Base fee for any bridge operation |
| `initialFeePerByte` | 100 gwei | Fee per byte of message payload |
| `feeRecipient` | Set via env | Address that receives bridge fees |

### Fee Calculation Example

For a bridge message with 52 bytes (`abi.encode(amount, recipient)`):

```
payloadLength = 20 (sender) + 16 (nonce) + 52 (message) = 88 bytes
fee = baseFee + (88 * feePerByte)
     = 0.01 ETH + (88 * 100 gwei)
     = 0.01 ETH + 0.0000088 ETH
     ≈ 0.010009 ETH
```

## Verification

After deployment, you can verify contracts on Etherscan:

```bash
forge verify-contract <CONTRACT_ADDRESS> \
  src/oracle/evm/GravityPortal.sol:GravityPortal \
  --constructor-args $(cast abi-encode "constructor(address,uint256,uint256,address)" "0xOWNER 10000000000000 100000000 0xRECIPIENT") \
  --chain-id 11155111 \
  --verifier etherscan \
  --etherscan-api-key YOUR_API_KEY
```

## Deployment Output

The scripts will output:
- Contract addresses after deployment
- JSON deployment summary
- Broadcast transaction details

## Scripts

| Script | Purpose |
|--------|---------|
| `DeployBridge.s.sol` | Deploy GravityPortal and optionally GBridgeSender |
| `DeployGBridgeSender.s.sol` | Deploy only GBridgeSender (use for second deployment) |
| `BridgeInteraction.s.sol` | Test bridge functionality on Sepolia |
| `bridge_test.sh` | Interactive bridge test script |

## Testing Bridge

After deployment, use the bridge test script to test the bridge functionality:

```bash
./scripts/sepolia/bridge_test.sh
```

The script will:
1. Display your G token balance
2. Prompt for bridge amount (in tokens, e.g., `1.5`)
3. Prompt for recipient address (press Enter to use your address)
4. Show required fee
5. Execute bridge transaction
6. Display MessageSent event details

### Contract Addresses (Sepolia)

- **GravityPortal**: `0x0f761B1B3c1aC9232C9015A7276692560aD6a05F`
- **GBridgeSender**: `0x3fc870008B1cc26f3614F14a726F8077227CA2c3`
- **Deployed at**: Block 10195203

## Security Notes

- **NEVER commit private keys** to version control
- Use a dedicated deployer wallet for deployments
- Consider using a multisig contract for `OWNER_ADDRESS` in production
- Review fee settings before deployment
- Test on local/devnet before deploying to testnet

## Troubleshooting

### "Owner address not configured"
Set `OWNER_ADDRESS` in your `.env` file or edit the script constant.

### "Insufficient funds"
Ensure your deployer wallet has enough Sepolia ETH for deployment + gas.

### "G Token address not configured"
Skip GBridgeSender initially, or set `G_TOKEN_ADDRESS` and run the full deployment.
