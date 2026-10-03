// Fills orders and liquidates underwater accounts. Anyone can run one; keepers earn a share of fees,
// credited to their trading balance on the exchange.
//
// Usage: KEEPER_KEY=0x... RPC_URL=... node keeper/keeper.js
//   KEEPER_KEY  private key of a wallet with a little ETH for gas (never one holding real funds)
//   RPC_URL     defaults to a local Anvil chain
//   INTERVAL_MS defaults to 3000
import "dotenv/config";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Contract, JsonRpcProvider, NonceManager, Wallet } from "ethers";

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const INTERVAL_MS = Number(process.env.INTERVAL_MS || 3000);
// Anvil's default account #2: public test key, only used when no key is given on a local chain
const ANVIL_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";

const TRADE_ABI = [
  "function getExecutableOrderIds() view returns (uint256[])",
  "function executeOrders()",
  "function getLiquidatableUsers() view returns (address[])",
  "function liquidateUsers()",
];

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const { chainId } = await provider.getNetwork();
  const key = process.env.KEEPER_KEY || (chainId === 31337n ? ANVIL_KEY : null);
  if (!key) throw new Error("Set KEEPER_KEY to a funded wallet's private key");

  const dir = path.dirname(fileURLToPath(import.meta.url));
  const file = path.join(dir, "..", "deployments", `${chainId}.json`);
  const { trade: tradeAddress } = JSON.parse(fs.readFileSync(file, "utf8"));
  const signer = new NonceManager(new Wallet(key, provider));
  const trade = new Contract(tradeAddress, TRADE_ABI, signer);
  log(`Keeper ${await signer.getAddress()} watching Trade ${tradeAddress} on chain ${chainId}`);

  for (;;) {
    try {
      const orders = await trade.getExecutableOrderIds();
      if (orders.length) {
        const receipt = await (await trade.executeOrders()).wait();
        log(`executed orders [${orders.join(", ")}] in ${receipt.hash}`);
      }
      const users = await trade.getLiquidatableUsers();
      if (users.length) {
        const receipt = await (await trade.liquidateUsers()).wait();
        log(`liquidated [${users.join(", ")}] in ${receipt.hash}`);
      }
    } catch (err) {
      log("keeper error:", err.shortMessage || err.message);
      signer.reset();
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}

main();
