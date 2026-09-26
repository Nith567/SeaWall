import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";

import { addresses, deployBlock, erc20Abi, managerAbi, oracleAbi, publicClient } from "./config";

/// viem returns named objects for single named-tuple outputs and arrays for multiple outputs.
/// Normalise both shapes.
function asNamed<T>(value: unknown, keys: string[]): T {
  if (Array.isArray(value)) {
    const result: Record<string, unknown> = {};
    keys.forEach((key, index) => {
      result[key] = value[index];
    });
    return result as T;
  }
  return value as T;
}

export function usePoll<T>(loader: () => Promise<T>, intervalMs = 4000, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const refresh = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    let alive = true;
    const load = async () => {
      try {
        const next = await loader();
        if (alive) {
          setData(next);
          setError(null);
        }
      } catch (e) {
        if (alive) setError((e as Error).message ?? String(e));
      }
    };
    void load();
    const id = setInterval(load, intervalMs);
    return () => {
      alive = false;
      clearInterval(id);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nonce, intervalMs, ...deps]);

  return { data, error, refresh };
}

export type PoolState = {
  maker: Address;
  totalCollateral: bigint;
  reservedLiability: bigint;
  availableCollateral: bigint;
  premiumEarned: bigint;
  payoutsPaid: bigint;
  maxNotionalPerOption: bigint;
  maxTenor: bigint;
  active: boolean;
};

export type Position = {
  id: bigint;
  buyer: Address;
  pool: `0x${string}`;
  notional: bigint;
  quantity: bigint;
  strike: bigint;
  expiry: bigint;
  premium: bigint;
  settlementPrice: bigint;
  payout: bigint;
  status: number;
};

export type GlobalState = {
  spot: bigint;
  pool: PoolState;
  exerciseWindow: bigint;
  nextPositionId: bigint;
  usdcBob: bigint;
  usdcAlice: bigint;
  wethBob: bigint;
  wethAlice: bigint;
  blockTimestamp: bigint;
};

export function useGlobalState() {
  return usePoll<GlobalState>(async () => {
    const [spot, poolRaw, exerciseWindow, nextPositionId, usdcBob, usdcAlice, wethBob, wethAlice, block] =
      await Promise.all([
        publicClient.readContract({ address: addresses.oracle, abi: oracleAbi, functionName: "spot" }),
        publicClient.readContract({
          address: addresses.optionManager,
          abi: managerAbi,
          functionName: "poolState",
          args: [addresses.poolId],
        }),
        publicClient.readContract({
          address: addresses.optionManager,
          abi: managerAbi,
          functionName: "EXERCISE_WINDOW",
        }),
        publicClient.readContract({ address: addresses.optionManager, abi: managerAbi, functionName: "nextPositionId" }),
        publicClient.readContract({
          address: addresses.usdc,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [addresses.lp],
        }),
        publicClient.readContract({
          address: addresses.usdc,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [addresses.alice],
        }),
        publicClient.readContract({
          address: addresses.weth,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [addresses.lp],
        }),
        publicClient.readContract({
          address: addresses.weth,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [addresses.alice],
        }),
        publicClient.getBlock({ blockTag: "latest" }),
      ]);

    const pool = asNamed<PoolState>(poolRaw, [
      "maker",
      "totalCollateral",
      "reservedLiability",
      "availableCollateral",
      "premiumEarned",
      "payoutsPaid",
      "maxNotionalPerOption",
      "maxTenor",
      "active",
    ]);

    return {
      spot,
      pool,
      exerciseWindow,
      nextPositionId,
      usdcBob,
      usdcAlice,
      wethBob,
      wethAlice,
      blockTimestamp: block.timestamp,
    };
  });
}

/// Loads every position ever bought by `buyer` from the manager's `OptionPurchased` events.
export function useBuyerPositions(buyer: Address, refreshKey: bigint) {
  return usePoll<Position[]>(
    async () => {
      const logs = await publicClient.getContractEvents({
        address: addresses.optionManager,
        abi: managerAbi,
        eventName: "OptionPurchased",
        args: { buyer },
        fromBlock: deployBlock,
        toBlock: "latest",
      });
      const ids = new Map<string, bigint>();
      for (const log of logs) {
        const id = log.args.positionId;
        if (id !== undefined) ids.set(id.toString(), id);
      }
      const sorted = [...ids.values()].sort((a, b) => (a < b ? 1 : -1));
      return Promise.all(sorted.map(async (id) => (await loadPosition(id)).position));
    },
    5000,
    [buyer, refreshKey],
  );
}

export async function loadPosition(positionId: bigint): Promise<{ position: Position; maker: Address }> {
  const raw = await publicClient.readContract({
    address: addresses.optionManager,
    abi: managerAbi,
    functionName: "getPosition",
    args: [positionId],
  });
  const decoded = asNamed<Record<string, unknown>>(raw, [
    "id",
    "buyer",
    "pool",
    "notional",
    "quantity",
    "strike",
    "expiry",
    "premium",
    "settlementPrice",
    "payout",
    "status",
  ]);
  const position: Position = {
    id: decoded.id as bigint,
    buyer: decoded.buyer as Address,
    pool: decoded.pool as `0x${string}`,
    notional: decoded.notional as bigint,
    quantity: decoded.quantity as bigint,
    strike: decoded.strike as bigint,
    expiry: decoded.expiry as bigint,
    premium: decoded.premium as bigint,
    settlementPrice: decoded.settlementPrice as bigint,
    payout: decoded.payout as bigint,
    status: Number(decoded.status),
  };
  const poolRaw = await publicClient.readContract({
    address: addresses.optionManager,
    abi: managerAbi,
    functionName: "poolState",
    args: [position.pool],
  });
  const pool = asNamed<PoolState>(poolRaw, [
    "maker",
    "totalCollateral",
    "reservedLiability",
    "availableCollateral",
    "premiumEarned",
    "payoutsPaid",
    "maxNotionalPerOption",
    "maxTenor",
    "active",
  ]);
  return { position, maker: pool.maker };
}
