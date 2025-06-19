#!/bin/bash
# filepath: deploy.sh

set -e  # Exit on error

# Load environment variables from .env file if present
if [ -f .env ]; then
    source .env
fi

# Default to Sepolia testnet if not specified
NETWORK=${1:-"base-sepolia"}

# Extract network configuration
if [ "$NETWORK" = "base-sepolia" ]; then
    echo "🚀 Deploying to Base Sepolia (main vault chain)..."
    RPC_URL=${BASE_SEPOLIA_RPC_URL:-"https://sepolia.base.org"}
elif [ "$NETWORK" = "sepolia" ]; then
    echo "🚀 Deploying to Ethereum Sepolia..."
    RPC_URL=${SEPOLIA_RPC_URL:-"https://rpc.sepolia.org"}
else
    echo "❌ Unsupported network: $NETWORK"
    exit 1
fi

# Check if private key is set
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY environment variable is not set."
    echo "Please create a .env file with your PRIVATE_KEY or set it in your environment."
    exit 1
fi

# Deploy contracts
echo "📝 Deploying contracts to $NETWORK..."
echo "Using RPC URL: $RPC_URL"

forge script script/Deploy.s.sol:Deploy \
    --rpc-url $RPC_URL \
    --broadcast \
    -vvv

echo "✅ Deployment completed! Contracts are now live on $NETWORK"
echo "Note down the addresses printed above for future reference."