# Seawall

> **Seawall is a fully collateralized ETH put market where LP collateral is made available
> through 1inch Aqua and custom SwapVM instructions enforce the complete option lifecycle, from
> purchase through settlement.**

Aqua is the collateral layer, SwapVM is the programmable execution engine, and the option lifecycle
is encoded as five custom SwapVM instructions appended to the official `AquaOpcodes` table.

```
Buyer = option holder           LP = collateral provider / option seller
```

---

## 1. The problem

DeFi options are hard to trust:

- **Counterparty risk.** Most on-chain options are undercollateralized — the buyer's payout depends on
  a seller who may not be able to pay.
- **Custody risk.** Where options are collateralized, the collateral is usually escrowed inside the
  protocol contract, so the LP gives up control of their assets.
- **Opacity.** Premiums are often set off-chain or by a curve the LP cannot reason about, and
  settlement frequently depends on keepers or a backend.

The result: LPs won't commit size, and buyers can't be sure the protection is actually funded.

---

## 2. The solution

**Seawall** is a fully collateralized ETH put market built on 1inch Aqua and SwapVM:

- **Collateral never leaves the LP's wallet.** The LP makes USDC available through Aqua; the pool's
  collateral *is* the live Aqua balance, and payouts are pulled from it at settlement.
- **Always funded.** Every option reserves the worst-case payout, `strike × quantity`, so a payout
  can never exceed the collateral backing it.
- **Deterministic pricing.** The premium is an on-chain Black-Scholes quote enforced at purchase —
  the frontend cannot invent it.
- **No keepers, no backend.** The complete lifecycle is five custom SwapVM instructions; settlement
  is permissionless and deterministic.

### Example

An **ETH put**: the buyer pays a premium today and, if ETH settles below the strike at expiry,
receives a cash payout from the LP's collateral. [`EXAMPLE.md`](EXAMPLE.md) walks through a full
realistic trade (a DAO treasury hedging 100 ETH against a yield fund) with every number and outcome.

| Parameter  | Example |
|------------|---------|
| Spot       | $3,000  |
| Strike     | $2,500  |
| Expiry     | 30 days |
| Notional   | $10,000 |
| Quantity   | 4 ETH   |

- The LP makes USDC collateral available through Aqua.
- The buyer pays a deterministic, on-chain Black-Scholes premium.
- The protocol reserves the **maximum payout** `strike × quantity` ($10,000) of the LP's collateral,
  not the current intrinsic value.
- At expiry: if ETH < strike the buyer exercises and is paid `(strike − settlement) × quantity`
  straight out of the LP's Aqua balance; otherwise the option expires and the reservation is
  released. The LP keeps the premium.

Only one product is supported by design: **ETH put, USDC collateral, cash settled, exercise only at
expiry**.

### How Seawall is different

- **The LP keeps custody.** Other options protocols pull collateral into a vault; here it stays in the
  LP's wallet and is only *made available* through Aqua.
- **Every option is fully funded by construction.** The protocol reserves the worst case
  (`strike × quantity`), not a margin estimate.
- **The quote is protocol-enforced, not negotiated.** The premium comes from the on-chain model and
  is checked at purchase — neither side can pick a different price.
- **The lifecycle is a program, not a product contract.** Open, buy, exercise, settle and expire are
  SwapVM instructions; a new product is a new program, not a new protocol.
- **Settlement is permissionless.** No keeper, no backend, no privileged settler — and the payout
  always goes to the buyer.
- **Premiums compound into the same collateral.** The premium is pushed into the pool's Aqua
  strategy, increasing the balance that backs future options.

---

## 3. Architecture

