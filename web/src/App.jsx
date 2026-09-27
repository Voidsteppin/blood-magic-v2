import { useCallback, useEffect, useMemo, useState } from "react";
import { BrowserProvider, Contract, MaxUint256, formatUnits, parseUnits } from "ethers";
import { MARKET, MARKET_ID, chain, contracts, deployments, describeError, isDeployed, readProvider } from "./chain.js";

const FEED_ABI = ["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)", "function decimals() view returns (uint8)"];
const POLL_MS = 5000;
const MAX_LEVERAGE = 50;

// ---------- formatting ----------
const n = (v, d = 2) => Number(v).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const usd = (v, d = 2) => `$${n(v, d)}`;
const fromUsdc = (v) => Number(formatUnits(v, 6));
const fromPrice = (v) => Number(formatUnits(v, 18));
const shortAddr = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

// ---------- wallet ----------
function useWallet() {
  const [account, setAccount] = useState(null);
  const [walletChainId, setWalletChainId] = useState(null);

  useEffect(() => {
    const eth = window.ethereum;
    if (!eth) return;
    eth.request({ method: "eth_accounts" }).then((a) => setAccount(a[0] ?? null));
    eth.request({ method: "eth_chainId" }).then((id) => setWalletChainId(Number(id)));
    const onAccounts = (a) => setAccount(a[0] ?? null);
    const onChain = (id) => setWalletChainId(Number(id));
    eth.on?.("accountsChanged", onAccounts);
    eth.on?.("chainChanged", onChain);
    return () => {
      eth.removeListener?.("accountsChanged", onAccounts);
      eth.removeListener?.("chainChanged", onChain);
    };
  }, []);

  const connect = async () => {
    if (!window.ethereum) throw new Error("No wallet found. Install MetaMask or Rabby.");
    const a = await window.ethereum.request({ method: "eth_requestAccounts" });
    setAccount(a[0] ?? null);
  };

  const switchChain = async () => {
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: chain.addParams.chainId }] });
    } catch (err) {
      if (err.code === 4902) {
        await window.ethereum.request({ method: "wallet_addEthereumChain", params: [chain.addParams] });
      } else throw err;
    }
  };

  const getSigner = async () => new BrowserProvider(window.ethereum).getSigner();

  return { account, wrongChain: account && walletChainId !== deployments.chainId, connect, switchChain, getSigner };
}

// ---------- on-chain data ----------
function useMarketData(account) {
  const [data, setData] = useState(null);
  const [tick, setTick] = useState(0);
  const refresh = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!readProvider) return;
    let cancelled = false;
    const feed = new Contract(deployments.markets[0].feed, FEED_ABI, readProvider);

    async function load() {
      try {
        const [round, decimals] = await Promise.all([feed.latestRoundData(), feed.decimals()]);
        const next = {
          price: Number(formatUnits(round[1], decimals)),
          priceAge: Math.max(0, Math.round(Date.now() / 1000 - Number(round[3]))),
        };

        if (isDeployed) {
          const { exchange, usdc } = contracts(readProvider);
          const [market, poolValue, poolBalance, oi, supply, feeBps, maxUtil] = await Promise.all([
            exchange.markets(MARKET_ID),
            exchange.poolValue(),
            exchange.poolBalance(),
            exchange.totalOpenInterest(),
            exchange.totalSupply(),
            exchange.feeBps(),
            exchange.maxUtilizationBps(),
          ]);
          Object.assign(next, {
            maxLeverage: Number(market.maxLeverage),
            longOI: fromUsdc(market.longSize),
            shortOI: fromUsdc(market.shortSize),
            poolValue: fromUsdc(poolValue),
            poolBalance: fromUsdc(poolBalance),
            totalOI: fromUsdc(oi),
            plpSupply: supply,
            feeRate: Number(feeBps) / 10_000,
            maxUtil: Number(maxUtil) / 10_000,
          });

          if (account) {
            const [pos, usdcBal, plpBal, ethBal] = await Promise.all([
              exchange.getPositionInfo(account, MARKET_ID),
              usdc.balanceOf(account),
              exchange.balanceOf(account),
              readProvider.getBalance(account),
            ]);
            Object.assign(next, {
              position: pos.size > 0n
                ? {
                    size: fromUsdc(pos.size),
                    sizeRaw: pos.size,
                    margin: fromUsdc(pos.margin),
                    entryPrice: fromPrice(pos.entryPrice),
                    isLong: pos.isLong,
                    pnl: fromUsdc(pos.pnl),
                    liquidationPrice: fromPrice(pos.liquidationPrice),
                  }
                : null,
              usdcBalance: fromUsdc(usdcBal),
              plpBalance: plpBal,
              ethBalance: Number(formatUnits(ethBal, 18)),
            });
          }
        }
        if (!cancelled) setData(next);
      } catch (err) {
        console.error(err);
        if (!cancelled) setData((d) => ({ ...(d ?? {}), loadError: describeError(err) }));
      }
    }

    load();
    const id = setInterval(load, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [account, tick]);

  return { data, refresh };
}

