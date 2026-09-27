# People's Perps

*Leverage for the many, not the few.*

A perpetual futures exchange run as a cooperative, on the **Arbitrum Sepolia testnet**. Trade **ETH-USD** long or short with **1–50x leverage**, using USDC as collateral and Chainlink prices. Unlike a normal perps DEX, the rules push value toward small traders and small depositors, and nobody owns it: members govern it by vote.

```
perps-dex/
├── contracts/   Solidity + Hardhat (exchange, Council, tests, deploy script)
└── web/         React + Vite app (ethers v6)
```

## The rules

| Rule | Default | What it does |
|---|---|---|
| **Progressive fees** | 0.05% up to $1K · 0.10% to $10K · 0.25% to $50K · 0.50% above | Marginal rates like tax brackets, on a wallet's *total* position. Splitting a trade into pieces costs the same as one trade. |
| **Whale cap** | $25,000 per wallet per market | Nobody gets to be that big. |
| **Fees are shared** | 50% pool · 30% members · 20% solidarity fund | The member share is split **equally per member**, not by deposit size. |
| **Solidarity fund** | 25% refund for margin ≤ $500 | Small traders who get liquidated get part of their margin back while the fund lasts. |
| **The Collective** | 100 USDC to join | Depositors are the counterparty to every trade. Membership shares (PLP) **can't be transferred, bought or sold**. |
| **The Council** | 1-hour votes, 20% quorum | Owns the exchange. Any member can propose a change; one member, one vote. Only wallets that were members *before* a proposal was made can vote on it. |

Other parameters: 50x max leverage, 1% maintenance margin, 5% liquidator reward, open interest ≤ 50% of pool, profit per position capped at 100% of size, 10 USDC minimum margin.

**Known limit on "one member, one vote":** blockchains can't tell people apart, so someone could split their money across several wallets ahead of time (100 USDC each) to get more votes. The "must be a member before the proposal" rule stops last-minute wallet creation, but not planned splitting. Real one-person-one-vote needs an identity layer such as Gitcoin Passport, World ID or BrightID.

### Accounting

Each position stores its `size` (USDC notional) and `units` (size ÷ entry price). PnL is linear in price, so the contract keeps per-market totals that give the exact unrealized PnL of all traders at once. Pool shares are priced against pool balance minus that PnL, so depositors can't withdraw ahead of losses already owed. The contract's USDC always equals pool balance + solidarity fund + unclaimed dividends + trader margin (checked in the tests).

## 1. Test the contracts

```
cd contracts
npm install
npx hardhat test
```

## 2. Deploy to Arbitrum Sepolia

1. Put a **testnet-only** private key in `contracts/.env` (see `.env.example`). Never use a wallet that holds real funds.
2. Fund it with ~0.01 Arbitrum Sepolia ETH: https://faucets.chain.link/arbitrum-sepolia
3. Deploy:
   ```
   cd contracts
   npx hardhat run scripts/deploy.js --network arbitrumSepolia
   ```
   This deploys test USDC and the exchange, adds ETH-USD, seeds the Collective with 100,000 test USDC (so the deployer is its first member), deploys the Council, and hands it ownership. Addresses are written to `web/src/deployments.json`.

## 3. Run the web app

```
cd web
npm install
npm run dev
```

Open http://localhost:5173, connect MetaMask, switch to Arbitrum Sepolia, and click **Get 10,000 test USDC**. To publish the site, run `npm run build` and upload `web/dist/` to a static host (Vercel, Netlify, Cloudflare Pages).

### Local-only mode

`npx hardhat node` in one terminal, then `npx hardhat run scripts/deploy.js --network localhost`. This uses a mock $2,700 price feed. Add chain 31337 at http://127.0.0.1:8545 to MetaMask and import a test key printed by `hardhat node`.

## Before real money

This is a working testnet MVP, **not** ready for mainnet funds. It would need:

- **A professional security audit.**
- **Oracle front-running protection.** Trades fill at the current Chainlink price; bots that see moves before the feed updates can profit at the Collective's expense. Use keeper-filled two-step orders or low-latency oracles (Pyth, Chainlink Data Streams).
- **Funding / borrow fees** to price long/short imbalances.
- **A liquidation keeper bot.**
- **Sybil-resistant identity** if one-member-one-vote is meant literally.
- **Real USDC** and a timelock on Council actions.
- **Legal review.** Leveraged derivatives are regulated in many countries, including the US.