```
                             Buyer                    LP
                               │                       │
                        buy / exercise           ship / push / withdraw
                               │                       │
                               ▼                       ▼
                    ┌──────────────────────────────────────────┐
                    │             SeawallRouter              │
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

- The LP is the **maker** and the router is the **app**. The LP calls
  `AQUA.ship(router, abi.encode(order), [USDC, WETH], [collateral, dust])`.
- Each pool is exactly one Aqua strategy: `poolId = keccak256(abi.encode(buyOrder))`, so the pool's
  collateral **is** the live Aqua balance of `(maker, router, poolId, USDC)`.
- The premium is settled through Aqua's standard transfer phase (`push`), so it lands in the maker's
  wallet and is credited to the same strategy balance.
- Payouts are `AQUA.pull(maker, poolId, USDC, payout, buyer)` — tokens move from the maker's wallet
  to the buyer inside `OPTION_SETTLE`.
- Deposits are `AQUA.push(...)`; withdrawals are a router pull back to the maker, limited to
  `availableCollateral`.
- Every pull is preceded by a live `rawBalances` check: **if the required Aqua balance is
  unavailable the transaction reverts** instead of paying out something that does not exist.

Aqua balances are allowances, not escrow: the maker keeps custody. That is the point — the protocol
never assumes it can move tokens the maker did not make available. See
[Limitations & honest risk notes](#10-limitations--honest-risk-notes).

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

## 4. Lifecycle

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
- **Exercise is buyer-only** and only inside the exercise window after expiry
  (`EXERCISE_WINDOW = 7 days`). An unexercised ITM position can be settled by anyone in that window
  (auto-exercise, paid to the buyer); after the window it can be expired, releasing the collateral.

---

## 5. Collateral accounting

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

## 6. Pricing engine

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
- **Binding, not advisory:** `OPTION_BUY` reverts if the premium paid is below the quote, so the
  engine's output is enforced by the protocol rather than trusted from the frontend.
- **Collateral-coupled:** the pool can only write what its collateral backs — every option reserves
  `strike × quantity`, and the premium can never exceed that maximum payout.

Settlement price comes from `IETHPriceOracle`. `ChainlinkETHOracle` reads the real Chainlink ETH/USD
feed: `spot()` enforces a freshness bound, and `settlementPrice(expiry)` only accepts a round
observed **at or after** expiry within a configurable delay. No backend, no single instantaneous DEX
price.

---

## 7. Repository layout

```
contracts/
├── core/
│   ├── OptionManager.sol        lifecycle state machine, authorization, settlement
│   ├── CollateralManager.sol    totalCollateral / reservedLiability / premium / payouts
│   └── PricingEngine.sol        deterministic Black-Scholes put pricing
├── aqua/
│   └── AquaAdapter.sol          safe Aqua balance checks and pulls
├── swapvm/
│   ├── SeawallRouter.sol        SwapVM router + 5 custom opcodes + order builders
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
├── demo-fork.sh           one-command fork demo (anvil + whale funding + deploy)
└── demo-terminal.sh       one-command terminal demo (anvil + deploy + narrated lifecycle)
frontend/                  React + viem UI (buyer / LP / position)
EXAMPLE.md                 realistic walkthrough with numbers and outcomes
SUBMISSION.md              project summary + demo runbook
```

---

## 8. Running it

### Contracts

```bash
forge build          # solc 0.8.30, viaIR, optimizer 200
forge test           # 99 tests: unit + integration + invariant + fork
```

The mainnet fork test uses the real deployed Aqua registry
(`0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`), real USDC/WETH and the real Chainlink ETH/USD feed.
It needs network access:

```bash
MAINNET_RPC_URL=<your rpc> forge test --match-contract MainnetForkTest -vv
```

### Fork demo (canonical Aqua, real USDC/WETH, no funds needed)

```bash
MAINNET_RPC_URL=<your rpc> ./script/demo-fork.sh
# starts anvil --fork-url ... --auto-impersonate --chain-id 31337,
# funds the demo LP and buyer (Bob/Alice) with real mainnet USDC from a whale,
# deploys against the canonical Aqua registry and runs the narrated lifecycle
```

The track explicitly allows local forks, and this path uses the **actual deployed Aqua registry**
with **real USDC/WETH**, so the token movements shown are real mainnet token transfers on a fork.

> Oracle note: the fork demo intentionally points at a `MockOracle` so the UI can move the price and
> the clock on demand. The **real Chainlink integration** lives in
> `ChainlinkETHOracle` and is proven by `test/fork/MainnetFork.t.sol`, which reads the live
> ETH/USD feed (`0x5f4eC3Df…`) and asserts premium and payout against it.

### Local demo (anvil, mock tokens)

```bash
# 1. chain
anvil --port 8546

# 2. deploy stack, fund the demo LP and buyer, ship + register the pool
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast

# 3. frontend
cd frontend && pnpm install && pnpm dev
# open http://localhost:5173
```

The UI drives the demo LP and buyer (Bob/Alice, local anvil keys) — clearly a local-demo setup — so
no wallet is needed to record the demo. If an injected wallet (MetaMask) is present, a **Connect MetaMask**
button appears: it requests accounts, auto-adds/switches to the anvil chain (`31337`,
`http://127.0.0.1:8546`) and then signs buys, exercises and settlements with the connected account.
LP actions always sign with the LP demo key.

### Terminal demo (one command, real transactions)

