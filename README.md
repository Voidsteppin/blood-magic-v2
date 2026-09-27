# Perps DEX

A decentralized perpetual futures exchange in the style of Cap Finance v1. It runs on the **Arbitrum Sepolia testnet**.

- Trade **ETH-USD** long or short with **1–50x leverage**, using USDC as collateral
- Prices come from **Chainlink** (ETH/USD feed `0xd30e…5165`)
- A shared **liquidity pool** takes the other side of every trade. LPs deposit USDC, get PLP tokens, earn fees and traders' losses, and pay traders' profits.
- **Liquidations** are permissionless: anyone can liquidate an underwater position and earn 5% of its margin.

```
perps-dex/
├── contracts/   Solidity + Hardhat (contracts, tests, deploy script)
└── web/         React + Vite trading app (ethers v6)
```

## How it works

| Parameter | Value |
|---|---|
| Trading fee | 0.1% of size, on open and on close |
| Max leverage | 50x |
| Maintenance margin | 1% of size. Below this, a position can be liquidated. |
| Liquidator reward | 5% of the position's margin |
| Min margin | 10 USDC |
| Max pool utilization | Open interest ≤ 50% of pool value |
| Max profit per position | 100% of size |
| Oracle staleness limit | 24 hours |

The owner can change all of these with `setParams`, and can add markets (such as BTC-USD) with `setMarket(id, chainlinkFeed, maxLeverage, enabled)`.

Accounting: each position stores its `size` (USDC notional) and `units` (size ÷ entry price). PnL is linear in price, so the contract keeps per-market totals of size and units. That gives the *exact* unrealized PnL of all traders at once. LP shares are priced against pool balance minus that PnL, so LPs can't withdraw ahead of losses the pool already owes.

## 1. Test the contracts

```
cd contracts
npm install
npx hardhat test
```

## 2. Deploy to Arbitrum Sepolia

1. Create a **new wallet used only for testnet** in MetaMask. Never use a wallet that holds real funds.
2. Get free Arbitrum Sepolia ETH for gas: https://faucets.chain.link/arbitrum-sepolia
3. Copy `contracts/.env.example` to `contracts/.env` and paste that wallet's private key into `PRIVATE_KEY`.
4. Deploy:
   ```
   cd contracts
   npx hardhat run scripts/deploy.js --network arbitrumSepolia
   ```
   This deploys test USDC and the exchange, adds the ETH-USD market, seeds the pool with 100,000 test USDC, and writes the addresses to `web/src/deployments.json`.

## 3. Run the web app

```
cd web
npm install
npm run dev
```

Open http://localhost:5173, connect MetaMask, switch to Arbitrum Sepolia, and click **Get 10,000 test USDC** to start trading.

To deploy the site publicly, run `npm run build` and upload `web/dist/` to any static host (Vercel, Netlify, Cloudflare Pages).

### Local-only mode

`npx hardhat node` in one terminal, then `npx hardhat run scripts/deploy.js --network localhost` in another. This uses a mock price feed at $2,700. Add the Hardhat network (chain 31337, RPC http://127.0.0.1:8545) to MetaMask and import one of the test keys that `hardhat node` prints.

## Before real money: known limitations

This is a working MVP for testnet. It is **not** ready for mainnet funds. Before mainnet it needs:

- **A professional security audit** of the contracts.
- **Oracle front-running protection.** Trades execute at the current Chainlink price, so bots that see price moves before the feed updates can profit at LPs' expense. Production perps DEXs use two-step orders filled by a keeper at a later price, or Pyth/Chainlink Data Streams low-latency prices.
- **Funding / borrow fees.** There's no fee for holding positions yet, so long-term imbalances between longs and shorts aren't priced in.
- **A liquidation keeper bot** to watch positions and liquidate them promptly.
- **Real USDC** instead of the mock token, and a multisig or timelock as contract owner.
- **Legal review.** Leveraged derivatives are regulated in many countries, including the US.
