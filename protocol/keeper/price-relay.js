// Keeps the local MockAggregator in step with the live ETH-USD price so you can paper trade on Anvil.
// Usage: node keeper/price-relay.js   (after deploying to a local chain without FEED set)
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Contract, JsonRpcProvider, NonceManager, Wallet, parseUnits } from "ethers";

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
// Anvil's default account #1: public test key, local use only
const RELAYER_KEY = process.env.RELAYER_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const INTERVAL_MS = Number(process.env.INTERVAL_MS || 3000);
const HEARTBEAT_MS = 60_000; // push even when the price is unchanged, so the oracle never looks stale
const TICKER_URL = "https://api.exchange.coinbase.com/products/ETH-USD/ticker";
const FEED_ABI = ["function setPrice(int256)", "function decimals() view returns (uint8)", "function description() view returns (string)"];

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const { chainId } = await provider.getNetwork();
  if (chainId !== 31337n) throw new Error("Refusing to run: not a local chain");

  const dir = path.dirname(fileURLToPath(import.meta.url));
  const { ethUsdFeed } = JSON.parse(fs.readFileSync(path.join(dir, "..", "deployments", "31337.json"), "utf8"));
  const relayer = new NonceManager(new Wallet(RELAYER_KEY, provider));
  const feed = new Contract(ethUsdFeed, FEED_ABI, relayer);
  if ((await feed.description()) !== "MOCK / USD") throw new Error(`${ethUsdFeed} is not a MockAggregator`);
  const decimals = Number(await feed.decimals());
  log(`Relaying Coinbase ETH-USD to ${ethUsdFeed} every ${INTERVAL_MS / 1000}s`);

  let last = null;
  let lastPush = 0;
  for (;;) {
    try {
      const res = await fetch(TICKER_URL, { headers: { "User-Agent": "blood-magic-relay" } });
      if (!res.ok) throw new Error(`Coinbase ${res.status}`);
      const { price } = await res.json();
      const answer = parseUnits(Number(price).toFixed(decimals), decimals);
      if (answer !== last || Date.now() - lastPush > HEARTBEAT_MS) {
        await (await feed.setPrice(answer)).wait();
        log(`$${price}`);
        last = answer;
        lastPush = Date.now();
      }
    } catch (err) {
      log("relay error:", err.shortMessage || err.message);
      relayer.reset();
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}

main();
