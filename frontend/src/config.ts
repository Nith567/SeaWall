import { createPublicClient, createWalletClient, defineChain, http, parseAbi, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import deployment from "../../deployments/31337.json";

export const RPC_URL = "http://127.0.0.1:8546";

export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient = createPublicClient({ chain: anvil, transport: http(RPC_URL) });

// Anvil's well-known development keys (public knowledge, local demo only).
const BOB_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const ALICE_PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;

export const bob = { name: "Bob (LP)", account: privateKeyToAccount(BOB_PK) };
export const alice = { name: "Alice (Buyer)", account: privateKeyToAccount(ALICE_PK) };

export const bobWallet = createWalletClient({ account: bob.account, chain: anvil, transport: http(RPC_URL) });
export const aliceWallet = createWalletClient({ account: alice.account, chain: anvil, transport: http(RPC_URL) });

export const addresses = {
  aqua: deployment.aqua as Address,
  usdc: deployment.usdc as Address,
  weth: deployment.weth as Address,
  pricingEngine: deployment.pricingEngine as Address,
  marketParams: deployment.marketParams as Address,
  oracle: deployment.oracle as Address,
  collateralManager: deployment.collateralManager as Address,
  router: deployment.router as Address,
  optionManager: deployment.optionManager as Address,
  lp: deployment.lp as Address,
  alice: deployment.alice as Address,
  poolId: deployment.poolId as `0x${string}`,
};

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address, uint256) returns (bool)",
  "function allowance(address, address) view returns (uint256)",
]);

export const oracleAbi = parseAbi([
  "function spot() view returns (uint256)",
  "function setSpot(uint256 price)",
  "function setSettlementPrice(uint256 expiry, uint256 price)",
]);

export const managerAbi = parseAbi([
  "function quotePremium(uint256 strike, uint256 quantity, uint256 expiry) view returns (uint256)",
  "function poolState(bytes32 poolId) view returns (address maker, uint256 totalCollateral, uint256 reservedLiability, uint256 availableCollateral, uint256 premiumEarned, uint256 payoutsPaid, uint256 maxNotionalPerOption, uint256 maxTenor, bool active)",
  "function getPosition(uint256 positionId) view returns ((uint256 id, address buyer, bytes32 pool, uint256 notional, uint256 quantity, uint256 strike, uint256 expiry, uint256 premium, uint256 settlementPrice, uint256 payout, uint8 status))",
  "function nextPositionId() view returns (uint256)",
  "function EXERCISE_WINDOW() view returns (uint256)",
  "function registerPool(bytes32 poolId, uint256 maxNotionalPerOption, uint256 maxTenor)",
  "function syncPool(bytes32 poolId)",
  "function cancelPending(bytes32 orderHash)",
  "event OptionPurchased(uint256 indexed positionId, bytes32 indexed orderHash, address indexed buyer, uint256 premium)",
]);

export const routerAbi = parseAbi([
  "function buildBuyProgram() view returns (bytes)",
  "function buildExerciseProgram() view returns (bytes)",
  "function buildSettleProgram() view returns (bytes)",
  "function buildExpireProgram() view returns (bytes)",
  "function buildOrder(address maker, bytes program) view returns ((address maker, uint256 traits, bytes data))",
  "function hash((address maker, uint256 traits, bytes data) order) view returns (bytes32)",
  "function swap((address maker, uint256 traits, bytes data) order, address tokenIn, address tokenOut, uint256 amount, bytes takerTraitsAndData) returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)",
  "function withdrawCollateral(bytes32 poolId, uint256 amount)",
]);

export const aquaAbi = parseAbi([
  "function ship(address app, bytes strategy, address[] tokens, uint256[] amounts) returns (bytes32)",
  "function push(address maker, address app, bytes32 strategyHash, address token, uint256 amount)",
  "function rawBalances(address maker, address app, bytes32 strategyHash, address token) view returns (uint248 balance, uint8 tokensCount)",
]);

/// First block of the current deployment; used to bound event queries (fork-friendly).
export const deployBlock = BigInt((deployment as { deployBlock?: number | string }).deployBlock ?? 0);

export const WAD = 10n ** 18n;
export const USDC_DECIMALS = 6n;
export const ONE_USDC = 10n ** USDC_DECIMALS;
export const OPTION_STATUS = ["NONE", "ACTIVE", "EXERCISED", "SETTLED", "EXPIRED"] as const;