// ---------- transactions ----------
function useTx(getSigner, refresh) {
  const [pending, setPending] = useState(null);
  const [message, setMessage] = useState(null);

  const run = async (label, fn) => {
    setPending(label);
    setMessage(null);
    try {
      const signer = await getSigner();
      await fn(contracts(signer), signer);
      setMessage({ kind: "ok", text: `${label}: confirmed` });
      refresh();
    } catch (err) {
      console.error(err);
      setMessage({ kind: "err", text: describeError(err) });
    } finally {
      setPending(null);
    }
  };

  return { pending, message, run };
}

async function ensureAllowance(usdc, owner, amount) {
  const allowance = await usdc.allowance(owner, deployments.exchange);
  if (allowance < amount) await (await usdc.approve(deployments.exchange, MaxUint256)).wait();
}

// ---------- UI ----------
export default function App() {
  const wallet = useWallet();
  const { data, refresh } = useMarketData(wallet.account);
  const tx = useTx(wallet.getSigner, refresh);
  const [walletError, setWalletError] = useState(null);

  const ready = isDeployed && wallet.account && !wallet.wrongChain;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="logo">◆</span> Perps DEX <span className="badge">{chain?.name ?? "Unknown network"}</span>
        </div>
        <div className="wallet">
          {wallet.account && data?.usdcBalance !== undefined && (
            <span className="muted">{n(data.usdcBalance)} USDC</span>
          )}
          {!wallet.account ? (
            <button className="btn primary" onClick={() => wallet.connect().catch((e) => setWalletError(describeError(e)))}>
              Connect wallet
            </button>
          ) : wallet.wrongChain ? (
            <button className="btn warn" onClick={() => wallet.switchChain().catch((e) => setWalletError(describeError(e)))}>
              Switch to {chain.name}
            </button>
          ) : (
            <span className="addr">{shortAddr(wallet.account)}</span>
          )}
        </div>
      </header>

      {walletError && <div className="notice err">{walletError}</div>}
      {!isDeployed && (
        <div className="notice">
          Contracts aren't deployed yet. Run <code>npx hardhat run scripts/deploy.js --network arbitrumSepolia</code> in the{" "}
          <code>contracts</code> folder. Live prices still show below.
        </div>
      )}

      <MarketBar data={data} />

      <main className="grid">
        <div className="col">
          <PositionPanel data={data} ready={ready} tx={tx} account={wallet.account} />
          <PoolPanel data={data} ready={ready} tx={tx} account={wallet.account} />
        </div>
        <TradePanel data={data} ready={ready} tx={tx} account={wallet.account} />
      </main>

      {tx.message && <div className={`toast ${tx.message.kind}`}>{tx.message.text}</div>}

      <footer className="muted">
        Testnet only. Test USDC and test ETH have no value. Prices from Chainlink.
        {chain?.explorer && isDeployed && (
          <>
            {" "}
            · <a href={`${chain.explorer}/address/${deployments.exchange}`} target="_blank" rel="noreferrer">Exchange contract</a>
          </>
        )}
      </footer>
    </div>
  );
}

function MarketBar({ data }) {
  const oiLong = data?.longOI ?? 0;
  const oiShort = data?.shortOI ?? 0;
  const age = data?.priceAge ?? null;
  return (
    <section className="marketbar">
      <div>
        <div className="market-name">{MARKET}</div>
        <div className="price">{data?.price ? usd(data.price) : "—"}</div>
      </div>
      <Stat label="Oracle update" value={age === null ? "—" : age < 120 ? `${age}s ago` : `${Math.round(age / 60)}m ago`} />
      <Stat label="Open interest (long)" value={usd(oiLong, 0)} />
      <Stat label="Open interest (short)" value={usd(oiShort, 0)} />
      <Stat label="Max leverage" value={`${data?.maxLeverage ?? MAX_LEVERAGE}x`} />
      {data?.loadError && <span className="err-text">{data.loadError}</span>}
    </section>
  );
}

function Stat({ label, value, tone }) {
  return (
    <div className="stat">
      <span className="label">{label}</span>
      <span className={`value ${tone ?? ""}`}>{value}</span>
    </div>
  );
}

