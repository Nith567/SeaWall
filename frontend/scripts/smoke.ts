/**
 * Terminal demo: the complete Seawall lifecycle with real transactions broadcast to a local anvil
 * chain. Bob is the LP, Alice is the buyer. Prints the story and asserts every token movement.
 *
 * Prereqs:
 *   anvil --port 8546
 *   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
 *
 * Run:
 *   node --experimental-strip-types scripts/smoke.ts
 * or one-shot:
 *   ./script/demo-terminal.sh
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
  "function poolState(bytes32 poolId) view returns (address maker, uint256 totalCollateral, uint256 reservedLiability, uint256 availableCollateral, uint256 premiumEarned, uint256 payoutsPaid, uint256 maxNotionalPerOption, uint256 maxTenor, bool active)",
  "function getPosition(uint256) view returns ((uint256 id, address buyer, bytes32 pool, uint256 notional, uint256 quantity, uint256 strike, uint256 expiry, uint256 premium, uint256 settlementPrice, uint256 payout, uint8 status))",
  "function nextPositionId() view returns (uint256)",
  "event OptionPurchased(uint256 indexed positionId, bytes32 indexed orderHash, address indexed buyer, uint256 premium)",
]);
const erc20Abi = parseAbi([
  "function approve(address, uint256) returns (bool)",
  "function allowance(address, address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
]);
const oracleAbi = parseAbi(["function setSettlementPrice(uint256 expiry, uint256 price)"]);
const paramsAbi = parseAbi([
  "function volatility() view returns (uint256)",
  "function riskFreeRate() view returns (uint256)",
]);

const router = deployment.router as `0x${string}`;
const manager = deployment.optionManager as `0x${string}`;
const usdc = deployment.usdc as `0x${string}`;
const weth = deployment.weth as `0x${string}`;
const oracle = deployment.oracle as `0x${string}`;
const lp = deployment.lp as `0x${string}`;
const aliceAddress = deployment.alice as `0x${string}`;
const poolId = deployment.poolId as `0x${string}`;
const marketParams = deployment.marketParams as `0x${string}`;
const WAD = 10n ** 18n;

const usd = (v: bigint) => `${formatUnits(v, 6)} USDC`;
const eth = (v: bigint) => `${formatUnits(v, 18)} ETH`;
const line = () => console.log("─".repeat(72));
const step = (n: number, title: string) => {
  line();
  console.log(`  ${n}. ${title}`);
  line();
};

async function poolState() {
  const raw = await publicClient.readContract({
    address: manager,
    abi: managerAbi,
    functionName: "poolState",
    args: [poolId],
  });
  return {
    total: raw[1],
    reserved: raw[2],
    available: raw[3],
    premium: raw[4],
    payouts: raw[5],
  };
}

async function usdcBalance(address: `0x${string}`) {
  return publicClient.readContract({ address: usdc, abi: erc20Abi, functionName: "balanceOf", args: [address] });
}

async function main() {
  const now = (await publicClient.getBlock({ blockTag: "latest" })).timestamp;
  const expiry = now + 30n * 86400n;
  const strike = parseUnits("2500", 6);
  const notional = parseUnits("10000", 6);
  const quantity = (notional * WAD) / strike;

  console.log("");
  line();
  console.log("  SEAWALL — fully collateralized ETH puts on 1inch Aqua + SwapVM");
  line();
  console.log(`  Aqua registry : ${deployment.aqua}`);
  console.log(`  USDC          : ${usdc}`);
  console.log(`  Bob (LP)      : ${lp}`);
  console.log(`  Alice (buyer) : ${aliceAddress}`);
  console.log(`  Pool (strategy hash) : ${poolId}`);

  step(1, "Bob's collateral pool");
  let pool = await poolState();
  console.log(`  totalCollateral     : ${usd(pool.total)}   (live Aqua balance)`);
  console.log(`  reservedLiability   : ${usd(pool.reserved)}`);
  console.log(`  availableCollateral : ${usd(pool.available)}`);

  const aliceBefore = await usdcBalance(aliceAddress);
  const bobBefore = await usdcBalance(lp);

  step(2, "Alice prices a put through the on-chain PricingEngine");
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
  const [volatility, riskFreeRate] = await Promise.all([
    publicClient.readContract({ address: marketParams, abi: paramsAbi, functionName: "volatility" }),
    publicClient.readContract({ address: marketParams, abi: paramsAbi, functionName: "riskFreeRate" }),
  ]);
  const premiumPerEth = (premium * WAD) / quantity;
  const maxLiability = (strike * quantity) / WAD;

  console.log(`  spot (oracle)   : $3,000`);
  console.log(`  strike          : $${formatUnits(strike, 6)}   (USDC per ETH, 6 decimals)`);
  console.log(`  expiry          : ${new Date(Number(expiry) * 1000).toISOString().slice(0, 10)} (30 days)`);
  console.log(`  notional        : ${usd(notional)}  →  quantity ${eth(quantity)}`);
  console.log(`  model           : Black-Scholes put · vol ${formatUnits(volatility, 16)}% · rate ${formatUnits(riskFreeRate, 16)}%`);
  console.log(`  premium / ETH   : $${formatUnits(premiumPerEth, 6)}  ×  ${eth(quantity)}`);
  console.log(`  ────────────────────────────────────────────────────────────────`);
  console.log(`  ALICE PAYS      : ${usd(premium)}   (enforced on-chain by OPTION_BUY)`);
  console.log(`  BOB RESERVES    : ${usd(maxLiability)}   (max payout = strike × quantity)`);
  console.log(`  ────────────────────────────────────────────────────────────────`);

  step(3, "Alice buys: [OPTION_OPEN][OPTION_BUY] through SwapVM (premium must match the quote)");
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
  const aliceAfterBuy = await usdcBalance(aliceAddress);
  pool = await poolState();

  console.log(`  tx              : ${buyHash}`);
  console.log(`  position #${positionId}     : ${position.buyer}  status ACTIVE`);
  console.log(`  Alice USDC      : ${usd(aliceBefore)} → ${usd(aliceAfterBuy)}  (−${usd(aliceBefore - aliceAfterBuy)})`);
  console.log(`  reservedLiability: ${usd(pool.reserved)}   available: ${usd(pool.available)}`);
  if (aliceBefore - aliceAfterBuy !== premium) throw new Error("premium mismatch");

  step(4, "ETH crashes to $2,000 and the option reaches expiry");
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
  console.log(`  settlement price: $2,000  (oracle tx ${priceHash})`);

  step(5, "Alice exercises + settles: [OPTION_EXERCISE][OPTION_SETTLE]");
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
  const aliceBeforeSettle = await usdcBalance(aliceAddress);
  const settleHash = await alice.writeContract({
    address: router,
    abi: routerAbi,
    functionName: "swap",
    args: [exerciseOrder, usdc, weth, 0n, exerciseData],
  });
  await publicClient.waitForTransactionReceipt({ hash: settleHash });

  const settled = await publicClient.readContract({
    address: manager,
    abi: managerAbi,
    functionName: "getPosition",
    args: [positionId],
  });
  const aliceAfterSettle = await usdcBalance(aliceAddress);
  const bobAfter = await usdcBalance(lp);
  pool = await poolState();

  console.log(`  tx              : ${settleHash}`);
  console.log(`  payout          : ${usd(settled.payout)}   = (strike − settlement) × quantity`);
  console.log(`  Alice USDC      : ${usd(aliceBeforeSettle)} → ${usd(aliceAfterSettle)}  (+${usd(aliceAfterSettle - aliceBeforeSettle)})`);
  console.log(`  Bob USDC        : ${usd(bobBefore)} → ${usd(bobAfter)}  (premium in, payout out)`);

  step(6, "Final state");
  console.log(`  position status : ${settled.status} (3 = SETTLED)`);
  console.log(`  reservedLiability: ${usd(pool.reserved)}   available: ${usd(pool.available)}`);
  console.log(`  premiumEarned   : ${usd(pool.premium)}   payoutsPaid: ${usd(pool.payouts)}`);
  const pnl = pool.premium >= pool.payouts ? pool.premium - pool.payouts : pool.payouts - pool.premium;
  console.log(`  LP realized PnL : ${pool.premium >= pool.payouts ? "+" : "−"}${usd(pnl)}`);
  line();

  if (settled.status !== 3) throw new Error("position not settled");
  if (settled.payout !== parseUnits("2000", 6)) throw new Error("payout mismatch");
  if (aliceAfterSettle - aliceBeforeSettle !== settled.payout) throw new Error("payout transfer mismatch");

  const events = await publicClient.getContractEvents({
    address: manager,
    abi: managerAbi,
    eventName: "OptionPurchased",
    args: { buyer: aliceAddress },
    fromBlock: BigInt((deployment as { deployBlock?: number | string }).deployBlock ?? 0),
    toBlock: "latest",
  });
  if (!events.some((e) => e.args.positionId === positionId)) throw new Error("event query mismatch");

  console.log("  DEMO PASSED — real USDC moved through Aqua: premium in, payout out.");
  line();
  console.log("");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
