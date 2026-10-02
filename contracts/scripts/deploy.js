const fs = require("fs");
const path = require("path");
const { ethers, network } = require("hardhat");

// Chainlink ETH/USD on Arbitrum Sepolia (verified on-chain: "ETH / USD", 8 decimals)
const CHAINLINK_ETH_USD = {
  arbitrumSepolia: "0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165",
};
const ETH_USD = ethers.encodeBytes32String("ETH-USD");
const SEED_LIQUIDITY = ethers.parseUnits("100000", 6);
const VOTING_PERIOD = 60 * 60; // 1 hour, short so testnet votes are quick to try
const QUORUM_BPS = 2_000; // 20% of members must vote

// Live ETH-USD from Coinbase (8 decimals), falling back to $2,700 offline
async function startingPrice() {
  try {
    const { price } = await (await fetch("https://api.exchange.coinbase.com/products/ETH-USD/ticker")).json();
    return ethers.parseUnits(Number(price).toFixed(8), 8);
  } catch {
    return 2700_00000000n;
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("No deployer account. Set PRIVATE_KEY in contracts/.env");
  console.log(`Deploying to ${network.name} from ${deployer.address}`);

  const usdc = await ethers.deployContract("MockUSDC");
  await usdc.waitForDeployment();
  console.log("MockUSDC:", await usdc.getAddress());

  let feedAddress = CHAINLINK_ETH_USD[network.name];
  if (!feedAddress) {
    // Local chain (including an Anvil fork): a settable feed, kept live by scripts/price-relay.js
    const feed = await ethers.deployContract("MockAggregator", [8, await startingPrice()]);
    await feed.waitForDeployment();
    feedAddress = await feed.getAddress();
    console.log("MockAggregator (run scripts/price-relay.js for live prices):", feedAddress);
  }

  const exchange = await ethers.deployContract("PerpExchange", [await usdc.getAddress()]);
  await exchange.waitForDeployment();
  const exchangeAddress = await exchange.getAddress();
  console.log("PerpExchange:", exchangeAddress);

  await (await exchange.setMarket(ETH_USD, feedAddress, 50, true)).wait();
  console.log("Added ETH-USD market (max 50x)");

  await (await usdc.mint(deployer.address, SEED_LIQUIDITY)).wait();
  await (await usdc.approve(exchangeAddress, SEED_LIQUIDITY)).wait();
  await (await exchange.addLiquidity(SEED_LIQUIDITY)).wait();
  console.log("Seeded the Collective with 100,000 test USDC");

  const council = await ethers.deployContract("Council", [exchangeAddress, VOTING_PERIOD, QUORUM_BPS]);
  await council.waitForDeployment();
  const councilAddress = await council.getAddress();
  await (await exchange.transferOwnership(councilAddress)).wait();
  console.log("Council:", councilAddress, "(now owns the exchange)");

  if (network.name === "hardhat") {
    console.log("In-memory dry run: not writing web/src/deployments.json");
    return;
  }

  const out = {
    chainId: Number(network.config.chainId ?? (await ethers.provider.getNetwork()).chainId),
    network: network.name,
    usdc: await usdc.getAddress(),
    exchange: exchangeAddress,
    council: councilAddress,
    markets: [{ id: "ETH-USD", feed: feedAddress }],
  };
  // Local deploys go to a gitignored file so they never overwrite the published testnet addresses
  const name = network.name === "localhost" ? "deployments.local.json" : "deployments.json";
  const file = path.join(__dirname, "..", "..", "web", "src", name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(out, null, 2) + "\n");
  console.log(`Wrote ${path.relative(process.cwd(), file)}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
