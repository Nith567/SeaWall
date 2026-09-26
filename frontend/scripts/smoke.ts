/**
 * End-to-end smoke test for the frontend's encoding + action layer.
 *
 * Prereqs:
 *   anvil --port 8546
 *   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
 *
 * Run:
 *   node --experimental-strip-types scripts/smoke.ts
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatUnits,
  http,
  parseAbi,
  parseUnits,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { buildTakerData, encodeOpenArgs, encodePositionIdTwice } from "../src/encoding.ts";

const here = dirname(fileURLToPath(import.meta.url));
const deployment = JSON.parse(readFileSync(join(here, "../../deployments/31337.json"), "utf8"));

const RPC = "http://127.0.0.1:8546";
const chain = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const publicClient = createPublicClient({ chain, transport: http(RPC) });
const bob = createWalletClient({
  account: privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"),
  chain,
  transport: http(RPC),
});
const alice = createWalletClient({
  account: privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"),
  chain,
  transport: http(RPC),
});

const routerAbi = parseAbi([
  "function buildBuyProgram() view returns (bytes)",
  "function buildExerciseProgram() view returns (bytes)",
  "function buildOrder(address maker, bytes program) view returns ((address maker, uint256 traits, bytes data))",
  "function swap((address maker, uint256 traits, bytes data) order, address tokenIn, address tokenOut, uint256 amount, bytes takerTraitsAndData) returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)",
]);
const managerAbi = parseAbi([
  "function quotePremium(uint256 strike, uint256 quantity, uint256 expiry) view returns (uint256)",
  "function getPosition(uint256) view returns ((uint256 id, address buyer, bytes32 pool, uint256 notional, uint256 quantity, uint256 strike, uint256 expiry, uint256 premium, uint256 settlementPrice, uint256 payout, uint8 status))",
  "function nextPositionId() view returns (uint256)",
  "event OptionPurchased(uint256 indexed positionId, bytes32 indexed orderHash, address indexed buyer, uint256 premium)",
]);
const erc20Abi = parseAbi([
  "function approve(address, uint256) returns (bool)",
  "function allowance(address, address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
]);
const oracleAbi = parseAbi([
  "function setSettlementPrice(uint256 expiry, uint256 price)",
  "function setSpot(uint256 price)",
]);

const router = deployment.router as `0x${string}`;
const manager = deployment.optionManager as `0x${string}`;
const usdc = deployment.usdc as `0x${string}`;
const weth = deployment.weth as `0x${string}`;
const oracle = deployment.oracle as `0x${string}`;
const lp = deployment.lp as `0x${string}`;
const aliceAddress = deployment.alice as `0x${string}`;
const WAD = 10n ** 18n;

async function main() {
  // Use the chain clock: the demo can time-travel, wall clock cannot.
  const now = (await publicClient.getBlock({ blockTag: "latest" })).timestamp;
  const expiry = now + 30n * 86400n;
  const strike = parseUnits("2500", 6);
  const notional = parseUnits("10000", 6);
  const quantity = (notional * WAD) / strike;

  const program = await publicClient.readContract({
    address: router,
    abi: routerAbi,
    functionName: "buildBuyProgram",
  });
  const order = await publicClient.readContract({
    address: router,
    abi: routerAbi,
    functionName: "buildOrder",
    args: [lp, program],
  });
  const premium = await publicClient.readContract({
    address: manager,
    abi: managerAbi,
    functionName: "quotePremium",
    args: [strike, quantity, expiry],
  });

  const allowance = await publicClient.readContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "allowance",
    args: [aliceAddress, router],
  });
  if (allowance < premium) {
    const approveHash = await alice.writeContract({
      address: usdc,
      abi: erc20Abi,
      functionName: "approve",
      args: [router, 2n ** 256n - 1n],
    });
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
  }

  const takerData = buildTakerData({
    useTransferFromAndAquaPush: true,
    instructionsArgs: encodeOpenArgs(strike, quantity, expiry),
  });

  const aliceBefore = await publicClient.readContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [aliceAddress],
  });

  const buyHash = await alice.writeContract({
    address: router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, usdc, weth, premium, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: buyHash });

  const nextId = await publicClient.readContract({
    address: manager,
    abi: managerAbi,
    functionName: "nextPositionId",
  });
  const positionId = nextId - 1n;

  const position = await publicClient.readContract({
    address: manager,
    abi: managerAbi,
    functionName: "getPosition",
    args: [positionId],
  });
  const aliceAfter = await publicClient.readContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [aliceAddress],
  });

  console.log(`premium:        ${formatUnits(premium, 6)} USDC`);
  console.log(`buyer:          ${position.buyer}`);
  console.log(`status:         ${position.status} (1 = ACTIVE)`);
  console.log(`notional:       ${formatUnits(position.notional, 6)} USDC`);
  console.log(`alice delta:    -${formatUnits(aliceBefore - aliceAfter, 6)} USDC`);

  if (position.status !== 1) throw new Error("position not active");
  if (aliceBefore - aliceAfter !== premium) throw new Error("premium mismatch");
  if (position.buyer.toLowerCase() !== aliceAddress.toLowerCase()) throw new Error("buyer mismatch");

  // --- simulate expiry: time travel + settlement price, then exercise + settle ---
  await publicClient.request({ method: "evm_increaseTime", params: [30 * 86400 + 1] } as never);
  await publicClient.request({ method: "evm_mine", params: [] } as never);

  const settlement = parseUnits("2000", 18);
  const priceHash = await bob.writeContract({
    address: oracle,
    abi: oracleAbi,
    functionName: "setSettlementPrice",
    args: [expiry, settlement],
  });
  await publicClient.waitForTransactionReceipt({ hash: priceHash });

  const exerciseProgram = await publicClient.readContract({
    address: router,
    abi: routerAbi,
    functionName: "buildExerciseProgram",
  });
  const exerciseOrder = await publicClient.readContract({
    address: router,
    abi: routerAbi,
    functionName: "buildOrder",
    args: [lp, exerciseProgram],
  });
  const exerciseData = buildTakerData({
    useTransferFromAndAquaPush: false,
    instructionsArgs: encodePositionIdTwice(positionId),
  });

  const before = await publicClient.readContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [aliceAddress],
  });
  const exerciseHash = await alice.writeContract({
    address: router,
    abi: routerAbi,
    functionName: "swap",
    args: [exerciseOrder, usdc, weth, 0n, exerciseData],
  });
  await publicClient.waitForTransactionReceipt({ hash: exerciseHash });
  const after = await publicClient.readContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [aliceAddress],
  });

  const settled = await publicClient.readContract({
    address: manager,
    abi: managerAbi,
    functionName: "getPosition",
    args: [positionId],
  });
  console.log(`payout:         ${formatUnits(settled.payout, 6)} USDC`);
  console.log(`status:         ${settled.status} (3 = SETTLED)`);
  console.log(`alice delta:    +${formatUnits(after - before, 6)} USDC`);

  if (settled.status !== 3) throw new Error("position not settled");
  if (settled.payout !== parseUnits("2000", 6)) throw new Error("payout mismatch");
  if (after - before !== settled.payout) throw new Error("payout transfer mismatch");

  // The UI lists Alice's positions from these events.
  const events = await publicClient.getContractEvents({
    address: manager,
    abi: managerAbi,
    eventName: "OptionPurchased",
    args: { buyer: aliceAddress },
    fromBlock: BigInt((deployment as { deployBlock?: number | string }).deployBlock ?? 0),
    toBlock: "latest",
  });
  console.log(`position id:    ${positionId}`);
  console.log(`buyer events:   ${events.length}`);
  if (!events.some((e) => e.args.positionId === positionId)) throw new Error("event query mismatch");

  console.log("\nSMOKE TEST PASSED");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
