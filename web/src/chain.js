import { Contract, Interface, JsonRpcProvider, encodeBytes32String } from "ethers";
import published from "./deployments.json";

// `npm run dev:anvil` uses the addresses from a local Anvil deploy (deployments.local.json, gitignored)
const local = Object.values(import.meta.glob("./deployments.local.json", { eager: true, import: "default" }))[0];
export const deployments = import.meta.env.MODE === "anvil" && local ? local : published;

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
export const isDeployed = Boolean(deployments.exchange && deployments.usdc && deployments.council);
export const MARKET = deployments.markets[0].id;
export const MARKET_ID = encodeBytes32String(MARKET);

const PARAMS_TUPLE =
  "tuple(uint16[4] feeRatesBps, uint256[3] feeBrackets, uint16 maintenanceMarginBps, uint16 liquidatorRewardBps, uint16 maxUtilizationBps, uint16 maxProfitBps, uint256 minMargin, uint256 maxPriceAge, uint256 maxPositionSize, uint16 dividendShareBps, uint16 solidarityShareBps, uint16 solidarityRefundBps, uint256 solidarityMarginCap, uint256 minMemberDeposit)";

export const EXCHANGE_ABI = [
  "function getPrice(bytes32) view returns (uint256)",
  "function getPositionInfo(address,bytes32) view returns (uint256 size, uint256 margin, uint256 entryPrice, bool isLong, int256 pnl, uint256 liquidationPrice, bool liquidatable)",
  "function markets(bytes32) view returns (address feed, uint8 feedDecimals, bool enabled, uint32 maxLeverage, uint256 longSize, uint256 longUnits, uint256 shortSize, uint256 shortUnits)",
  `function getParams() view returns (${PARAMS_TUPLE})`,
  `function setParams(${PARAMS_TUPLE} p)`,
  "function openingFee(address,bytes32,uint256) view returns (uint256)",
  "function poolBalance() view returns (uint256)",
  "function poolValue() view returns (uint256)",
  "function solidarityFund() view returns (uint256)",
  "function totalOpenInterest() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function sharesToUsdc(uint256) view returns (uint256)",
  "function memberCount() view returns (uint256)",
  "function memberSince(address) view returns (uint256)",
  "function pendingDividend(address) view returns (uint256)",
  "function increasePosition(bytes32 marketId, bool isLong, uint256 margin, uint256 leverage)",
  "function decreasePosition(bytes32 marketId, uint256 sizeDelta)",
  "function addMargin(bytes32 marketId, uint256 amount)",
  "function liquidate(address trader, bytes32 marketId)",
  "function addLiquidity(uint256 amount) returns (uint256)",
  "function removeLiquidity(uint256 shares) returns (uint256)",
  "function claimDividend() returns (uint256)",
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
  "error WhaleCapExceeded()",
  "error NotLiquidatable()",
  "error WouldBeLiquidatable()",
  "error InsufficientLiquidity()",
  "error ZeroAmount()",
  "error NotMember()",
  "error NonTransferable()",
  "error InvalidParams()",
];

export const COUNCIL_ABI = [
  "function propose(bytes data, string description) returns (uint256)",
  "function vote(uint256 id, bool support)",
  "function execute(uint256 id)",
  "function passed(uint256 id) view returns (bool)",
  "function quorumFor(uint256 id) view returns (uint256)",
  "function proposalCount() view returns (uint256)",
  "function hasVoted(uint256, address) view returns (bool)",
  "function votingPeriod() view returns (uint256)",
  "function getProposal(uint256 id) view returns (tuple(address proposer, uint64 createdAt, uint64 endsAt, uint32 yes, uint32 no, uint32 electorate, bool executed, bytes data, string description))",
  "error NotMember()",
  "error NotEligible()",
  "error AlreadyVoted()",
  "error VotingClosed()",
  "error VotingOpen()",
  "error AlreadyExecuted()",
  "error Rejected()",
  "error UnknownProposal()",
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
    council: new Contract(deployments.council, COUNCIL_ABI, runner),
    usdc: new Contract(deployments.usdc, USDC_ABI, runner),
  };
}

