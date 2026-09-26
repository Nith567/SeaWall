import { useState } from "react";
import { formatUnits, parseUnits } from "viem";

import { depositCollateral, withdrawCollateral } from "../actions";
import type { GlobalState } from "../hooks";

export function LpPanel({ state, onDone }: { state: GlobalState; onDone: () => void }) {
  const [depositInput, setDepositInput] = useState("10000");
  const [withdrawInput, setWithdrawInput] = useState("1000");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const run = async (fn: () => Promise<unknown>, label: string) => {
    setBusy(true);
    setMessage(null);
    try {
      await fn();
      setMessage(`${label} confirmed`);
      onDone();
    } catch (e) {
      setMessage((e as Error).message.split("\n")[0]);
    } finally {
      setBusy(false);
    }
  };

  const parse = (value: string) => {
    try {
      return parseUnits(value || "0", 6);
    } catch {
      return 0n;
    }
  };

  const p = state.pool;

  return (
    <section className="card">
      <h2>Seawall LP</h2>
      <p className="muted">
        Bob's USDC is made available through Aqua. Only <em>available</em> collateral can leave the
        pool; reserved liability is locked against live puts. No APR is shown or promised — the LP
        earns premiums and pays settlement losses.
      </p>

      <div className="stats">
        <div>
          <span className="muted">Collateral (Aqua)</span>
          <strong>{formatUnits(p.totalCollateral, 6)} USDC</strong>
        </div>
        <div>
          <span className="muted">Reserved liability</span>
          <strong>{formatUnits(p.reservedLiability, 6)} USDC</strong>
        </div>
        <div>
          <span className="muted">Available</span>
          <strong>{formatUnits(p.availableCollateral, 6)} USDC</strong>
        </div>
        <div>
          <span className="muted">Premium earned</span>
          <strong>{formatUnits(p.premiumEarned, 6)} USDC</strong>
        </div>
        <div>
          <span className="muted">Payouts</span>
          <strong>{formatUnits(p.payoutsPaid, 6)} USDC</strong>
        </div>
        <div>
          <span className="muted">Realized PnL (premiums − payouts)</span>
          <strong className="pnl">
            {p.premiumEarned >= p.payoutsPaid ? "+" : "−"}
            {formatUnits(
              p.premiumEarned >= p.payoutsPaid ? p.premiumEarned - p.payoutsPaid : p.payoutsPaid - p.premiumEarned,
              6,
            )}{" "}
            USDC
          </strong>
        </div>
      </div>

      <p className="muted small">
        Wallet: {formatUnits(state.usdcBob, 6)} USDC · Max notional per option:{" "}
        {formatUnits(p.maxNotionalPerOption, 6)} USDC
      </p>

      <div className="row">
        <input value={depositInput} onChange={(e) => setDepositInput(e.target.value)} />
        <button disabled={busy} onClick={() => run(() => depositCollateral(parse(depositInput)), "Deposit")}>
          DEPOSIT
        </button>
        <input value={withdrawInput} onChange={(e) => setWithdrawInput(e.target.value)} />
        <button disabled={busy} onClick={() => run(() => withdrawCollateral(parse(withdrawInput)), "Withdraw")}>
          WITHDRAW
        </button>
      </div>

      {message && <p className="message">{message}</p>}
    </section>
  );
}
