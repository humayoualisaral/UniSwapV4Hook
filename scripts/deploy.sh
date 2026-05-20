set -euo pipefail


ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo ".env file not found"
  exit 1
fi


: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

CHAIN=${CHAIN:-sepolia}
ETHERSCAN_API_KEY=${ETHERSCAN_API_KEY:-${ETHERSCAN_KEY:-}}


PK=$(printf '%s' "$PRIVATE_KEY" | tr -d '\r\n' | sed 's/^0x//i')

if ! [[ $PK =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Invalid PRIVATE_KEY format"
  exit 1
fi

export PRIVATE_KEY="0x$PK"


echo "================================================="
echo "Starting Deployment"
echo "================================================="
echo "Chain:        $CHAIN"
echo "RPC:          $RPC_URL"
echo "Private Key:  ${PRIVATE_KEY:0:6}...${PRIVATE_KEY: -4}"
echo "================================================="


echo "Checking RPC connectivity..."

if ! cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1; then
  echo "Cannot connect to RPC"
  exit 1
fi

echo "RPC connection successful"


echo "Building contracts..."
forge build

echo "Deploying contracts..."

DEPLOY_LOG=$(mktemp)

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv | tee "$DEPLOY_LOG"


TX_HASH=$(grep -Eo '0x[a-fA-F0-9]{64}' "$DEPLOY_LOG" | head -n1 || true)
DEPLOYED_ADDR=$(grep -Eo '0x[a-fA-F0-9]{40}' "$DEPLOY_LOG" | tail -n1 || true)

rm -f "$DEPLOY_LOG"

if [ -z "$DEPLOYED_ADDR" ]; then
  echo "Failed to extract deployed contract address"
  exit 1
fi

echo "================================================="
echo "Deployment Successful"
echo "Contract Address: $DEPLOYED_ADDR"
echo "================================================="

