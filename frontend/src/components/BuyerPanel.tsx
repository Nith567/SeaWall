import { useEffect, useMemo, useState } from "react";
import { formatUnits, parseUnits } from "viem";

import { addresses, WAD } from "../config";
import { buyOption, quotePremium } from "../actions";
import type { GlobalState } from "../hooks";

export function BuyerPanel({ state, onDone }: { state: GlobalState; onDone: () => void }) {
  const [strikeInput, setStrikeInput] = useState("2500");
  const [notionalInput, setNotionalInput] = useState("10000");
  const [tenorDays, setTenorDays] = useState("30");
  const [premium, setPremium] = useState<bigint | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const strike = useMemo(() => {
    try {
      return parseUnits(strikeInput || "0", 6);
    } catch {
      return 0n;
    }
  }, [strikeInput]);

  const notional = useMemo(() => {
    try {
      return parseUnits(notionalInput || "0", 6);
    } catch {
      return 0n;
    }
  }, [notionalInput]);

  const quantity = strike > 0n ? (notional * WAD) / strike : 0n;
  const expiry = useMemo(
    // Use the chain clock: the demo can time-travel, wall clock cannot.
    () => state.blockTimestamp + BigInt(Math.floor(Number(tenorDays || "0") * 86400)),
    [tenorDays, state.blockTimestamp],
  );

  useEffect(() => {
    let alive = true;
    if (strike === 0n || quantity === 0n || !tenorDays) {
      setPremium(null);
      return;
    }
    quotePremium(strike, quantity, expiry)
      .then((value) => {
        if (alive) setPremium(value);
      })
      .catch(() => {
        if (alive) setPremium(null);
      });
    return () => {
      alive = false;
    };
  }, [strike, quantity, expiry, tenorDays]);

  // A few "what if" scenarios at expiry.
  const preview = useMemo(() => {
    if (!premium || quantity === 0n) return null;
    const payoutAt = (priceUsdc: bigint) => (priceUsdc >= strike ? 0n : ((strike - priceUsdc) * quantity) / WAD);
    const breakEven = strike - (premium * WAD) / quantity;
    const maxLoss = premium;
    const maxPayout = notional;
    return {
      atStrike: payoutAt(strike),
      down10: payoutAt((strike * 90n) / 100n),
      down20: payoutAt((strike * 80n) / 100n),
      breakEven,
      maxLoss,
      maxPayout,
    };
  }, [premium, quantity, strike, notional]);

  const buy = async () => {
    setBusy(true);
    setMessage(null);
    try {
      const result = await buyOption("alice", addresses.lp, strike, quantity, expiry);
      setMessage(`Bought ETH PUT for ${formatUnits(result.premium, 6)} USDC`);
      onDone();
    } catch (e) {
      setMessage((e as Error).message.split("\n")[0]);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="card">
      <h2>Buy ETH PUT</h2>
      <p className="muted">
        Alice buys downside protection from Bob's collateral pool. All amounts are USDC (6 decimals
        on-chain); strike is USDC per 1 ETH.
      </p>

      <div className="grid">
        <label>
          ETH spot (oracle)
          <input value={`$${formatUnits(state.spot, 18)}`} readOnly />
        </label>
        <label>
          Strike ($ per ETH)
          <input value={strikeInput} onChange={(e) => setStrikeInput(e.target.value)} />
        </label>
        <label>
          Expiry (days)
          <input value={tenorDays} onChange={(e) => setTenorDays(e.target.value)} />
        </label>
        <label>
          Notional ($, e.g. 10000)
          <input value={notionalInput} onChange={(e) => setNotionalInput(e.target.value)} />
        </label>
      </div>

      <div className="summary">
        <div>
          <span className="muted">Quantity (notional / strike)</span>
          <strong>{formatUnits(quantity, 18)} ETH</strong>
        </div>
        <div>
          <span className="muted">Premium (model quote)</span>
          <strong>{premium === null ? "—" : `${formatUnits(premium, 6)} USDC`}</strong>
        </div>
        <div>
          <span className="muted">Expiry</span>
          <strong>{new Date(Number(expiry) * 1000).toLocaleString()}</strong>
        </div>
      </div>

      {preview && (
        <div className="preview">
          <span className="muted small">At expiry, if ETH is…</span>
          <table>
            <tbody>
              <tr>
                <td>${formatUnits(strike, 6)} (strike)</td>
                <td>{formatUnits(preview.atStrike, 6)} USDC payout</td>
              </tr>
              <tr>
                <td>${formatUnits((strike * 90n) / 100n, 6)} (−10%)</td>
                <td>{formatUnits(preview.down10, 6)} USDC payout</td>
              </tr>
              <tr>
                <td>${formatUnits((strike * 80n) / 100n, 6)} (−20%)</td>
                <td>{formatUnits(preview.down20, 6)} USDC payout</td>
              </tr>
              <tr>
                <td>Break-even</td>
                <td>${formatUnits(preview.breakEven, 6)}</td>
              </tr>
              <tr>
                <td>Max loss / max payout</td>
                <td>
                  {formatUnits(preview.maxLoss, 6)} / {formatUnits(preview.maxPayout, 6)} USDC
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      )}

      <button onClick={buy} disabled={busy || premium === null}>
        {busy ? "Buying…" : "BUY PUT"}
      </button>
      <p className="muted small">
        The premium is a deterministic on-chain Black-Scholes quote, not a market price. The same
        value is enforced by the protocol when the option is created.
      </p>
      {message && <p className="message">{message}</p>}
    </section>
  );
}