function TradePanel({ data, ready, tx, account }) {
  const [side, setSide] = useState("long");
  const [margin, setMargin] = useState("100");
  const [leverage, setLeverage] = useState(10);

  const maxLev = data?.maxLeverage ?? MAX_LEVERAGE;
  const price = data?.price ?? 0;
  const feeRate = data?.feeRate ?? 0.001;
  const m = Number(margin) || 0;
  const size = m * leverage;
  const fee = size * feeRate;
  const liq = side === "long" ? price * (1 + 0.01 - 1 / leverage) : price * (1 + 1 / leverage - 0.01);
  const existing = data?.position;
  const blocked = existing && existing.isLong !== (side === "long");

  const submit = () =>
    tx.run(`${side === "long" ? "Long" : "Short"} ${MARKET}`, async ({ exchange, usdc }, signer) => {
      const marginRaw = parseUnits(margin || "0", 6);
      const feeRaw = (marginRaw * BigInt(leverage) * 10n) / 10_000n;
      await ensureAllowance(usdc, await signer.getAddress(), marginRaw + feeRaw);
      await (await exchange.increasePosition(MARKET_ID, side === "long", marginRaw, leverage)).wait();
    });

  const faucet = () => tx.run("Get test USDC", async ({ usdc }) => (await usdc.faucet()).wait());

  return (
    <section className="panel trade">
      <div className="tabs">
        <button className={side === "long" ? "tab long active" : "tab"} onClick={() => setSide("long")}>Long</button>
        <button className={side === "short" ? "tab short active" : "tab"} onClick={() => setSide("short")}>Short</button>
      </div>

      <label className="field">
        <span>
          Margin (USDC)
          {data?.usdcBalance !== undefined && (
            <button className="link" onClick={() => setMargin(String(Math.floor(data.usdcBalance / (1 + leverage * feeRate))))}>
              Max {n(data.usdcBalance)}
            </button>
          )}
        </span>
        <input inputMode="decimal" value={margin} onChange={(e) => setMargin(e.target.value.replace(/[^0-9.]/g, ""))} />
      </label>

      <label className="field">
        <span>Leverage <b>{leverage}x</b></span>
        <input type="range" min="1" max={maxLev} value={leverage} onChange={(e) => setLeverage(Number(e.target.value))} />
        <div className="ticks">{[1, 10, 25, maxLev].map((v) => <button key={v} className="link" onClick={() => setLeverage(v)}>{v}x</button>)}</div>
      </label>

      <dl className="summary">
        <dt>Position size</dt><dd>{usd(size)}</dd>
        <dt>Entry price (est.)</dt><dd>{price ? usd(price) : "—"}</dd>
        <dt>Liquidation price (est.)</dt><dd>{price ? usd(liq) : "—"}</dd>
        <dt>Opening fee ({(feeRate * 100).toFixed(2)}%)</dt><dd>{usd(fee)}</dd>
        <dt>Total cost</dt><dd>{usd(m + fee)}</dd>
      </dl>

      {blocked && <p className="hint">Close your {existing.isLong ? "long" : "short"} first to open a {side}.</p>}

      <button
        className={`btn big ${side}`}
        disabled={!ready || !!tx.pending || m < 10 || blocked}
        onClick={submit}
      >
        {tx.pending ? `${tx.pending}…` : !account ? "Connect wallet to trade" : m < 10 ? "Minimum margin is 10 USDC" : `${side === "long" ? "Long" : "Short"} ${MARKET} ${leverage}x`}
      </button>

      {ready && (
        <div className="faucet">
          <span className="muted">Need test funds?</span>
          <button className="link" onClick={faucet} disabled={!!tx.pending}>Get 10,000 test USDC</button>
          {data?.ethBalance !== undefined && data.ethBalance < 0.0005 && (
            <a className="link" href="https://faucets.chain.link/arbitrum-sepolia" target="_blank" rel="noreferrer">Get test ETH for gas</a>
          )}
        </div>
      )}
    </section>
  );
}

