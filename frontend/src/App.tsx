import { useState } from "react";
import { formatUnits } from "viem";

import { BuyerPanel } from "./components/BuyerPanel";
import { LpPanel } from "./components/LpPanel";
import { PositionPanel } from "./components/PositionPanel";
import { addresses } from "./config";
import { useGlobalState } from "./hooks";

type Tab = "buy" | "lp" | "position";

export default function App() {
  const { data: state, error, refresh } = useGlobalState();
  const [tab, setTab] = useState<Tab>("buy");

  return (
    <div className="app">
      <header>
        <div>
          <h1>Seawall</h1>
          <p className="muted">
            Fully collateralized ETH puts · LP collateral through 1inch Aqua · lifecycle enforced by
            custom SwapVM instructions
          </p>
          <p className="muted small">
            Local anvil demo — Bob (LP) and Alice (buyer) sign with anvil development keys. There is
            no wallet connect; a production build would use a wallet connector.
          </p>
        </div>
        <div className="header-stats">
          <div>
            <span className="muted">ETH spot</span>
            <strong>{state ? `$${formatUnits(state.spot, 18)}` : "—"}</strong>
          </div>
          <div>
            <span className="muted">Block time</span>
            <strong>
              {state ? new Date(Number(state.blockTimestamp) * 1000).toLocaleTimeString() : "—"}
            </strong>
          </div>
          <div>
            <span className="muted">Bob USDC</span>
            <strong>{state ? formatUnits(state.usdcBob, 6) : "—"}</strong>
          </div>
          <div>
            <span className="muted">Alice USDC</span>
            <strong>{state ? formatUnits(state.usdcAlice, 6) : "—"}</strong>
          </div>
          <div>
            <span className="muted">Bob (LP)</span>
            <strong className="mono">{addresses.lp.slice(0, 6)}…{addresses.lp.slice(-4)}</strong>
          </div>
          <div>
            <span className="muted">Alice (buyer)</span>
            <strong className="mono">{addresses.alice.slice(0, 6)}…{addresses.alice.slice(-4)}</strong>
          </div>
        </div>
      </header>

      {error && (
        <p className="error">
          {error}
          <br />
          Is anvil running on http://127.0.0.1:8546 with a fresh <code>DeployLocal</code> deployment?
        </p>
      )}

      {state && (
        <>
          <nav className="tabs">
            <button className={tab === "buy" ? "active" : ""} onClick={() => setTab("buy")}>
              Buyer
            </button>
            <button className={tab === "lp" ? "active" : ""} onClick={() => setTab("lp")}>
              LP
            </button>
            <button className={tab === "position" ? "active" : ""} onClick={() => setTab("position")}>
              Position
            </button>
          </nav>

          {tab === "buy" && <BuyerPanel state={state} onDone={refresh} />}
          {tab === "lp" && <LpPanel state={state} onDone={refresh} />}
          {tab === "position" && <PositionPanel state={state} onDone={refresh} />}
        </>
      )}

      <footer className="muted small">
        Model-based Black-Scholes quotes · fully collateralized (max payout = strike × quantity) ·
        keeperless deterministic settlement · payouts pulled from Aqua maker balances
      </footer>
    </div>
  );
}
