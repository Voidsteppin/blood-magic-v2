import { useEffect, useRef, useState } from "react";
import { CandlestickSeries, ColorType, CrosshairMode, LineStyle, createChart } from "lightweight-charts";

// Coinbase candles: public, CORS-enabled, and the same source the local price relay uses.
const CANDLES_URL = "https://api.exchange.coinbase.com/products/ETH-USD/candles";
const TIMEFRAMES = [
  { label: "1m", secs: 60 },
  { label: "5m", secs: 300 },
  { label: "15m", secs: 900 },
  { label: "1h", secs: 3600 },
];
const REFRESH_MS = 15_000;
// The chart library draws in UTC; shifting by the local offset makes the axis read in local time.
const TZ_SHIFT = -new Date().getTimezoneOffset() * 60;

async function fetchCandles(granularity) {
  const res = await fetch(`${CANDLES_URL}?granularity=${granularity}`);
  if (!res.ok) throw new Error(`Candles unavailable (${res.status})`);
  const rows = await res.json(); // [time, low, high, open, close, volume], newest first
  return rows
    .map(([time, low, high, open, close]) => ({ time: time + TZ_SHIFT, open, high, low, close }))
    .sort((a, b) => a.time - b.time);
}

function cssVar(name, fallback) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
}

export default function PriceChart({ price, position }) {
  const containerRef = useRef(null);
  const seriesRef = useRef(null);
  const lastRef = useRef(null);
  const linesRef = useRef([]);
  const [tf, setTf] = useState(TIMEFRAMES[0]);
  const [error, setError] = useState(null);

  // Create the chart once.
  useEffect(() => {
    const up = cssVar("--long", "#39ff9e");
    const down = cssVar("--short", "#ff3864");
    const chart = createChart(containerRef.current, {
      autoSize: true,
      layout: {
        background: { type: ColorType.Solid, color: "transparent" },
        textColor: cssVar("--text-2", "#cdb8f0"),
        fontFamily: cssVar("--mono", "monospace"),
        attributionLogo: false,
      },
      grid: {
        vertLines: { color: "rgba(160, 30, 60, 0.08)" },
        horzLines: { color: "rgba(160, 30, 60, 0.08)" },
      },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: "rgba(160, 30, 60, 0.4)" },
      timeScale: { borderColor: "rgba(160, 30, 60, 0.4)", timeVisible: true, secondsVisible: false, rightOffset: 4 },
    });
    seriesRef.current = chart.addSeries(CandlestickSeries, {
      upColor: up,
      downColor: down,
      borderUpColor: up,
      borderDownColor: down,
      wickUpColor: up,
      wickDownColor: down,
      priceFormat: { type: "price", precision: 2, minMove: 0.01 },
    });
    return () => {
      chart.remove();
      seriesRef.current = null;
      linesRef.current = [];
    };
  }, []);

  // Load history for the selected timeframe and keep it fresh.
  useEffect(() => {
    let cancelled = false;
    let first = true;
    async function load() {
      try {
        const candles = await fetchCandles(tf.secs);
        if (cancelled || !seriesRef.current) return;
        seriesRef.current.setData(candles);
        lastRef.current = candles.at(-1) ?? null;
        if (first) seriesRef.current.priceScale().applyOptions({ autoScale: true });
        first = false;
        setError(null);
      } catch (err) {
        if (!cancelled) setError(err.message);
      }
    }
    load();
    const id = setInterval(load, REFRESH_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [tf]);

  // Fold each oracle price into the current candle so the chart moves with the exchange.
  useEffect(() => {
    const series = seriesRef.current;
    const last = lastRef.current;
    if (!series || !last || !price) return;
    const bucket = Math.floor((Date.now() / 1000 + TZ_SHIFT) / tf.secs) * tf.secs;
    if (bucket < last.time) return;
    const candle =
      bucket === last.time
        ? { ...last, high: Math.max(last.high, price), low: Math.min(last.low, price), close: price }
        : { time: bucket, open: last.close, high: Math.max(last.close, price), low: Math.min(last.close, price), close: price };
    series.update(candle);
    lastRef.current = candle;
  }, [price, tf]);

  // Entry and liquidation lines for the open position.
  const entry = position?.entryPrice;
  const liq = position?.liquidationPrice;
  const isLong = position?.isLong;
  useEffect(() => {
    const series = seriesRef.current;
    if (!series) return;
    linesRef.current.forEach((l) => series.removePriceLine(l));
    linesRef.current = [];
    if (!entry) return;
    const side = isLong ? "Long" : "Short";
    linesRef.current.push(
      series.createPriceLine({ price: entry, color: cssVar("--accent-2", "#d6a0ff"), lineWidth: 2, lineStyle: LineStyle.Solid, title: `${side} entry` })
    );
    if (liq) {
      linesRef.current.push(
        series.createPriceLine({ price: liq, color: cssVar("--short", "#ff3864"), lineWidth: 2, lineStyle: LineStyle.Dashed, title: "Liquidation" })
      );
    }
  }, [entry, liq, isLong]);

  return (
    <section className="panel chart-panel">
      <div className="chart-head">
        <h2>ETH-USD</h2>
        <div className="tabs small chart-tf">
          {TIMEFRAMES.map((t) => (
            <button key={t.label} className={t.label === tf.label ? "tab active" : "tab"} onClick={() => setTf(t)}>
              {t.label}
            </button>
          ))}
        </div>
      </div>
      <div className="chart" ref={containerRef} />
      {error && <p className="err-text">{error}</p>}
      <p className="muted small chart-note">Candles from Coinbase. The latest candle follows the exchange's oracle price.</p>
    </section>
  );
}
