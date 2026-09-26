# Seawall

> **Seawall is a fully collateralized ETH put market where LP collateral is made available
> through 1inch Aqua and custom SwapVM instructions enforce the complete option lifecycle, from
> purchase through settlement.**

Built for the **Build an Aqua App — $5,000** hackathon. Aqua is the collateral layer, SwapVM is the
programmable execution engine, and the option lifecycle is encoded as **five custom SwapVM
instructions** appended to the official `AquaOpcodes` table.

> Hackathon judges: see [`SUBMISSION.md`](SUBMISSION.md) for the requirement-by-requirement mapping
> and a 5-minute demo runbook.

```
Alice = option buyer            Bob = option liquidity provider / seller
```

---

## 1. The product

A European **ETH put**, fully collateralized:

| Parameter  | Example |
|------------|---------|
| Spot       | $3,000  |
| Strike     | $2,500  |
| Expiry     | 30 days |
| Notional   | $10,000 |
| Quantity   | 4 ETH   |

- Bob makes USDC available through Aqua.
- Alice pays a deterministic, on-chain Black-Scholes premium.
- The protocol reserves the **maximum payout** `strike × quantity` ($10,000) of Bob's collateral,
  not the current intrinsic value.
- At expiry: if ETH < strike Alice exercises and is paid `(strike − settlement) × quantity` straight
  out of Bob's Aqua balance; otherwise the option expires and the reservation is released. Bob keeps
  the premium.

Only one product is supported by design: **ETH European put, USDC collateral, cash settled**.

---

## 2. Architecture

```
                             Alice                    Bob
                               │                       │
                        buy / exercise           ship / push / withdraw
                               │                       │
                               ▼                       ▼
                    ┌──────────────────────────────────────────┐
                    │            SeawallRouter            │
                    │  official SwapVM + AquaOpcodes + 5 new   │
                    │  option instructions (34..38)            │
                    └───────┬───────────────────────┬──────────┘
                            │                       │
              custom VM instructions          Aqua registry (IAqua)
       OPTION_OPEN/BUY/EXERCISE/SETTLE/EXPIRE   ship / push / pull
                            │                       │
                            ▼                       │
                    ┌───────────────┐               │
                    │ OptionManager │───────────────┘
                    │  lifecycle    │   live maker balances
                    └───┬───────┬───┘
                        │       │
             ┌──────────▼──┐ ┌──▼────────────┐
             │ Collateral  │ │ PricingEngine │
             │  Manager    │ │  Black-Scholes│
             └─────────────┘ └───────────────┘
                        │
              ┌─────────▼──────────┐
              │ Chainlink ETH/USD  │   spot + post-expiry settlement price
              └────────────────────┘
```

### Aqua integration (real, not bolted on)

- Bob is the **maker** and the router is the **app**. Bob calls
  `AQUA.ship(router, abi.encode(order), [USDC, WETH], [collateral, dust])`.
- Each pool is exactly one Aqua strategy: `poolId = keccak256(abi.encode(buyOrder))`, so the pool's
  collateral **is** the live Aqua balance of `(Bob, router, poolId, USDC)`.
- The premium is settled through Aqua's standard transfer phase (`push`), so it lands in Bob's wallet
  and is credited to the same strategy balance.
- Payouts are `AQUA.pull(maker, poolId, USDC, payout, buyer)` — tokens move from Bob's wallet to
  Alice inside `OPTION_SETTLE`.
- Deposits are `AQUA.push(...)`; withdrawals are a router pull back to the maker, limited to
  `availableCollateral`.
- Every pull is preceded by a live `rawBalances` check: **if the required Aqua balance is
  unavailable the transaction reverts** instead of paying out something that does not exist.

