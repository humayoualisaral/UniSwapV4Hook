#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

# Load .env
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env file not found"
  exit 1
fi

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

# Sanitize private key
PK=$(printf '%s' "$PRIVATE_KEY" | tr -d '\r\n' | sed 's/^0x//i')
if ! [[ $PK =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "❌ Invalid PRIVATE_KEY format"
  exit 1
fi
export PRIVATE_KEY="0x$PK"

echo "================================================="
echo "🚀 Deploying TreasuryFeeHook"
echo "RPC: $RPC_URL"
echo "================================================="

echo "🔍 Checking RPC..."
cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1 && echo "✅ RPC OK" || { echo "❌ RPC failed"; exit 1; }

echo "🏗  Building..."
forge build

echo "🚀 Deploying..."
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv

echo "================================================="
echo "🎉 Done — copy the Hook address printed above"
echo "================================================="