# Hackathon submission — Build an Aqua App

> **Seawall is a fully collateralized ETH put market where LP collateral is made available
> through 1inch Aqua and custom SwapVM instructions enforce the complete option lifecycle, from
> purchase through settlement.**

## Track

| **custom Aqua app** | Fully collateralized European ETH put: reserves `strike × quantity` (worst case), deterministic Black-Scholes quote, buyer-only exercise, keeperless settlement, LP collateral accounting | `contracts/core/`, `contracts/aqua/` |
| **Modify SwapVM opcodes** | Five custom instructions appended to the official `AquaOpcodes` table (indices 34–38): `OPTION_OPEN`, `OPTION_BUY`, `OPTION_EXERCISE`, `OPTION_SETTLE`, `OPTION_EXPIRE`. Official opcode numbers preserved | `contracts/swapvm/`, `RouterProgramsTest.testCustomOpcodesAreAppended`, `testSwapVMInstruction` |
| **Tests** | 94 Foundry tests + mainnet-fork test + end-to-end smoke script + React UI | `forge test`, `frontend/scripts/smoke.ts`, `frontend/` |
| **Official Aqua/SwapVM contracts used** (redeploying a modified SwapVM is allowed) | Fork demo uses the **canonical deployed Aqua registry** `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`; the router extends the official `1inch/swap-vm` v1.0.2 (the version deployed on-chain) | `test/fork/MainnetFork.t.sol`, `script/DeployFork.s.sol` |
 
## Aqua-native

- The **pool is an Aqua strategy**: `poolId = keccak256(abi.encode(buyOrder))`; the pool's collateral
  *is* the live `rawBalances(maker, router, poolId, USDC)`.
- Premiums settle through the standard SwapVM transfer phase (`AQUA.push`), payouts through
  `AQUA.pull(maker, poolId, USDC, payout, buyer)` inside `OPTION_SETTLE`.
- Deposits are `AQUA.push`; withdrawals are an app pull back to the maker, limited to
  `availableCollateral`.
- Every pull is preceded by a live balance check — if the maker's Aqua balance is unavailable the
  transaction reverts instead of paying from nowhere.

## SwapVM is the execution engine

- All five lifecycle operations run through the unmodified `SwapVM.swap()` entry point; the VM
  decodes the program, dispatches to our handlers, validates traits and performs transfers.
- Instruction encoding: `[opcode][argsLength][args]`, appended after the official 34-slot table.
- Programs:
  ```
  buy       [OPTION_OPEN][OPTION_BUY]         taker args: strike, quantity, expiry
  exercise  [OPTION_EXERCISE][OPTION_SETTLE]  taker args: positionId ×2
  settle    [OPTION_SETTLE]                   taker args: positionId
  expire    [OPTION_EXPIRE]                   taker args: positionId
  ```
- SwapVM requires `amountOut > 0`, so each instruction settles a 1 wei WETH execution marker via the
  regular transfer phase; the option payout itself is moved by the instruction.

---


### 0. Contracts (30s)

```bash
forge test          # 94 tests: pricing, lifecycle, integration, invariants, mainnet fork
```

### 1. Deploy against the canonical Aqua registry on a mainnet fork (1 min)

```bash
MAINNET_RPC_URL=<your rpc> ./script/demo-fork.sh
```

What it does:
1. starts `anvil --fork-url $MAINNET_RPC_URL --auto-impersonate --chain-id 31337 --port 8546`
2. sends **real mainnet USDC** from a whale to Bob (200,000) and Alice (10,000)
3. deploys the stack against the **canonical Aqua** `0x1111113C…` with real USDC/WETH
4. ships Bob's four Aqua strategies, registers the pool, writes `deployments/31337.json`

### 2. UI lifecycle (2 min)

```bash
cd frontend && pnpm install && pnpm dev 
```

1. **LP tab** — collateral `100,000 USDC` (live Aqua balance), reserved `0`, available `100,000`.
2. **Buyer tab** — spot from oracle, strike `2500`, 30 days, notional `10000` → quantity `4 ETH`,
   premium ≈ `132.9 USDC` (model quote), payout table shown.
   Click **BUY PUT** → position `#1 ACTIVE`.
3. **LP tab** — reserved `10,000`, premium earned `≈133`, available `≈90,133`.
4. **Position tab** — Alice's position loads from `OptionPurchased` events. Set spot `2000`,
   `SET SETTLEMENT 2000`, `ADVANCE TO EXPIRY`, then **EXERCISE** →
   payout `2,000 USDC` pulled from Bob's Aqua balance to Alice; status `SETTLED`;
   LP realized PnL `≈ −1,867`.
5. **OTM path** — buy another put, keep the price above the strike, `EXPIRE` →
   reservation released, Bob keeps the premium.

### 3. Optional evidence (1 min)

```bash
# real Chainlink ETH/USD + real USDC, with assertions
MAINNET_RPC_URL=<rpc> forge test --match-contract MainnetForkTest -vv

# terminal-only full lifecycle through the exact UI encoding
cd frontend && node --experimental-strip-types scripts/smoke.ts
```

---

## Architecture in one diagram

```
Alice ── buy / exercise ──► SeawallRouter (official SwapVM + 5 custom opcodes)
Bob  ── ship / push ──────►        │                    │
                                   ▼                    ▼
                             OptionManager          Aqua registry
                        lifecycle + accounting   ship / push / pull
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
             CollateralManager  PricingEngine  Chainlink ETH/USD
```

- Deployed canonical Aqua (fork demo): `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`