Aqua balances are allowances, not escrow: the maker keeps custody. That is the point — the protocol
never assumes it can move tokens the maker did not make available. See
[Limitations & honest risk notes](#9-limitations--honest-risk-notes).

### SwapVM integration (real custom instructions)

The router inherits the official `SwapVM` and `AquaOpcodes` from
[`1inch/swap-vm`](https://github.com/1inch/swap-vm) and appends five instructions after the official
opcode table. **All official opcode numbers are preserved.**

We build against the **`v1.0.2` tag** deliberately: it is the release actually deployed on-chain
(`AquaSwapVMRouter` `0x111111338c5091e8440b67b168bae16a668ac0de`, bound to the canonical Aqua
registry), it is the architecture the provided Ballast template targets, and its function-pointer
opcode table is designed for exactly this kind of extension. The repository's `main` branch carries
a newer, not-yet-deployed enum-dispatch architecture; porting to it would not change the app's
semantics but would decouple us from the live protocol version.

| Opcode | Instruction        | What it does |
|--------|--------------------|--------------|
| 34     | `OPTION_OPEN`      | validates terms/limits, quotes the premium, reserves `strike × quantity`, stages the option |
| 35     | `OPTION_BUY`       | validates `amountIn ≥ on-chain quote`, creates the position, records the premium |
| 36     | `OPTION_EXERCISE`  | buyer-only, inside `[expiry, expiry + EXERCISE_WINDOW]`, in the money |
| 37     | `OPTION_SETTLE`    | deterministic payout, Aqua pull to the buyer, releases the liability |
| 38     | `OPTION_EXPIRE`    | OTM at expiry (or ITM after the window), releases the reservation |

Canonical programs (built by the router, byte-for-byte):

```
buy       [OPTION_OPEN][OPTION_BUY]            taker args: abi.encode(strike, quantity, expiry)
exercise  [OPTION_EXERCISE][OPTION_SETTLE]     taker args: abi.encode(positionId, positionId)
settle    [OPTION_SETTLE]                      taker args: abi.encode(positionId)
expire    [OPTION_EXPIRE]                      taker args: abi.encode(positionId)
```

Everything runs through the unmodified SwapVM `swap()` entry point: the VM decodes the program,
dispatches to the option handlers, validates maker/taker traits, and performs the token transfers.
Because SwapVM requires a strictly positive output amount, each option instruction settles a **1 wei
WETH execution marker** through the regular transfer phase (the LP ships dust WETH per strategy). The
option payout itself is moved by `OPTION_SETTLE` directly from the pool's Aqua balance.

---

## 3. Lifecycle

```
                    ┌──────────────┐
      OPTION_OPEN   │   PENDING    │  collateral reserved, premium quoted
      (staged)      └──────┬───────┘
                           │ OPTION_BUY (same atomic tx, premium verified)
                           ▼
                    ┌──────────────┐
                    │    ACTIVE    │
                    └──┬────┬───┬──┘
        exercise       │    │   │      expire (OTM, or ITM after window)
     (buyer, in money) │    │   └──────────────────────────► EXPIRED
                       ▼    │                                  (reservation released)
                ┌──────────┐│ settle (anyone, auto-exercise ITM)
                │EXERCISED │└──────────────────────────────► SETTLED
                └────┬─────┘                                 (payout pulled to buyer)
                     │ OPTION_SETTLE
                     ▼
                  SETTLED
```

- `SETTLED → ACTIVE`, `EXPIRED → ACTIVE`, `EXERCISED → ACTIVE` are impossible: every transition is
  status-guarded.
- **No keeper dependency**: settlement is permissionless and deterministic. The caller cannot alter
  the payout, the settlement price, the recipient or the terms. The payout always goes to
  `position.buyer`.
- **Exercise is buyer-only** and only inside the European exercise window
  (`EXERCISE_WINDOW = 7 days` after expiry). An unexercised ITM position can be settled by anyone in
  that window (auto-exercise, paid to the buyer); after the window it can be expired, releasing the
  collateral (standard European semantics).

---

## 4. Collateral accounting

```
totalCollateral     = live Aqua USDC balance of the pool strategy
reservedLiability   = Σ maximumPayout of live options (ACTIVE + EXERCISED)
availableCollateral = totalCollateral − reservedLiability
```

- A new option requires `reservedLiability + strike × quantity ≤ totalCollateral`, otherwise it
  reverts.
- `maximumPayout = strike × quantity` (the payout if ETH goes to zero) — never current intrinsic.
- On settlement the full reservation is released and only the actual payout is deducted; on expiry
  the reservation is released with no payout.
- `premiumEarned`, `payoutsPaid` and `realized PnL = premiumEarned − payoutsPaid` are tracked for the
  LP dashboard. No APR is fabricated anywhere.

Invariants proven by stateful fuzzing (`test/invariant`):

1. `reservedLiability ≤ totalCollateral`
2. `reservedLiability == Σ notional of live options`
3. `payout ≤ notional` for every position
4. `totalCollateral + payoutsPaid + withdrawn == initial + deposited + premiumEarned`
5. `premiumEarned == Σ recorded premiums`

---

## 5. Pricing engine

`PricingEngine.quotePremium` is the single source of truth; the frontend never invents a premium and
`OPTION_BUY` enforces the same quote on-chain.

```
d1 = [ln(S/K) + (r + σ²/2)T] / (σ√T)
d2 = d1 − σ√T
put = K·e^(−rT)·N(−d2) − S·N(−d1)
premium = ceil(put · Q)
```

| Input        | Representation |
|--------------|----------------|
| spot, strike | 1e18 fixed point (USD per ETH) |
| quantity     | 1e18 (ETH) |
| expiry       | unix seconds |
| volatility   | 1e18 fixed point, annualised, bounded to 500% |
| riskFreeRate | 1e18 fixed point, annualised, bounded to 50% |
| tenor        | bounded to 5 years |

- `ln`, `exp`, `sqrt` come from **Solady's `FixedPointMathLib`** (well-tested, not hand-rolled).
- The normal CDF uses the Zelen & Severo / A&S 26.2.17 rational approximation with a documented
  absolute error bound of `7.5e-8`; worst-case premium error for a $3,000 spot / 4 ETH option is
  below `2e-3` USD. Reference values and fuzz monotonicity are tested.
- Premiums round **up** (favour the collateral pool); payouts round **down**.
- Quotes are explicitly **model-based** market parameters, not market-implied values.

Settlement price comes from `IETHPriceOracle`. `ChainlinkETHOracle` reads the real Chainlink ETH/USD
feed: `spot()` enforces a freshness bound, and `settlementPrice(expiry)` only accepts a round
observed **at or after** expiry within a configurable delay. No backend, no single instantaneous DEX
price.

---

## 6. Repository layout

```
contracts/
├── core/
│   ├── OptionManager.sol        lifecycle state machine, authorization, settlement
│   ├── CollateralManager.sol    totalCollateral / reservedLiability / premium / payouts
│   └── PricingEngine.sol        deterministic Black-Scholes put pricing
├── aqua/
│   └── AquaAdapter.sol          safe Aqua balance checks and pulls
├── swapvm/
│   ├── SeawallRouter.sol    SwapVM router + 5 custom opcodes + order builders
│   └── OptionInstructions.sol   the custom instruction handlers
├── oracle/
│   ├── ChainlinkETHOracle.sol   spot + post-expiry settlement
│   └── MarketParams.sol         bounded volatility / risk-free rate
├── interfaces/
└── libs/NormalDist.sol
test/
├── unit/          pricing, lifecycle, program encoding
├── integration/   full lifecycle through real Aqua + SwapVM
├── invariant/     stateful fuzzing of collateral safety
├── fork/          mainnet fork: real Aqua, USDC, WETH, Chainlink
└── mocks/
script/
├── DeployLocal.s.sol      anvil deployment + demo pool (mock tokens)
├── DeployFork.s.sol       mainnet-fork deployment against canonical Aqua + real USDC/WETH
├── RouterDeployer.sol     router deployer (forge constructor-arg workaround)
└── demo-fork.sh           one-command fork demo (anvil + whale funding + deploy)
frontend/                  React + viem UI (buyer / LP / position)
SUBMISSION.md              hackathon requirement mapping + 5-minute demo runbook
```

---

## 7. Running it

### Contracts

```bash
forge build          # solc 0.8.30, viaIR, optimizer 200
forge test           # 94 tests: unit + integration + invariant + fork
```

The mainnet fork test uses the real deployed Aqua registry
(`0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`), real USDC/WETH and the real Chainlink ETH/USD feed.
It needs network access:

```bash
MAINNET_RPC_URL=<your rpc> forge test --match-contract MainnetForkTest -vv
```

### Fork demo (recommended — canonical Aqua, real USDC/WETH, no funds needed)

```bash
MAINNET_RPC_URL=<your rpc> ./script/demo-fork.sh
# starts anvil --fork-url ... --auto-impersonate --chain-id 31337,
# funds Bob/Alice with real mainnet USDC from a whale,
# deploys against the canonical Aqua registry and writes deployments/31337.json

cd frontend && pnpm install && pnpm dev    # → http://localhost:5173
cd frontend && node --experimental-strip-types scripts/smoke.ts   # terminal proof
```

The track explicitly allows local forks, and this path uses the **actual deployed Aqua registry**
with **real USDC/WETH**, so the token movements shown are real mainnet token transfers on a fork.

> Oracle note: the fork demo intentionally points at a `MockOracle` so the UI can move the price and
> the clock on demand. The **real Chainlink integration** lives in
> `ChainlinkETHOracle` and is proven by `test/fork/MainnetFork.t.sol`, which reads the live
> ETH/USD feed (`0x5f4eC3Df…`) and asserts premium and payout against it.

### Local demo (anvil + UI, mock tokens)

```bash
# 1. chain
anvil --port 8546

# 2. deploy stack, fund Bob/Alice, ship + register Bob's pool
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast

# 3. frontend
cd frontend && pnpm install && pnpm dev
# open http://localhost:5173
```

The UI drives Bob and Alice through local anvil keys (clearly a local-demo setup), so no wallet is
needed to record the demo.

### End-to-end smoke test of the frontend encoding

```bash
anvil --port 8546
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
cd frontend && node --experimental-strip-types scripts/smoke.ts
```

It buys a put and exercises it through the exact same encoding the UI uses, asserting the premium and
payout movements.

---

