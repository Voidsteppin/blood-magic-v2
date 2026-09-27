import { Contract, Interface, JsonRpcProvider, encodeBytes32String } from "ethers";
import deployments from "./deployments.json";

export { deployments };

export const CHAINS = {
  421614: {
    name: "Arbitrum Sepolia",
    rpc: "https://sepolia-rollup.arbitrum.io/rpc",
    explorer: "https://sepolia.arbiscan.io",
    addParams: {
      chainId: "0x66eee",
      chainName: "Arbitrum Sepolia",
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: ["https://sepolia-rollup.arbitrum.io/rpc"],
      blockExplorerUrls: ["https://sepolia.arbiscan.io"],
    },
  },
  31337: {
    name: "Localhost",
    rpc: "http://127.0.0.1:8545",
    explorer: null,
    addParams: {
      chainId: "0x7a69",
      chainName: "Hardhat Localhost",
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: ["http://127.0.0.1:8545"],
    },
  },
};

export const chain = CHAINS[deployments.chainId];
export const isDeployed = Boolean(deployments.exchange && deployments.usdc);
export const MARKET = deployments.markets[0].id;
export const MARKET_ID = encodeBytes32String(MARKET);

export const EXCHANGE_ABI = [
  "function getPrice(bytes32) view returns (uint256)",
  "function getPositionInfo(address,bytes32) view returns (uint256 size, uint256 margin, uint256 entryPrice, bool isLong, int256 pnl, uint256 liquidationPrice, bool liquidatable)",
  "function markets(bytes32) view returns (address feed, uint8 feedDecimals, bool enabled, uint32 maxLeverage, uint256 longSize, uint256 longUnits, uint256 shortSize, uint256 shortUnits)",
  "function poolBalance() view returns (uint256)",
  "function poolValue() view returns (uint256)",
  "function totalOpenInterest() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function feeBps() view returns (uint256)",
  "function maintenanceMarginBps() view returns (uint256)",
  "function maxUtilizationBps() view returns (uint256)",
  "function minMargin() view returns (uint256)",
  "function increasePosition(bytes32 marketId, bool isLong, uint256 margin, uint256 leverage)",
  "function decreasePosition(bytes32 marketId, uint256 sizeDelta)",
  "function addMargin(bytes32 marketId, uint256 amount)",
  "function liquidate(address trader, bytes32 marketId)",
  "function addLiquidity(uint256 amount) returns (uint256)",
  "function removeLiquidity(uint256 shares) returns (uint256)",
  "error MarketDisabled()",
  "error UnknownMarket()",
  "error InvalidPrice()",
  "error StalePrice()",
  "error MarginTooSmall()",
  "error InvalidLeverage()",
  "error DirectionMismatch()",
  "error NoPosition()",
  "error InvalidSize()",
  "error UtilizationExceeded()",
  "error NotLiquidatable()",
  "error WouldBeLiquidatable()",
  "error InsufficientLiquidity()",
  "error ZeroAmount()",
];

export const USDC_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function faucet()",
];

export const readProvider = chain ? new JsonRpcProvider(chain.rpc, deployments.chainId, { staticNetwork: true }) : null;

export function contracts(runner) {
  return {
    exchange: new Contract(deployments.exchange, EXCHANGE_ABI, runner),
    usdc: new Contract(deployments.usdc, USDC_ABI, runner),
  };
}

const FRIENDLY_ERRORS = {
  MarketDisabled: "This market is paused.",
  StalePrice: "The oracle price is stale. Try again shortly.",
  InvalidPrice: "The oracle returned an invalid price.",
  MarginTooSmall: "Margin is below the 10 USDC minimum.",
  InvalidLeverage: "Leverage is above the market maximum.",
  DirectionMismatch: "Close your current position before opening one in the other direction.",
  NoPosition: "You have no open position.",
  InvalidSize: "Invalid size.",
  UtilizationExceeded: "The liquidity pool can't take on that much open interest right now.",
  NotLiquidatable: "That position isn't liquidatable.",
  WouldBeLiquidatable: "That change would put the position below maintenance margin.",
  InsufficientLiquidity: "The pool doesn't have enough free liquidity.",
  ZeroAmount: "Enter an amount.",
};

const exchangeInterface = new Interface(EXCHANGE_ABI);

// ethers doesn't always decode custom errors on transaction sends, so decode the raw revert data here.
function revertName(err) {
  if (err?.revert?.name) return err.revert.name;
  const data = err?.data ?? err?.info?.error?.data?.data ?? err?.info?.error?.data;
  if (typeof data !== "string" || !data.startsWith("0x")) return null;
  try {
    return exchangeInterface.parseError(data)?.name ?? null;
  } catch {
    return null;
  }
}

export function describeError(err) {
  const name = revertName(err);
  if (name && FRIENDLY_ERRORS[name]) return FRIENDLY_ERRORS[name];
  if (err?.code === "ACTION_REJECTED") return "Transaction rejected in wallet.";
  if (err?.code === "INSUFFICIENT_FUNDS") return "Not enough ETH for gas. Get test ETH from a faucet.";
  return err?.shortMessage || err?.message || "Something went wrong.";
}
