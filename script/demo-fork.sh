#!/usr/bin/env bash
#
# Fork-mode demo: runs Seawall on a mainnet fork against the **canonical deployed Aqua
# registry** and **real USDC/WETH**, then leaves anvil running so the frontend can drive the
# lifecycle.
#
# Usage:
#   MAINNET_RPC_URL=<rpc> ./script/demo-fork.sh
#
# The script:
#   1. starts `anvil --fork-url ... --auto-impersonate` on port 8546
#   2. sends real USDC from a known whale to Bob (LP) and Alice (buyer)
#   3. deploys the stack against the canonical Aqua registry (script/DeployFork.s.sol)
#   4. writes deployments/31337.json for the frontend
#
# Then: cd frontend && pnpm install && pnpm dev

set -euo pipefail

RPC_URL="${MAINNET_RPC_URL:?set MAINNET_RPC_URL to a mainnet archive RPC}"
FORK_RPC="http://127.0.0.1:8546"
WHALE="${USDC_WHALE:-0x55FE002aefF02F77364de339a1292923A15844B8}"
LP="${LP_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
ALICE="${ALICE_ADDRESS:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"
USDC="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"

echo "==> starting anvil fork on ${FORK_RPC}"
pkill -f "anvil --port 8546" 2>/dev/null || true
sleep 1
# --chain-id 31337 keeps the frontend's chain definition and deployment json path stable.
anvil --fork-url "${RPC_URL}" --auto-impersonate --chain-id 31337 --port 8546 --silent > /tmp/anvil-fork.log 2>&1 &
sleep 5

echo "==> funding Bob (LP) with 200,000 real USDC from ${WHALE}"
cast send --unlocked --from "${WHALE}" "${USDC}" "transfer(address,uint256)" "${LP}" 200000000000 \
  --rpc-url "${FORK_RPC}" > /dev/null

echo "==> funding Alice with 10,000 real USDC"
cast send --unlocked --from "${WHALE}" "${USDC}" "transfer(address,uint256)" "${ALICE}" 10000000000 \
  --rpc-url "${FORK_RPC}" > /dev/null

echo "==> deploying against canonical Aqua 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a"
forge script script/DeployFork.s.sol --rpc-url "${FORK_RPC}" --broadcast < /dev/null

echo
echo "==> done. anvil is still running on ${FORK_RPC}"
echo "    start the UI:  cd frontend && pnpm install && pnpm dev"
echo "    stop anvil:    pkill -f 'anvil --port 8546'"
