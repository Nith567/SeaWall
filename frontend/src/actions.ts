import type { Address } from "viem";

import {
  addresses,
  aliceWallet,
  aquaAbi,
  bobWallet,
  erc20Abi,
  managerAbi,
  oracleAbi,
  publicClient,
  routerAbi,
} from "./config";
import {
  buildTakerData,
  encodeOpenArgs,
  encodePositionId,
  encodePositionIdTwice,
  encodeOrder,
  type Order,
} from "./encoding";

export type Actor = "bob" | "alice";

export const actorAddress = (actor: Actor): Address =>
  actor === "bob" ? addresses.lp : addresses.alice;

const walletFor = (actor: Actor) => (actor === "bob" ? bobWallet : aliceWallet);

const PROGRAM_FN = {
  buy: "buildBuyProgram",
  exercise: "buildExerciseProgram",
  settle: "buildSettleProgram",
  expire: "buildExpireProgram",
} as const;

export type ProgramKind = keyof typeof PROGRAM_FN;

export async function buildOrder(maker: Address, kind: ProgramKind): Promise<Order> {
  const program = await publicClient.readContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: PROGRAM_FN[kind],
  });
  const order = await publicClient.readContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: "buildOrder",
    args: [maker, program],
  });
  return { maker: order.maker, traits: order.traits, data: order.data };
}

export async function approveIfNeeded(
  actor: Actor,
  token: Address,
  spender: Address,
  minimum: bigint,
): Promise<void> {
  const owner = actorAddress(actor);
  const allowance = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, spender],
  });
  if (allowance >= minimum) return;
  const wallet = walletFor(actor);
  const hash = await wallet.writeContract({
    address: token,
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, 2n ** 256n - 1n],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

export async function quotePremium(strike: bigint, quantity: bigint, expiry: bigint): Promise<bigint> {
  return publicClient.readContract({
    address: addresses.optionManager,
    abi: managerAbi,
    functionName: "quotePremium",
    args: [strike, quantity, expiry],
  });
}

export async function buyOption(
  actor: Actor,
  maker: Address,
  strike: bigint,
  quantity: bigint,
  expiry: bigint,
): Promise<{ tx: `0x${string}`; premium: bigint }> {
  const order = await buildOrder(maker, "buy");
  const premium = await quotePremium(strike, quantity, expiry);
  await approveIfNeeded(actor, addresses.usdc, addresses.router, premium);

  const takerData = buildTakerData({
    useTransferFromAndAquaPush: true,
    instructionsArgs: encodeOpenArgs(strike, quantity, expiry),
  });

  const wallet = walletFor(actor);
  const tx = await wallet.writeContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, premium, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return { tx, premium };
}

export async function exercisePosition(
  actor: Actor,
  maker: Address,
  positionId: bigint,
): Promise<`0x${string}`> {
  const order = await buildOrder(maker, "exercise");
  const takerData = buildTakerData({
    useTransferFromAndAquaPush: false,
    instructionsArgs: encodePositionIdTwice(positionId),
  });
  const wallet = walletFor(actor);
  const tx = await wallet.writeContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, 0n, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

export async function settlePosition(actor: Actor, maker: Address, positionId: bigint): Promise<`0x${string}`> {
  const order = await buildOrder(maker, "settle");
  const takerData = buildTakerData({
    useTransferFromAndAquaPush: false,
    instructionsArgs: encodePositionId(positionId),
  });
  const wallet = walletFor(actor);
  const tx = await wallet.writeContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, 0n, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

export async function expirePosition(actor: Actor, maker: Address, positionId: bigint): Promise<`0x${string}`> {
  const order = await buildOrder(maker, "expire");
  const takerData = buildTakerData({
    useTransferFromAndAquaPush: false,
    instructionsArgs: encodePositionId(positionId),
  });
  const wallet = walletFor(actor);
  const tx = await wallet.writeContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, 0n, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

export async function depositCollateral(amount: bigint): Promise<`0x${string}`> {
  await approveIfNeeded("bob", addresses.usdc, addresses.aqua, amount);
  const wallet = walletFor("bob");
  const tx = await wallet.writeContract({
    address: addresses.aqua,
    abi: aquaAbi,
    functionName: "push",
    args: [addresses.lp, addresses.router, addresses.poolId, addresses.usdc, amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  const sync = await wallet.writeContract({
    address: addresses.optionManager,
    abi: managerAbi,
    functionName: "syncPool",
    args: [addresses.poolId],
  });
  await publicClient.waitForTransactionReceipt({ hash: sync });
  return tx;
}

export async function withdrawCollateral(amount: bigint): Promise<`0x${string}`> {
  const wallet = walletFor("bob");
  const tx = await wallet.writeContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: "withdrawCollateral",
    args: [addresses.poolId, amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

export async function setDemoSpot(price: bigint): Promise<void> {
  const wallet = walletFor("bob");
  const hash = await wallet.writeContract({
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "setSpot",
    args: [price],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

export async function setDemoSettlement(expiry: bigint, price: bigint): Promise<void> {
  const wallet = walletFor("bob");
  const hash = await wallet.writeContract({
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "setSettlementPrice",
    args: [expiry, price],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

export { encodeOrder };
