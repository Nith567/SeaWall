import { useEffect, useMemo, useState } from "react";
import { formatUnits, parseUnits } from "viem";

import { addresses, OPTION_STATUS } from "../config";
import { exercisePosition, expirePosition, setDemoSettlement, setDemoSpot, settlePosition } from "../actions";
import { increaseTime } from "../anvil";
import { loadPosition, useBuyerPositions, type GlobalState, type Position } from "../hooks";

export function PositionPanel({ state, onDone }: { state: GlobalState; onDone: () => void }) {
  const { data: alicePositions, refresh: refreshPositions } = useBuyerPositions(
    addresses.alice,
    state.nextPositionId,
  );

  const [idInput, setIdInput] = useState("1");
  const [position, setPosition] = useState<Position | null>(null);
  const [maker, setMaker] = useState<`0x${string}` | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [settlementInput, setSettlementInput] = useState("2000");
  const [spotInput, setSpotInput] = useState("3000");

  // Default to the most recent position bought by Alice.
  useEffect(() => {
    if (alicePositions && alicePositions.length > 0) {
      setIdInput((current) => (current === "1" ? alicePositions[0].id.toString() : current));
    }
  }, [alicePositions]);

  const positionId = useMemo(() => {
    try {
      return BigInt(idInput || "0");
    } catch {
      return 0n;
    }
  }, [idInput]);

  useEffect(() => {
    let alive = true;
    if (positionId === 0n) return;
    loadPosition(positionId)
      .then((result) => {
        if (!alive) return;
        setPosition(result.position);
        setMaker(result.maker);
      })
      .catch(() => {
        if (alive) {
          setPosition(null);
          setMaker(null);
        }
      });
    return () => {
      alive = false;
    };
  }, [positionId, state.nextPositionId, state.blockTimestamp]);

  const run = async (fn: () => Promise<unknown>, label: string) => {
    setBusy(true);
    setMessage(null);
    try {
      await fn();
      setMessage(`${label} confirmed`);
      refreshPositions();
      onDone();
    } catch (e) {
      setMessage((e as Error).message.split("\n")[0]);
    } finally {
      setBusy(false);
    }
  };

  const parse6 = (value: string) => {
    try {
      return parseUnits(value || "0", 6);
    } catch {
      return 0n;
    }
  };

  const status = position ? OPTION_STATUS[position.status] : null;
  const now = state.blockTimestamp;
  const expired = position ? now >= position.expiry : false;
  const windowClosed = position ? now > position.expiry + state.exerciseWindow : false;

  return (
    <section className="card">
      <h2>Positions</h2>
      <p className="muted">
        Alice's positions are loaded from the manager's <code>OptionPurchased</code> events. Anyone
        may settle; only the buyer can exercise.
      </p>

      {alicePositions && alicePositions.length > 0 && (
        <div className="position-list">
          {alicePositions.map((p) => (
            <button
              key={p.id.toString()}
              className={`position-row ${position?.id === p.id ? "selected" : ""}`}
              onClick={() => setIdInput(p.id.toString())}
            >
              <span>
                ETH PUT #{p.id.toString()} · ${formatUnits(p.strike, 6)} · {formatUnits(p.notional, 6)} USDC
              </span>
              <span className={`status status-${OPTION_STATUS[p.status]}`}>{OPTION_STATUS[p.status]}</span>
            </button>
          ))}
        </div>
      )}

      <div className="row">
        <label>
          Position id
          <input value={idInput} onChange={(e) => setIdInput(e.target.value)} />
        </label>
      </div>

      {!position && <p className="muted">No position loaded. Buy a put in the Buyer tab first.</p>}

      {position && (
        <>
          <div className="stats">
            <div>
              <span className="muted">ETH PUT #{position.id.toString()}</span>
              <strong className={`status status-${status}`}>{status}</strong>
            </div>
            <div>
              <span className="muted">Notional</span>
              <strong>{formatUnits(position.notional, 6)} USDC</strong>
            </div>
            <div>
              <span className="muted">Strike</span>
              <strong>${formatUnits(position.strike, 6)}</strong>
            </div>
            <div>
              <span className="muted">Quantity</span>
              <strong>{formatUnits(position.quantity, 18)} ETH</strong>
            </div>
            <div>
              <span className="muted">Premium paid</span>
              <strong>{formatUnits(position.premium, 6)} USDC</strong>
            </div>
            <div>
              <span className="muted">Expiry</span>
              <strong>{new Date(Number(position.expiry) * 1000).toLocaleString()}</strong>
            </div>
            <div>
              <span className="muted">Settlement price</span>
              <strong>
                {position.settlementPrice === 0n ? "—" : `$${formatUnits(position.settlementPrice, 6)}`}
              </strong>
            </div>
            <div>
              <span className="muted">Payout</span>
              <strong>{formatUnits(position.payout, 6)} USDC</strong>
            </div>
          </div>

          <div className="row">
            <button
              disabled={busy || !maker || !expired || windowClosed}
              onClick={() => run(() => exercisePosition("alice", maker!, position.id), "Exercise")}
            >
              EXERCISE
            </button>
            <button
              disabled={busy || !maker || !expired}
              onClick={() => run(() => settlePosition("bob", maker!, position.id), "Settle")}
            >
              SETTLE (keeperless)
            </button>
            <button
              disabled={busy || !maker || !expired}
              onClick={() => run(() => expirePosition("bob", maker!, position.id), "Expire")}
            >
              EXPIRE
            </button>
          </div>

          <hr />

          <h3>Local demo controls</h3>
          <p className="muted small">
            This anvil deployment uses a mock oracle, so you can move the price and the clock
            yourself. On a real deployment the spot/settlement price comes from the Chainlink ETH/USD
            feed and expiry from the chain clock — the protocol code is identical.
          </p>
          <div className="row">
            <input value={spotInput} onChange={(e) => setSpotInput(e.target.value)} />
            <button disabled={busy} onClick={() => run(() => setDemoSpot(parseUnits(spotInput || "0", 18)), "Set spot")}>
              SET SPOT
            </button>
            <input value={settlementInput} onChange={(e) => setSettlementInput(e.target.value)} />
            <button
              disabled={busy}
              onClick={() =>
                run(
                  () => setDemoSettlement(position.expiry, parseUnits(settlementInput || "0", 18)),
                  "Set settlement price",
                )
              }
            >
              SET SETTLEMENT
            </button>
          </div>
          <div className="row">
            <button
              disabled={busy}
              onClick={() => run(() => increaseTime(Number(position.expiry - now) + 1), "Time travel")}
            >
              ADVANCE TO EXPIRY
            </button>
            <button disabled={busy} onClick={() => run(() => increaseTime(86400), "Advance 1 day")}>
              +1 DAY
            </button>
          </div>
        </>
      )}

      {message && <p className="message">{message}</p>}
    </section>
  );
}
