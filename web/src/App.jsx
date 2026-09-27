import { useCallback, useEffect, useState } from "react";
import { BrowserProvider, Contract, MaxUint256, formatUnits, parseUnits } from "ethers";
import {
  MARKET,
  MARKET_ID,
  chain,
  contracts,
  deployments,
  describeError,
  isDeployed,
  progressiveTax,
  readProvider,
  toParams,
} from "./chain.js";

const FEED_ABI = ["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)", "function decimals() view returns (uint8)"];
const POLL_MS = 5000;
const MAX_LEVERAGE = 50;
const PROPOSALS_SHOWN = 8;
// Contract defaults, used for previews before the contracts are reachable.
const DEFAULT_FEES = {
  feeRatesBps: [5, 10, 25, 50],
  feeBrackets: [1_000_000000n, 10_000_000000n, 50_000_000000n],
  maxPositionSize: 25_000_000000n,
};

// ---------- formatting ----------
const n = (v, d = 2) => Number(v).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const usd = (v, d = 2) => `$${n(v, d)}`;
const fromUsdc = (v) => Number(formatUnits(v, 6));
const fromPrice = (v) => Number(formatUnits(v, 18));
const pct = (bps) => `${n(Number(bps) / 100, Number(bps) % 100 ? 2 : 0)}%`;
const shortAddr = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const cleanNum = (s) => s.replace(/[^0-9.]/g, "");
function duration(secs) {
  if (secs <= 0) return "ended";
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  return h ? `${h}h ${m}m left` : `${m || 1}m left`;
}

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
async function loadProposals(council, account) {
  const count = Number(await council.proposalCount());
  const ids = Array.from({ length: Math.min(count, PROPOSALS_SHOWN) }, (_, i) => count - 1 - i);
  return Promise.all(
    ids.map(async (id) => {
      const [p, passed, quorum, voted] = await Promise.all([
        council.getProposal(id),
        council.passed(id),
        council.quorumFor(id),
        account ? council.hasVoted(id, account) : false,
      ]);
      return {
        id,
        proposer: p.proposer,
        createdAt: Number(p.createdAt),
        endsAt: Number(p.endsAt),
        yes: Number(p.yes),
        no: Number(p.no),
        electorate: Number(p.electorate),
        executed: p.executed,
        description: p.description,
        passed,
        quorum: Number(quorum),
        voted,
      };
    })
  );
}

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
        const now = Math.floor(Date.now() / 1000);
        const [round, decimals] = await Promise.all([feed.latestRoundData(), feed.decimals()]);
        const next = {
          now,
          price: Number(formatUnits(round[1], decimals)),
          priceAge: Math.max(0, now - Number(round[3])),
        };

        if (isDeployed) {
          const { exchange, usdc, council } = contracts(readProvider);
          const [market, params, poolValue, oi, fund, members, proposals] = await Promise.all([
            exchange.markets(MARKET_ID),
            exchange.getParams(),
            exchange.poolValue(),
            exchange.totalOpenInterest(),
            exchange.solidarityFund(),
            exchange.memberCount(),
            loadProposals(council, account),
          ]);
          Object.assign(next, {
            maxLeverage: Number(market.maxLeverage),
            longOI: fromUsdc(market.longSize),
            shortOI: fromUsdc(market.shortSize),
            params: toParams(params),
            poolValue: fromUsdc(poolValue),
            totalOI: fromUsdc(oi),
            solidarityFund: fromUsdc(fund),
            memberCount: Number(members),
            proposals,
          });

          if (account) {
            const [pos, usdcBal, shares, since, dividend, ethBal] = await Promise.all([
              exchange.getPositionInfo(account, MARKET_ID),
              usdc.balanceOf(account),
              exchange.balanceOf(account),
              exchange.memberSince(account),
              exchange.pendingDividend(account),
              readProvider.getBalance(account),
            ]);
            Object.assign(next, {
              position:
                pos.size > 0n
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
              shares,
              shareValue: shares > 0n ? fromUsdc(await exchange.sharesToUsdc(shares)) : 0,
              memberSince: Number(since),
              pendingDividend: fromUsdc(dividend),
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
  const props = { data, ready, tx, account: wallet.account };

  return (
    <div className="app">
      <div className="backdrop" aria-hidden="true">
        <div className="sun" />
        <div className="floor" />
      </div>
      <header className="topbar">
        <div className="brand">
          <span className="logo" aria-hidden="true">★</span>
          <div>
            <div className="name">People's Perps</div>
            <div className="slogan">Leverage for the many, not the few</div>
          </div>
          <span className="badge">{chain?.name ?? "Unknown network"}</span>
        </div>
        <div className="wallet">
          {wallet.account && data?.usdcBalance !== undefined && <span className="muted">{n(data.usdcBalance)} USDC</span>}
          {!wallet.account ? (
            <button className="btn primary" onClick={() => wallet.connect().catch((e) => setWalletError(describeError(e)))}>
              Connect wallet
            </button>
          ) : wallet.wrongChain ? (
            <button className="btn warn" onClick={() => wallet.switchChain().catch((e) => setWalletError(describeError(e)))}>
              Switch to {chain.name}
            </button>
          ) : (
            <span className="addr">
              {data?.memberSince ? <span className="comrade">Comrade</span> : null} {shortAddr(wallet.account)}
            </span>
          )}
        </div>
      </header>

      {walletError && <div className="notice err">{walletError}</div>}
      {!isDeployed && (
        <div className="notice">
          ★ Launching soon on Arbitrum Sepolia. Trading opens when the contracts go live. Live ETH prices below are real.
        </div>
      )}

      <MarketBar data={data} />

      <main className="grid">
        <div className="col">
          <PositionPanel {...props} />
          <CollectivePanel {...props} />
          <CouncilPanel {...props} />
        </div>
        <div className="col">
          <TradePanel {...props} />
          <PrinciplesPanel data={data} />
        </div>
      </main>

      {tx.message && <div className={`toast ${tx.message.kind}`}>{tx.message.text}</div>}

      <footer className="muted">
        Testnet only. Test USDC and test ETH have no value. Prices from Chainlink. No owner: the Council governs.
        {chain?.explorer && isDeployed && (
          <>
            {" "}
            ·{" "}
            <a href={`${chain.explorer}/address/${deployments.exchange}`} target="_blank" rel="noreferrer">
              Exchange
            </a>{" "}
            ·{" "}
            <a href={`${chain.explorer}/address/${deployments.council}`} target="_blank" rel="noreferrer">
              Council
            </a>
          </>
        )}
      </footer>
    </div>
  );
}

function MarketBar({ data }) {
  const age = data?.priceAge ?? null;
  return (
    <section className="marketbar">
      <div>
        <div className="market-name">{MARKET}</div>
        <div className="price">{data?.price ? usd(data.price) : "—"}</div>
      </div>
      <Stat label="Oracle update" value={age === null ? "—" : age < 120 ? `${age}s ago` : `${Math.round(age / 60)}m ago`} />
      <Stat label="Longs / shorts" value={`${usd(data?.longOI ?? 0, 0)} / ${usd(data?.shortOI ?? 0, 0)}`} />
      <Stat label="Members" value={data?.memberCount ?? "—"} />
      <Stat label="Solidarity fund" value={data?.solidarityFund !== undefined ? usd(data.solidarityFund) : "—"} />
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
  const params = data?.params ?? DEFAULT_FEES;
  const existing = data?.position;
  const m = Number(margin) || 0;
  const size = m * leverage;

  let fee = 0;
  let effectiveRate = 0;
  if (params && size > 0) {
    const current = existing ? parseUnits(existing.size.toFixed(6), 6) : 0n;
    const add = parseUnits(size.toFixed(6), 6);
    fee = fromUsdc(progressiveTax(current + add, params) - progressiveTax(current, params));
    effectiveRate = (fee / size) * 100;
  }
  const whaleCap = params ? fromUsdc(params.maxPositionSize) : 25_000;
  const room = Math.max(0, whaleCap - (existing?.size ?? 0));
  const overCap = size > room;
  const liq = side === "long" ? price * (1 + 0.01 - 1 / leverage) : price * (1 + 1 / leverage - 0.01);
  const blocked = existing && existing.isLong !== (side === "long");

  const submit = () =>
    tx.run(`${side === "long" ? "Long" : "Short"} ${MARKET}`, async ({ exchange, usdc }, signer) => {
      const trader = await signer.getAddress();
      const marginRaw = parseUnits(margin || "0", 6);
      const feeRaw = await exchange.openingFee(trader, MARKET_ID, marginRaw * BigInt(leverage));
      await ensureAllowance(usdc, trader, marginRaw + feeRaw);
      await (await exchange.increasePosition(MARKET_ID, side === "long", marginRaw, leverage)).wait();
    });

  const faucet = () => tx.run("Get test USDC", async ({ usdc }) => (await usdc.faucet()).wait());

  let label = `${side === "long" ? "Long" : "Short"} ${MARKET} ${leverage}x`;
  if (tx.pending) label = `${tx.pending}…`;
  else if (!account) label = "Connect wallet to trade";
  else if (m < 10) label = "Minimum margin is 10 USDC";
  else if (overCap) label = `Whale cap: max ${usd(room, 0)} more`;

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
            <button className="link" onClick={() => setMargin(String(Math.floor(Math.min(data.usdcBalance * 0.99, room / leverage))))}>
              Max
            </button>
          )}
        </span>
        <input inputMode="decimal" value={margin} onChange={(e) => setMargin(cleanNum(e.target.value))} />
      </label>

      <label className="field">
        <span>Leverage <b>{leverage}x</b></span>
        <input type="range" min="1" max={maxLev} value={leverage} onChange={(e) => setLeverage(Number(e.target.value))} />
        <div className="ticks">
          {[1, 10, 25, maxLev].map((v) => (
            <button key={v} className="link" onClick={() => setLeverage(v)}>{v}x</button>
          ))}
        </div>
      </label>

      <dl className="summary">
        <dt>Position size</dt><dd className={overCap ? "down" : ""}>{usd(size)}</dd>
        <dt>Entry price (est.)</dt><dd>{price ? usd(price) : "—"}</dd>
        <dt>Liquidation price (est.)</dt><dd>{price ? usd(liq) : "—"}</dd>
        <dt>Progressive fee ({n(effectiveRate, 3)}%)</dt><dd>{usd(fee)}</dd>
        <dt>Whale cap room</dt><dd>{usd(room, 0)}</dd>
        <dt>Total cost</dt><dd>{usd(m + fee)}</dd>
      </dl>

      {blocked && <p className="hint">Close your {existing.isLong ? "long" : "short"} first to open a {side}.</p>}

      <button className={`btn big ${side}`} disabled={!ready || !!tx.pending || m < 10 || blocked || overCap} onClick={submit}>
        {label}
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

  if (!account || !p) {
    return (
      <section className="panel">
        <h2>Your position</h2>
        <p className="muted">{account ? `No open ${MARKET} position.` : "Connect a wallet to see your position."}</p>
      </section>
    );
  }

  const pnlPct = (p.pnl / p.margin) * 100;
  const tone = p.pnl >= 0 ? "up" : "down";
  const smallTrader = data?.params && p.margin <= fromUsdc(data.params.solidarityMarginCap);

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
        Your position{" "}
        <span className={`pill ${p.isLong ? "long" : "short"}`}>
          {p.isLong ? "LONG" : "SHORT"} {n(p.size / p.margin, 1)}x
        </span>
      </h2>
      <div className="stats">
        <Stat label="Size" value={usd(p.size)} />
        <Stat label="Margin" value={usd(p.margin)} />
        <Stat label="Entry price" value={usd(p.entryPrice)} />
        <Stat label="Mark price" value={data?.price ? usd(data.price) : "—"} />
        <Stat label="Liquidation price" value={p.liquidationPrice ? usd(p.liquidationPrice) : "None"} />
        <Stat
          label="Unrealized PnL"
          value={`${p.pnl >= 0 ? "+" : "−"}${usd(Math.abs(p.pnl))} (${pnlPct >= 0 ? "+" : "−"}${n(Math.abs(pnlPct), 1)}%)`}
          tone={tone}
        />
      </div>
      {smallTrader && (
        <p className="hint ok">
          Protected by the solidarity fund: if liquidated, you get {pct(data.params.solidarityRefundBps)} of your margin back (while the fund lasts).
        </p>
      )}
      <div className="actions">
        <button className="btn" disabled={!ready || !!tx.pending} onClick={() => close(0.5)}>Close 50%</button>
        <button className="btn primary" disabled={!ready || !!tx.pending} onClick={() => close(1)}>Close position</button>
        <div className="inline">
          <input placeholder="USDC" inputMode="decimal" value={addAmount} onChange={(e) => setAddAmount(cleanNum(e.target.value))} />
          <button className="btn" disabled={!ready || !!tx.pending || !Number(addAmount)} onClick={addMargin}>Add margin</button>
        </div>
      </div>
    </section>
  );
}

function CollectivePanel({ data, ready, tx, account }) {
  const [amount, setAmount] = useState("");
  const [mode, setMode] = useState("deposit");

  const myValue = data?.shareValue ?? 0;
  const isMember = Boolean(data?.memberSince);
  const minDeposit = data?.params ? fromUsdc(data.params.minMemberDeposit) : 100;
  const utilization = data?.poolValue ? (data.totalOI / data.poolValue) * 100 : 0;

  const submit = () =>
    tx.run(mode === "deposit" ? "Join / deposit" : "Withdraw", async ({ exchange, usdc }, signer) => {
      if (mode === "deposit") {
        const raw = parseUnits(amount || "0", 6);
        await ensureAllowance(usdc, await signer.getAddress(), raw);
        await (await exchange.addLiquidity(raw)).wait();
      } else {
        // Convert the requested USDC amount to shares; withdraw everything if it's ≥ the position's value.
        const want = Number(amount);
        const shares = want >= myValue * 0.9999 ? data.shares : (data.shares * BigInt(Math.floor((want / myValue) * 1e6))) / 1_000_000n;
        await (await exchange.removeLiquidity(shares)).wait();
      }
      setAmount("");
    });

  const claim = () => tx.run("Claim dividend", async ({ exchange }) => (await exchange.claimDividend()).wait());

  return (
    <section className="panel">
      <h2>
        The Collective {isMember && <span className="pill member">MEMBER</span>}
      </h2>
      <p className="muted small">
        The Collective is the counterparty to every trade. Deposit {usd(minDeposit, 0)}+ to become a member: you share in fees,
        and {data?.params ? pct(data.params.dividendShareBps) : "30%"} of all fees are split <b>equally</b> between members, whatever
        they put in. Membership can't be bought or sold.
      </p>
      <div className="stats">
        <Stat label="Pool value" value={data?.poolValue !== undefined ? usd(data.poolValue, 0) : "—"} />
        <Stat label="Utilization" value={`${n(utilization, 1)}% / ${data?.params ? pct(data.params.maxUtilizationBps) : "50%"}`} />
        <Stat label="Your deposit value" value={account ? usd(myValue) : "—"} />
        <Stat label="Your equal-share dividend" value={account ? usd(data?.pendingDividend ?? 0, 4) : "—"} tone={data?.pendingDividend > 0 ? "up" : ""} />
      </div>
      {isMember && (
        <div className="actions" style={{ marginBottom: 12 }}>
          <button className="btn" disabled={!ready || !!tx.pending || !(data?.pendingDividend > 0)} onClick={claim}>
            Claim dividend
          </button>
        </div>
      )}
      <div className="tabs small">
        <button className={mode === "deposit" ? "tab active" : "tab"} onClick={() => setMode("deposit")}>{isMember ? "Deposit" : "Join"}</button>
        <button className={mode === "withdraw" ? "tab active" : "tab"} onClick={() => setMode("withdraw")}>Withdraw</button>
      </div>
      <div className="inline">
        <input placeholder="USDC" inputMode="decimal" value={amount} onChange={(e) => setAmount(cleanNum(e.target.value))} />
        {mode === "withdraw" && myValue > 0 && <button className="link" onClick={() => setAmount(myValue.toFixed(2))}>Max</button>}
        <button
          className="btn primary"
          disabled={!ready || !!tx.pending || !Number(amount) || (mode === "withdraw" && myValue <= 0)}
          onClick={submit}
        >
          {mode === "deposit" ? (isMember ? "Deposit" : "Join the Collective") : "Withdraw"}
        </button>
      </div>
      {mode === "withdraw" && isMember && <p className="hint">Dropping below {usd(minDeposit, 0)} ends your membership (your dividend is paid out first).</p>}
    </section>
  );
}

// Parameters members can propose changing, with how to display and encode them.
const GOVERNABLE = [
  { key: "maxPositionSize", label: "Whale cap (max position, USDC)", kind: "usdc" },
  { key: "fee0", label: "Fee rate, bracket 1 (%)", kind: "feeRate", index: 0 },
  { key: "fee1", label: "Fee rate, bracket 2 (%)", kind: "feeRate", index: 1 },
  { key: "fee2", label: "Fee rate, bracket 3 (%)", kind: "feeRate", index: 2 },
  { key: "fee3", label: "Fee rate, top bracket (%)", kind: "feeRate", index: 3 },
  { key: "dividendShareBps", label: "Equal member dividend share of fees (%)", kind: "bps" },
  { key: "solidarityShareBps", label: "Solidarity fund share of fees (%)", kind: "bps" },
  { key: "solidarityRefundBps", label: "Solidarity refund on liquidation (%)", kind: "bps" },
  { key: "solidarityMarginCap", label: "Solidarity refund eligibility (max margin, USDC)", kind: "usdc" },
  { key: "minMemberDeposit", label: "Minimum deposit for membership (USDC)", kind: "usdc" },
];

function currentValue(params, g) {
  if (g.kind === "usdc") return fromUsdc(params[g.key]);
  if (g.kind === "feeRate") return params.feeRatesBps[g.index] / 100;
  return params[g.key] / 100;
}

function withChange(params, g, value) {
  const next = { ...params, feeRatesBps: [...params.feeRatesBps], feeBrackets: [...params.feeBrackets] };
  if (g.kind === "usdc") next[g.key] = parseUnits(String(value), 6);
  else if (g.kind === "feeRate") next.feeRatesBps[g.index] = Math.round(Number(value) * 100);
  else next[g.key] = Math.round(Number(value) * 100);
  return next;
}

function CouncilPanel({ data, ready, tx }) {
  const [choice, setChoice] = useState(GOVERNABLE[0].key);
  const [value, setValue] = useState("");
  const [reason, setReason] = useState("");

  const params = data?.params;
  const g = GOVERNABLE.find((x) => x.key === choice);
  const isMember = Boolean(data?.memberSince);
  const now = data?.now ?? 0;

  const propose = () =>
    tx.run("Submit proposal", async ({ exchange, council }) => {
      const calldata = exchange.interface.encodeFunctionData("setParams", [withChange(params, g, value)]);
      const from = currentValue(params, g);
      const summary = `${g.label}: ${n(from, g.kind === "usdc" ? 0 : 2)} → ${n(Number(value), g.kind === "usdc" ? 0 : 2)}`;
      await (await council.propose(calldata, reason.trim() ? `${summary}. ${reason.trim()}` : summary)).wait();
      setValue("");
      setReason("");
    });

  const vote = (id, support) => tx.run(support ? "Vote yes" : "Vote no", async ({ council }) => (await council.vote(id, support)).wait());
  const execute = (id) => tx.run("Enact proposal", async ({ council }) => (await council.execute(id)).wait());

  return (
    <section className="panel">
      <h2>The Council</h2>
      <p className="muted small">
        Nobody owns this exchange. Any member can propose a change; members vote, one member one vote, no matter how much they
        deposited. Only wallets that were members before a proposal was made can vote on it.
      </p>

      {data?.proposals?.length ? (
        <ul className="proposals">
          {data.proposals.map((p) => {
            const open = now < p.endsAt;
            const eligible = isMember && data.memberSince < p.createdAt;
            let status = open ? duration(p.endsAt - now) : p.executed ? "Enacted" : p.passed ? "Passed, awaiting enactment" : "Rejected";
            return (
              <li key={p.id} className="proposal">
                <div className="proposal-head">
                  <span className="muted">#{p.id}</span>
                  <span className={`status ${p.executed ? "enacted" : open ? "open" : p.passed ? "passed" : "rejected"}`}>{status}</span>
                </div>
                <div className="proposal-text">{p.description}</div>
                <div className="votes">
                  <span className="up">Yes {p.yes}</span>
                  <span className="down">No {p.no}</span>
                  <span className="muted">Quorum {p.quorum} of {p.electorate} members</span>
                </div>
                <div className="actions">
                  {open && eligible && !p.voted && (
                    <>
                      <button className="btn long-outline" disabled={!ready || !!tx.pending} onClick={() => vote(p.id, true)}>Vote yes</button>
                      <button className="btn short-outline" disabled={!ready || !!tx.pending} onClick={() => vote(p.id, false)}>Vote no</button>
                    </>
                  )}
                  {open && p.voted && <span className="muted small-inline">You voted</span>}
                  {open && isMember && !eligible && <span className="muted small-inline">You joined after this was proposed</span>}
                  {!open && p.passed && !p.executed && (
                    <button className="btn primary" disabled={!ready || !!tx.pending} onClick={() => execute(p.id)}>Enact</button>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="muted">No proposals yet.</p>
      )}

      {isMember && params && (
        <div className="propose">
          <h3>Propose a change</h3>
          <select value={choice} onChange={(e) => setChoice(e.target.value)}>
            {GOVERNABLE.map((x) => (
              <option key={x.key} value={x.key}>{x.label}</option>
            ))}
          </select>
          <div className="inline">
            <span className="muted nowrap">Now {n(currentValue(params, g), g.kind === "usdc" ? 0 : 2)} →</span>
            <input placeholder="New value" inputMode="decimal" value={value} onChange={(e) => setValue(cleanNum(e.target.value))} />
          </div>
          <input placeholder="Why? (optional)" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
          <button className="btn primary" disabled={!ready || !!tx.pending || value === "" || isNaN(Number(value))} onClick={propose}>
            Submit proposal
          </button>
        </div>
      )}
    </section>
  );
}

function PrinciplesPanel({ data }) {
  const p = data?.params;
  const brackets = p
    ? [
        `Up to ${usd(fromUsdc(p.feeBrackets[0]), 0)}: ${pct(p.feeRatesBps[0])}`,
        `${usd(fromUsdc(p.feeBrackets[0]), 0)}–${usd(fromUsdc(p.feeBrackets[1]), 0)}: ${pct(p.feeRatesBps[1])}`,
        `${usd(fromUsdc(p.feeBrackets[1]), 0)}–${usd(fromUsdc(p.feeBrackets[2]), 0)}: ${pct(p.feeRatesBps[2])}`,
        `Above ${usd(fromUsdc(p.feeBrackets[2]), 0)}: ${pct(p.feeRatesBps[3])}`,
      ]
    : ["Up to $1,000: 0.05%", "$1,000–$10,000: 0.1%", "$10,000–$50,000: 0.25%", "Above $50,000: 0.5%"];

  return (
    <section className="panel principles">
      <h2>How the Commune works</h2>
      <ol>
        <li>
          <b>Progressive fees.</b> Like tax brackets, on your total position:
          <ul>{brackets.map((b) => <li key={b}>{b}</li>)}</ul>
        </li>
        <li><b>Whale cap.</b> No wallet can hold more than {p ? usd(fromUsdc(p.maxPositionSize), 0) : "$25,000"} per market.</li>
        <li>
          <b>Fees are shared.</b> {p ? pct(p.dividendShareBps) : "30%"} split equally among members, {p ? pct(p.solidarityShareBps) : "20%"} to
          the solidarity fund, the rest to the pool.
        </li>
        <li>
          <b>Solidarity fund.</b> Small traders (margin ≤ {p ? usd(fromUsdc(p.solidarityMarginCap), 0) : "$500"}) who get liquidated
          get {p ? pct(p.solidarityRefundBps) : "25%"} of their margin back.
        </li>
        <li><b>No owner.</b> Every rule above can only be changed by a vote of members.</li>
      </ol>
    </section>
  );
}
