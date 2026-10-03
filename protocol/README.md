# Blood Magic protocol

The trading engine from [CAP v4](https://github.com/capofficial/protocol), rebuilt with Blood Magic's cooperative rules and governed by a Council of members instead of an admin key.

> **License:** files marked `BUSL-1.1` are derived from CAP v4, © cap.io, under the Business Source License 1.1. That license allows copying, modifying and **non-production** use, so these contracts are for testnets only. A real-money launch needs a commercial license from cap.io, or a rebuild from CAP v3 (`0xcap/protocol`), which converted to GPL-2.0-or-later on 2025-12-01. Files marked `MIT` are original to this project.

## How it works

| Contract | Role |
|---|---|
| `Store` | Holds every token and all state. Enforces hard limits that no vote can exceed. |
| `Trade` | Deposits, orders, keeper execution, liquidations, funding. |
| `Pool` | The Collective. LP deposits, the loss buffer, fee split, equal member dividends, solidarity refunds. |
| `CLP` | Pool share token. Can't be transferred. |
| `Chainlink` | Reads price feeds. Returns 0 (skip) on stale or invalid prices instead of reverting. |
| `Council` | Governs Store, Trade and Pool. One member, one vote. Can't call anything else. |

**Trading:**
- Deposit USDC into one cross-margin balance, then submit orders. Order types are market, limit and stop, with optional take-profit and stop-loss.
- Every order, market ones included, is filled by a **keeper** at the next oracle price, so nobody can trade on a price they already know. Market orders fill on the next price update, or after `minSettlementTime` at an unchanged price.
- When equity falls below 20% of locked margin, keepers liquidate the account.
- Funding: the crowded side pays the other, up to 50% a year at full skew.

**Cooperative rules on top of CAP:**

| Rule | Default |
|---|---|
| Leverage | Trader's choice, 1–50x per order (CAP always used the market maximum) |
| Progressive fees | 0.05% to $1K · 0.10% to $10K · 0.25% to $50K · 0.50% above, on the wallet's total position |
| Whale cap | $25,000 per wallet per market |
| Fee split | 10% to the keeper, then 30% split **equally** between members, 20% to the solidarity fund, the rest to the pool. No treasury. |
| Membership | $100 in the pool. CLP is non-transferable. |
| Solidarity fund | Liquidated traders with margin ≤ $500 get 25% of it back |
| Pool safety | Open interest ≤ 50% of the pool; profit per close ≤ 100% of size; LPs can't withdraw below what open positions need |
| Council | 1-hour votes, 20% quorum; only members from before a proposal can vote on it |

**CAP v4 bugs fixed here:**
- One order failing a check (max OI, insufficient funds) reverted the whole keeper batch, so no order could ever execute again. Such orders are now rejected individually, with their margin unlocked.
- The first trader loss was never debited.
- Liquidations debited the margin twice and could revert.
- Withdrawing liquidity didn't actually charge the withdrawal fee.
- Partial closes forgave the funding owed on the rest of the position.
- Adding to a position charged old funding to the new size.
- Open interest was reduced by the order size instead of the size actually closed.
- Chainlink prices weren't checked for staleness.
- Governance could re-link the contracts to new addresses.

## Develop

```
npm install
forge build
forge test
```

The test suite covers trading, fees, the whale cap, triggers, liquidation and solidarity refunds, funding, the pool and its buffer, member dividends, and the Council. It also runs invariant tests: the Store holds exactly what it owes, open interest matches positions, locked margin matches positions plus orders, and keepers are never blocked.

## Deploy

```
# Local paper trading on an Anvil fork with live prices
anvil --fork-url https://sepolia-rollup.arbitrum.io/rpc --chain-id 31337
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
npm run relay     # pushes the live Coinbase price into the mock feed
npm run keeper    # fills orders and liquidates

# Arbitrum Sepolia (about 0.0004 ETH of gas)
FEED=0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165 forge script script/Deploy.s.sol \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc --broadcast --slow --private-key $PRIVATE_KEY
KEEPER_KEY=0x... RPC_URL=https://sepolia-rollup.arbitrum.io/rpc npm run keeper
```

Addresses are written to `deployments/<chainId>.json`. The keeper needs a wallet with a little ETH for gas, and it earns 10% of the fees it collects. Trading only works while at least one keeper is running.