function PositionPanel({ data, ready, tx, account }) {
  const [addAmount, setAddAmount] = useState("");
  const p = data?.position;

  if (!account) return <section className="panel"><h2>Your position</h2><p className="muted">Connect a wallet to see your position.</p></section>;
  if (!p) return <section className="panel"><h2>Your position</h2><p className="muted">No open {MARKET} position.</p></section>;

  const pnlPct = (p.pnl / p.margin) * 100;
  const tone = p.pnl >= 0 ? "up" : "down";

  const close = (fraction) =>
    tx.run(fraction === 1 ? "Close position" : "Close half", async ({ exchange }) => {
      const sizeDelta = fraction === 1 ? p.sizeRaw : p.sizeRaw / 2n;
      await (await exchange.decreasePosition(MARKET_ID, sizeDelta)).wait();
    });

  const addMargin = () =>
    tx.run("Add margin", async ({ exchange, usdc }, signer) => {
      const amount = parseUnits(addAmount || "0", 6);
      await ensureAllowance(usdc, await signer.getAddress(), amount);
      await (await exchange.addMargin(MARKET_ID, amount)).wait();
      setAddAmount("");
    });

  return (
    <section className="panel">
      <h2>
        Your position <span className={`pill ${p.isLong ? "long" : "short"}`}>{p.isLong ? "LONG" : "SHORT"} {n(p.size / p.margin, 1)}x</span>
      </h2>
      <div className="stats">
        <Stat label="Size" value={usd(p.size)} />
        <Stat label="Margin" value={usd(p.margin)} />
        <Stat label="Entry price" value={usd(p.entryPrice)} />
        <Stat label="Mark price" value={data?.price ? usd(data.price) : "—"} />
        <Stat label="Liquidation price" value={p.liquidationPrice ? usd(p.liquidationPrice) : "None"} />
        <Stat label="Unrealized PnL" value={`${p.pnl >= 0 ? "+" : "−"}${usd(Math.abs(p.pnl))} (${pnlPct >= 0 ? "+" : "−"}${n(Math.abs(pnlPct), 1)}%)`} tone={tone} />
      </div>
      <div className="actions">
        <button className="btn" disabled={!ready || !!tx.pending} onClick={() => close(0.5)}>Close 50%</button>
        <button className="btn primary" disabled={!ready || !!tx.pending} onClick={() => close(1)}>Close position</button>
        <div className="inline">
          <input placeholder="USDC" inputMode="decimal" value={addAmount} onChange={(e) => setAddAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
          <button className="btn" disabled={!ready || !!tx.pending || !Number(addAmount)} onClick={addMargin}>Add margin</button>
        </div>
      </div>
    </section>
  );
}

function PoolPanel({ data, ready, tx, account }) {
  const [amount, setAmount] = useState("");
  const [mode, setMode] = useState("deposit");

  const supply = data?.plpSupply ?? 0n;
  const myShares = data?.plpBalance ?? 0n;
  const myValue = useMemo(
    () => (supply > 0n && data?.poolValue ? (Number(myShares) / Number(supply)) * data.poolValue : 0),
    [supply, myShares, data?.poolValue]
  );
  const utilization = data?.poolValue ? (data.totalOI / data.poolValue) * 100 : 0;

  const submit = () =>
    tx.run(mode === "deposit" ? "Deposit liquidity" : "Withdraw liquidity", async ({ exchange, usdc }, signer) => {
      if (mode === "deposit") {
        const raw = parseUnits(amount || "0", 6);
        await ensureAllowance(usdc, await signer.getAddress(), raw);
        await (await exchange.addLiquidity(raw)).wait();
      } else {
        // Convert the requested USDC amount to shares; withdraw everything if it's ≥ the position's value.
        const want = Number(amount);
        const shares = want >= myValue * 0.9999 ? myShares : (myShares * BigInt(Math.floor((want / myValue) * 1e6))) / 1_000_000n;
        await (await exchange.removeLiquidity(shares)).wait();
      }
      setAmount("");
    });

  return (
    <section className="panel">
      <h2>Liquidity pool</h2>
      <p className="muted small">
        LPs are the counterparty to every trade. They earn trading fees and traders' losses, and pay traders' profits.
      </p>
      <div className="stats">
        <Stat label="Pool value" value={data?.poolValue !== undefined ? usd(data.poolValue, 0) : "—"} />
        <Stat label="Utilization" value={`${n(utilization, 1)}% / ${n((data?.maxUtil ?? 0.5) * 100, 0)}%`} />
        <Stat label="Your deposit value" value={account ? usd(myValue) : "—"} />
      </div>
      <div className="tabs small">
        <button className={mode === "deposit" ? "tab active" : "tab"} onClick={() => setMode("deposit")}>Deposit</button>
        <button className={mode === "withdraw" ? "tab active" : "tab"} onClick={() => setMode("withdraw")}>Withdraw</button>
      </div>
      <div className="inline">
        <input placeholder="USDC" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
        {mode === "withdraw" && myValue > 0 && <button className="link" onClick={() => setAmount(myValue.toFixed(2))}>Max</button>}
        <button className="btn primary" disabled={!ready || !!tx.pending || !Number(amount) || (mode === "withdraw" && myValue <= 0)} onClick={submit}>
          {mode === "deposit" ? "Deposit" : "Withdraw"}
        </button>
      </div>
    </section>
  );
}