/** Converts a getParams() result into a plain object that can be edited and passed back to setParams. */
export function toParams(r) {
  return {
    feeRatesBps: [...r.feeRatesBps].map(Number),
    feeBrackets: [...r.feeBrackets],
    maintenanceMarginBps: Number(r.maintenanceMarginBps),
    liquidatorRewardBps: Number(r.liquidatorRewardBps),
    maxUtilizationBps: Number(r.maxUtilizationBps),
    maxProfitBps: Number(r.maxProfitBps),
    minMargin: r.minMargin,
    maxPriceAge: r.maxPriceAge,
    maxPositionSize: r.maxPositionSize,
    dividendShareBps: Number(r.dividendShareBps),
    solidarityShareBps: Number(r.solidarityShareBps),
    solidarityRefundBps: Number(r.solidarityRefundBps),
    solidarityMarginCap: r.solidarityMarginCap,
    minMemberDeposit: r.minMemberDeposit,
  };
}

/** Progressive fee on a total position size, mirroring the contract's bracket math (6-decimal bigints). */
export function progressiveTax(size, params) {
  let total = 0n;
  let lower = 0n;
  for (let i = 0; i < 4 && size > lower; i++) {
    const upper = i < 3 ? params.feeBrackets[i] : size;
    const slice = (size < upper ? size : upper) - lower;
    total += (slice * BigInt(params.feeRatesBps[i])) / 10_000n;
    lower = upper;
  }
  return total;
}

const exchangeInterface = new Interface([...EXCHANGE_ABI, ...COUNCIL_ABI.filter((f) => f.startsWith("error"))]);

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

const FRIENDLY_ERRORS = {
  MarketDisabled: "This market has been paused by the Council.",
  StalePrice: "The oracle price is stale. Try again shortly.",
  InvalidPrice: "The oracle returned an invalid price.",
  MarginTooSmall: "Margin is below the 10 USDC minimum.",
  InvalidLeverage: "Leverage is above the market maximum.",
  DirectionMismatch: "Close your current position before opening one in the other direction.",
  NoPosition: "You have no open position.",
  InvalidSize: "Invalid size.",
  UtilizationExceeded: "The Collective can't take on that much open interest right now.",
  WhaleCapExceeded: "That would take you over the whale cap. No one gets to be that big here.",
  NotLiquidatable: "That position isn't liquidatable.",
  WouldBeLiquidatable: "That change would put the position below maintenance margin.",
  InsufficientLiquidity: "The Collective doesn't have enough free liquidity.",
  ZeroAmount: "Enter an amount.",
  NotMember: "Only members of the Collective can do that. Deposit at least 100 USDC to join.",
  NonTransferable: "Membership can't be bought or sold.",
  InvalidParams: "Those parameters are out of bounds.",
  NotEligible: "Only wallets that were members before this proposal was made can vote on it.",
  AlreadyVoted: "You've already voted on this proposal.",
  VotingClosed: "Voting on this proposal has ended.",
  VotingOpen: "Voting is still open.",
  AlreadyExecuted: "This proposal was already enacted.",
  Rejected: "This proposal didn't pass (not enough yes votes, or quorum not reached).",
  UnknownProposal: "No such proposal.",
};

export function describeError(err) {
  const name = revertName(err);
  if (name && FRIENDLY_ERRORS[name]) return FRIENDLY_ERRORS[name];
  if (err?.code === "ACTION_REJECTED") return "Transaction rejected in wallet.";
  if (err?.code === "INSUFFICIENT_FUNDS") return "Not enough ETH for gas. Get test ETH from a faucet.";
  return err?.shortMessage || err?.message || "Something went wrong.";
}