```bash
./script/demo-terminal.sh
# starts anvil, deploys, then prints the full lifecycle:
#   LP pool 100,000 USDC → buyer purchases a put for 132.899 USDC →
#   ETH crashes to $2,000 → exercise+settle → 2,000 USDC payout to the buyer,
#   LP realized PnL -1,867.10083 USDC
```

It broadcasts real transactions to anvil and asserts every USDC movement, so it doubles as the
"onchain token transfers" evidence. For the same lifecycle against the **canonical Aqua registry
with real mainnet USDC**, run `./script/demo-fork.sh` and then the same smoke script.

### End-to-end smoke test of the frontend encoding

```bash
anvil --port 8546
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
cd frontend && node --experimental-strip-types scripts/smoke.ts
```

It buys a put and exercises it through the exact same encoding the UI uses, asserting the premium and
payout movements (this is the script `demo-terminal.sh` runs).

---

## 9. Demo script (2 minutes)

1. **The LP supplies collateral** — the deploy script ships the LP's strategy through Aqua with
   `$100,000 USDC` and registers the pool. The LP tab shows
   `Collateral 100,000 / Reserved 0 / Available 100,000`.
2. **The buyer purchases a put** — Buyer tab: spot $3,000, strike $2,500, 30 days, $10,000 notional.
   The UI calls `PricingEngine` and shows the model premium (≈ $133). `BUY PUT` executes
   `[OPTION_OPEN][OPTION_BUY]` through SwapVM; the premium is pushed into the LP's Aqua strategy.
   The LP tab now shows `Reserved 10,000 / Available ≈ 90,133`, `Premium earned ≈ 133`.
3. **ETH falls** — Position tab → `SET SPOT 2000` (or set the settlement price directly), then
   `ADVANCE TO EXPIRY`.
4. **The buyer exercises** — `EXERCISE` runs `[OPTION_EXERCISE][OPTION_SETTLE]`: the payout
   `($2,500 − $2,000) × 4 = $2,000` is pulled from the LP's Aqua balance to the buyer. Position status
   becomes `SETTLED`, reserved liability returns to `0`, `Payouts = 2,000`, `Realized PnL ≈ −1,867`.
5. **Or let it expire** — buy another put, keep the price above the strike, `EXPIRE`; the collateral
   is released and the LP keeps the premium.

The same story runs headlessly with `./script/demo-terminal.sh` (LP pool → premium quote → purchase →
crash → exercise → payout), and against the canonical Aqua registry with real mainnet USDC via
`./script/demo-fork.sh`.

---

## 10. Limitations & honest risk notes

- **Aqua is an allowance layer, not escrow.** A maker can `dock()` a strategy unilaterally. The
  protocol then fails safely: new reservations revert and settlement reverts on the Aqua balance
  check rather than paying out from nowhere. LPs are trusted with their collateral, exactly as Aqua
  models it.
- **Model risk.** Quotes are deterministic Black-Scholes with governance-set volatility and
  risk-free rate. A mis-set volatility can misprice options; the CDF approximation has the documented
  `7.5e-8` bound. This is not a claim about fair market value.
- **Exercise window.** Exercise is only possible in `[expiry, expiry + 7 days]`. After that
  the option can be expired even if it finished in the money. This is deliberate and documented.
- **Pool limits.** `maxNotionalPerOption` and `maxTenor` are set at registration; the MVP has one
  pool per maker and one underlying.
- **Oracle.** `ChainlinkETHOracle` trusts the configured aggregator; production should consider a
  TWAP or exchange-rate fallback for the settlement leg.
- **Not audited.** Demo code.

---

## 11. Security properties covered by tests

- reentrancy (`ReentrancyGuard` on the manager, SwapVM per-order locks)
- double exercise / double settlement / settle-after-expire
- unauthorized exercise (buyer-only), expired exercise
- collateral over-allocation (`reserved + new ≤ total`)
- payout `≤ notional` (fuzz + invariants)
- decimal mismatch (USDC 6dp ↔ 1e18 model prices), rounding direction
- invalid option parameters (zero strike/quantity, past expiry, tenor/notional limits)
- invalid settlement price / not-yet-available settlement
- insufficient Aqua balance → safe revert
- replayed / invalid SwapVM instruction args (taker-arg decoding, token pair checks)
- no `tx.origin` authorization anywhere

---

## 12. Credits

Built on [1inch Aqua](https://github.com/1inch/aqua) and
[1inch SwapVM](https://github.com/1inch/swap-vm). The Ballast repository was used only as a
development template (Foundry setup and project structure); no Ballast business logic is reused.
