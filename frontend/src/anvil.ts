import { publicClient } from "./config";

/// Anvil cheatcodes used by the local demo controls.
export async function increaseTime(seconds: number): Promise<void> {
  if (seconds <= 0) return;
  const client = publicClient as unknown as {
    request: (args: { method: string; params: unknown[] }) => Promise<unknown>;
  };
  await client.request({ method: "evm_increaseTime", params: [seconds] });
  await client.request({ method: "evm_mine", params: [] });
}
