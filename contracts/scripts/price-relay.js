// Keeps the local MockAggregator in step with the live ETH-USD price so you can paper trade on Anvil.
// Usage: node scripts/price-relay.js   (after deploying to localhost)
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
// Anvil's default account #1: public test key, local use only. Account #0 is the deployer.
const RELAYER_KEY = process.env.RELAYER_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const INTERVAL_MS = Number(process.env.INTERVAL_MS || 3000);
const HEARTBEAT_MS = 60_000; // push even when the price is unchanged, so the oracle never looks stale
const TICKER_URL = "https://api.exchange.coinbase.com/products/ETH-USD/ticker";

const deployments = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "web", "src", "deployments.local.json"), "utf8"));
const FEED_ABI = ["function setPrice(int256)", "function decimals() view returns (uint8)", "function description() view returns (string)"];

async function livePrice() {
  const res = await fetch(TICKER_URL, { headers: { "User-Agent": "blood-magic-relay" } });
  if (!res.ok) throw new Error(`Coinbase ${res.status}`);
  const { price } = await res.json();
  return price;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const relayer = new ethers.NonceManager(new ethers.Wallet(RELAYER_KEY, provider));
  const feed = new ethers.Contract(deployments.markets[0].feed, FEED_ABI, relayer);

  if ((await provider.getNetwork()).chainId !== 31337n) throw new Error("Refusing to run: not a local chain");
  if ((await feed.description()) !== "MOCK / USD") throw new Error(`${await feed.getAddress()} is not a MockAggregator`);
  const decimals = await feed.decimals();
  console.log(`Relaying Coinbase ETH-USD to ${await feed.getAddress()} every ${INTERVAL_MS / 1000}s`);

  let last = null;
  let lastPush = 0;
  for (;;) {
    try {
      const price = await livePrice();
      const answer = ethers.parseUnits(Number(price).toFixed(Number(decimals)), decimals);
      if (answer !== last || Date.now() - lastPush > HEARTBEAT_MS) {
        await (await feed.setPrice(answer)).wait();
        console.log(`${new Date().toISOString()}  $${price}`);
        last = answer;
        lastPush = Date.now();
      }
    } catch (err) {
      console.error(`${new Date().toISOString()}  relay error: ${err.shortMessage || err.message}`);
      relayer.reset();
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}

main();
