import { useMemo, useState } from "react";
import { formatUnits } from "viem";

import { BuyerPanel } from "./components/BuyerPanel";
import { LpPanel } from "./components/LpPanel";
import { PositionPanel } from "./components/PositionPanel";
import { addresses, alice, aliceWallet, injectedWallet } from "./config";
import { useGlobalState } from "./hooks";
import type { Signer } from "./actions";
import { useWallet } from "./wallet";

type Tab = "buy" | "lp" | "position";

export default function App() {
  const { data: state, error, refresh } = useGlobalState();
  const [tab, setTab] = useState<Tab>("buy");
  const wallet = useWallet();

  // Buyer/settlement actions sign with the connected wallet when available, otherwise with Alice's
  // local demo key. LP actions always sign with Bob's demo key.
  const signer: Signer = useMemo(
    () =>
      wallet.address
        ? { address: wallet.address, wallet: injectedWallet(wallet.address) }
        : { address: alice.account.address, wallet: aliceWallet },
    [wallet.address],
  );

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
            {wallet.address
              ? "Connected wallet signs buys, exercises and settlements."
              : "Local demo: Bob (LP) and Alice (buyer) sign with anvil development keys. Connect a wallet to act with your own account."}
          </p>
        </div>
        <div className="header-right">
          <div className="wallet">
            {wallet.address ? (
              <>
                <span className="muted small">Connected</span>
                <strong className="mono">
                  {wallet.address.slice(0, 6)}…{wallet.address.slice(-4)}
                </strong>
                <button className="ghost" onClick={wallet.disconnect}>
                  Disconnect
                </button>
              </>
            ) : wallet.available ? (
              <button onClick={wallet.connect} disabled={wallet.connecting}>
                {wallet.connecting ? "Connecting…" : "Connect MetaMask"}
              </button>
            ) : (
              <span className="muted small">Demo keys (no injected wallet)</span>
            )}
            {wallet.error && <span className="error small">{wallet.error}</span>}
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
              <strong className="mono">
                {addresses.lp.slice(0, 6)}…{addresses.lp.slice(-4)}
              </strong>
            </div>
            <div>
              <span className="muted">Alice (buyer)</span>
              <strong className="mono">
                {addresses.alice.slice(0, 6)}…{addresses.alice.slice(-4)}
              </strong>
            </div>
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

          {tab === "buy" && <BuyerPanel state={state} signer={signer} onDone={refresh} />}
          {tab === "lp" && <LpPanel state={state} onDone={refresh} />}
          {tab === "position" && <PositionPanel state={state} signer={signer} onDone={refresh} />}
        </>
      )}

      <footer className="muted small">
        Model-based Black-Scholes quotes · fully collateralized (max payout = strike × quantity) ·
        keeperless deterministic settlement · payouts pulled from Aqua maker balances
      </footer>
    </div>
  );
}
