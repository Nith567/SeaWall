import { encodeAbiParameters } from "viem";

export type Order = { maker: `0x${string}`; traits: bigint; data: `0x${string}` };

export const ORDER_PARAM = {
  type: "tuple",
  components: [
    { name: "maker", type: "address" },
    { name: "traits", type: "uint256" },
    { name: "data", type: "bytes" },
  ],
} as const;

/// Replicates SwapVM's `TakerTraitsLib.build` for the subset of options we use:
/// no threshold, no custom recipient, no deadline, no hooks/callbacks, no signature.
/// Layout: [index9..index0 (uint16 BE each)][flags (uint16 BE)][instructionsArgs]
/// `TakerTraitsLib.build` packs `uint160 slicesIndexes` where index0 is the least significant
/// 16 bits, and `abi.encodePacked` is big-endian, so the encoded order is index9 -> index0.
export function buildTakerData(opts: {
  isExactIn?: boolean;
  useTransferFromAndAquaPush?: boolean;
  instructionsArgs?: `0x${string}`;
}): `0x${string}` {
  const args = opts.instructionsArgs ?? "0x";
  const argsLength = (args.length - 2) / 2;

  const indexes = [0, 0, 0, 0, 0, 0, 0, 0, 0, argsLength];
  let flags = 0;
  if (opts.isExactIn !== false) flags |= 0x0001;
  if (opts.useTransferFromAndAquaPush) flags |= 0x0040;

  const head =
    [...indexes]
      .reverse()
      .map((i) => i.toString(16).padStart(4, "0"))
      .join("") + flags.toString(16).padStart(4, "0");

  return `0x${head}${args.slice(2)}` as `0x${string}`;
}

/// `abi.encode(strike, quantity, expiry)` for OPTION_OPEN.
export function encodeOpenArgs(strike: bigint, quantity: bigint, expiry: bigint): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
    [strike, quantity, expiry],
  );
}

/// `abi.encode(positionId)` for exercise/settle/expire instructions.
export function encodePositionId(positionId: bigint): `0x${string}` {
  return encodeAbiParameters([{ type: "uint256" }], [positionId]);
}

/// `abi.encode(positionId, positionId)` for the combined EXERCISE + SETTLE program.
export function encodePositionIdTwice(positionId: bigint): `0x${string}` {
  return encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [positionId, positionId]);
}

/// `abi.encode(order)` — the Aqua strategy payload.
export function encodeOrder(order: Order): `0x${string}` {
  return encodeAbiParameters([ORDER_PARAM], [order]);
}
