#!/usr/bin/env bash
#
# One-command terminal demo of the full Seawall lifecycle with real transactions on a local anvil
# chain: Bob supplies collateral, Alice buys a put, ETH crashes, the option is exercised and the
# payout is pulled from Bob's Aqua balance to Alice.
#
# Usage:
#   ./script/demo-terminal.sh
#
# Leaves anvil running on http://127.0.0.1:8546 so you can open the UI afterwards:
#   cd frontend && pnpm dev

set -euo pipefail

FORK_RPC="http://127.0.0.1:8546"

echo "==> starting anvil on ${FORK_RPC}"
pkill -f "anvil --port 8546" 2>/dev/null || true
sleep 1
anvil --port 8546 --silent > /tmp/seawall-anvil.log 2>&1 &
sleep 3

echo "==> deploying Seawall (official Aqua code + SwapVM router + options stack)"
forge script script/DeployLocal.s.sol --rpc-url "${FORK_RPC}" --broadcast < /dev/null

echo "==> running the lifecycle demo (real USDC transfers)"
cd frontend
node --experimental-strip-types scripts/smoke.ts

echo
echo "==> anvil is still running on ${FORK_RPC}"
echo "    open the UI:  cd frontend && pnpm dev"
echo "    stop anvil:   pkill -f 'anvil --port 8546'"
