#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Deploy + Verify Script
# =========================================================

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

# ---------------------------------------------------------
# Load .env
# ---------------------------------------------------------
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env file not found"
  exit 1
fi

# ---------------------------------------------------------
# Required ENV Vars
# ---------------------------------------------------------
: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

CHAIN=${CHAIN:-sepolia}
ETHERSCAN_API_KEY=${ETHERSCAN_API_KEY:-${ETHERSCAN_KEY:-}}

# ---------------------------------------------------------
# Sanitize Private Key
# ---------------------------------------------------------
PK=$(printf '%s' "$PRIVATE_KEY" | tr -d '\r\n' | sed 's/^0x//i')

if ! [[ $PK =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "❌ Invalid PRIVATE_KEY format"
  exit 1
fi

export PRIVATE_KEY="0x$PK"

# ---------------------------------------------------------
# Info
# ---------------------------------------------------------
echo "================================================="
echo "🚀 Starting Deployment"
echo "================================================="
echo "Chain:        $CHAIN"
echo "RPC:          $RPC_URL"
echo "Private Key:  ${PRIVATE_KEY:0:6}...${PRIVATE_KEY: -4}"
echo "================================================="

# ---------------------------------------------------------
# RPC Check
# ---------------------------------------------------------
echo "🔍 Checking RPC connectivity..."

if ! cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1; then
  echo "❌ Cannot connect to RPC"
  exit 1
fi

echo "✅ RPC connection successful"

# ---------------------------------------------------------
# Build
# ---------------------------------------------------------
echo "🏗 Building contracts..."
forge build

# ---------------------------------------------------------
# Deploy
# ---------------------------------------------------------
echo "🚀 Deploying contracts..."

DEPLOY_LOG=$(mktemp)

forge script script/Deploy.s.sol:DeployTreasuryHook \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv | tee "$DEPLOY_LOG"

# ---------------------------------------------------------
# Extract Contract Address + TX Hash
# ---------------------------------------------------------
# The forge script output contains both a transaction hash (0x + 64 hex)
# and the deployed contract address (0x + 40 hex). Capture both so we can
# pass the creation tx hash to Etherscan verification which avoids timing
# races where Etherscan hasn't yet indexed the contract code.
TX_HASH=$(grep -Eo '0x[a-fA-F0-9]{64}' "$DEPLOY_LOG" | head -n1 || true)
DEPLOYED_ADDR=$(grep -Eo '0x[a-fA-F0-9]{40}' "$DEPLOY_LOG" | tail -n1 || true)

rm -f "$DEPLOY_LOG"

if [ -z "$DEPLOYED_ADDR" ]; then
  echo "❌ Failed to extract deployed contract address"
  exit 1
fi

echo "================================================="
echo "✅ Deployment Successful"
echo "Contract Address: $DEPLOYED_ADDR"
echo "================================================="

# ---------------------------------------------------------
# Verification
# ---------------------------------------------------------
if [ -n "${ETHERSCAN_API_KEY:-}" ]; then

  echo "🔍 Starting Etherscan verification..."

  # Small pause to give the network and Etherscan a moment to index the new code
  sleep 6

  if [ -n "${TX_HASH:-}" ]; then
    echo "Using creation transaction hash for verification: $TX_HASH"
    forge verify-contract \
      "$DEPLOYED_ADDR" \
      src/TreasuryFeeHook.sol:TreasuryFeeHook \
      --chain "$CHAIN" \
      --watch \
      --creation-transaction-hash "$TX_HASH" \
      --etherscan-api-key "$ETHERSCAN_API_KEY"
  else
    forge verify-contract \
      "$DEPLOYED_ADDR" \
      src/TreasuryFeeHook.sol:TreasuryFeeHook \
      --chain "$CHAIN" \
      --watch \
      --etherscan-api-key "$ETHERSCAN_API_KEY"
  fi

  echo "✅ Verification submitted"

else
  echo "⚠️ ETHERSCAN_API_KEY not found"
  echo "Skipping verification..."
fi

echo "================================================="
echo "🎉 All Done"
echo "================================================="