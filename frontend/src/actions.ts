import type { Address, WalletClient } from "viem";

import {
  addresses,
  anvil,
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

/// A signer is either a connected browser wallet (MetaMask) or one of the local demo keys.
export type Signer = { address: Address; wallet: WalletClient };

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
  signer: Signer,
  token: Address,
  spender: Address,
  minimum: bigint,
): Promise<void> {
  const allowance = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [signer.address, spender],
  });
  if (allowance >= minimum) return;
  const hash = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
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
  signer: Signer,
  maker: Address,
  strike: bigint,
  quantity: bigint,
  expiry: bigint,
): Promise<{ tx: `0x${string}`; premium: bigint }> {
  const order = await buildOrder(maker, "buy");
  const premium = await quotePremium(strike, quantity, expiry);
  await approveIfNeeded(signer, addresses.usdc, addresses.router, premium);

  const takerData = buildTakerData({
    useTransferFromAndAquaPush: true,
    instructionsArgs: encodeOpenArgs(strike, quantity, expiry),
  });

  const tx = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, premium, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return { tx, premium };
}

export async function exercisePosition(
  signer: Signer,
  maker: Address,
  positionId: bigint,
): Promise<`0x${string}`> {
  const order = await buildOrder(maker, "exercise");
  const takerData = buildTakerData({
    useTransferFromAndAquaPush: false,
    instructionsArgs: encodePositionIdTwice(positionId),
  });
  const tx = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, 0n, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

export async function settlePosition(signer: Signer, maker: Address, positionId: bigint): Promise<`0x${string}`> {
  const order = await buildOrder(maker, "settle");
  const takerData = buildTakerData({
    useTransferFromAndAquaPush: false,
    instructionsArgs: encodePositionId(positionId),
  });
  const tx = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, 0n, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

export async function expirePosition(signer: Signer, maker: Address, positionId: bigint): Promise<`0x${string}`> {
  const order = await buildOrder(maker, "expire");
  const takerData = buildTakerData({
    useTransferFromAndAquaPush: false,
    instructionsArgs: encodePositionId(positionId),
  });
  const tx = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, addresses.usdc, addresses.weth, 0n, takerData],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

// ---------------------------------------------------------------------------
// LP actions always sign with Bob's local demo key (the pool maker).
// ---------------------------------------------------------------------------

export async function depositCollateral(amount: bigint): Promise<`0x${string}`> {
  const signer: Signer = { address: addresses.lp, wallet: bobWallet };
  await approveIfNeeded(signer, addresses.usdc, addresses.aqua, amount);
  const tx = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.aqua,
    abi: aquaAbi,
    functionName: "push",
    args: [addresses.lp, addresses.router, addresses.poolId, addresses.usdc, amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  const sync = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.optionManager,
    abi: managerAbi,
    functionName: "syncPool",
    args: [addresses.poolId],
  });
  await publicClient.waitForTransactionReceipt({ hash: sync });
  return tx;
}

export async function withdrawCollateral(amount: bigint): Promise<`0x${string}`> {
  const tx = await bobWallet.writeContract({
    chain: anvil,
    account: addresses.lp,
    address: addresses.router,
    abi: routerAbi,
    functionName: "withdrawCollateral",
    args: [addresses.poolId, amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

export async function setDemoSpot(signer: Signer, price: bigint): Promise<void> {
  const hash = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "setSpot",
    args: [price],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

export async function setDemoSettlement(signer: Signer, expiry: bigint, price: bigint): Promise<void> {
  const hash = await signer.wallet.writeContract({
    chain: anvil,
    account: signer.address,
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "setSettlementPrice",
    args: [expiry, price],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

export { encodeOrder };
