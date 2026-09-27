const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const ETH_USD = ethers.encodeBytes32String("ETH-USD");
const usdc = (n) => ethers.parseUnits(String(n), 6);
const feedPrice = (n) => ethers.parseUnits(String(n), 8);
const price18 = (n) => ethers.parseUnits(String(n), 18);

// Mirrors the contract's default progressive fee schedule.
const BRACKETS = [usdc(1_000), usdc(10_000), usdc(50_000)];
const RATES = [5n, 10n, 25n, 50n];
function tax(size) {
  let total = 0n;
  let lower = 0n;
  for (let i = 0; i < 4 && size > lower; i++) {
    const upper = i < 3 ? BRACKETS[i] : ethers.MaxUint256;
    const slice = (size < upper ? size : upper) - lower;
    total += (slice * RATES[i]) / 10_000n;
    lower = upper;
  }
  return total;
}
// Fee split: 20% solidarity fund, 30% equal member dividends (if any members), rest to the pool.
function split(fee, hasMembers = true) {
  const solidarity = (fee * 2_000n) / 10_000n;
  const members = hasMembers ? (fee * 3_000n) / 10_000n : 0n;
  return { solidarity, members, pool: fee - solidarity - members };
}
const toParams = (r) => ({
  feeRatesBps: [...r.feeRatesBps],
  feeBrackets: [...r.feeBrackets],
  maintenanceMarginBps: r.maintenanceMarginBps,
  liquidatorRewardBps: r.liquidatorRewardBps,
  maxUtilizationBps: r.maxUtilizationBps,
  maxProfitBps: r.maxProfitBps,
  minMargin: r.minMargin,
  maxPriceAge: r.maxPriceAge,
  maxPositionSize: r.maxPositionSize,
  dividendShareBps: r.dividendShareBps,
  solidarityShareBps: r.solidarityShareBps,
  solidarityRefundBps: r.solidarityRefundBps,
  solidarityMarginCap: r.solidarityMarginCap,
  minMemberDeposit: r.minMemberDeposit,
});

async function deploy() {
  const signers = await ethers.getSigners();
  const [owner, lp, trader, other, liquidator] = signers;

  const USDC = await ethers.deployContract("MockUSDC");
  const feed = await ethers.deployContract("MockAggregator", [8, feedPrice(2000)]);
  const ex = await ethers.deployContract("PerpExchange", [await USDC.getAddress()]);
  await ex.setMarket(ETH_USD, await feed.getAddress(), 50, true);

  for (const s of signers.slice(1, 15)) {
    await USDC.mint(s.address, usdc(100_000));
    await USDC.connect(s).approve(await ex.getAddress(), ethers.MaxUint256);
  }
  await ex.connect(lp).addLiquidity(usdc(100_000));

  return { USDC, feed, ex, owner, lp, trader, other, liquidator, signers };
}

// Every USDC the contract holds must belong to exactly one bucket.
async function expectSolvent(ex, USDC, traders) {
  let margins = 0n;
  for (const t of traders) margins += (await ex.positions(t.address, ETH_USD)).margin;
  const buckets = (await ex.poolBalance()) + (await ex.solidarityFund()) + (await ex.dividendReserve()) + margins;
  const held = await USDC.balanceOf(await ex.getAddress());
  expect(held).to.be.gte(buckets);
  expect(held - buckets).to.be.lte(10n); // rounding dust only
}

describe("PerpExchange", function () {
  describe("the Collective", function () {
    it("makes depositors members and tracks the pool", async function () {
      const { ex, lp } = await loadFixture(deploy);
      expect(await ex.poolBalance()).to.equal(usdc(100_000));
      expect(await ex.poolValue()).to.equal(usdc(100_000));
      expect(await ex.isMember(lp.address)).to.equal(true);
      expect(await ex.memberCount()).to.equal(1);
    });

    it("requires the minimum deposit for membership", async function () {
      const { ex, other } = await loadFixture(deploy);
      await ex.connect(other).addLiquidity(usdc(50));
      expect(await ex.isMember(other.address)).to.equal(false);
      await ex.connect(other).addLiquidity(usdc(50));
      expect(await ex.isMember(other.address)).to.equal(true);
    });

    it("returns the deposit on withdrawal and ends membership", async function () {
      const { ex, USDC, lp } = await loadFixture(deploy);
      await ex.connect(lp).removeLiquidity(await ex.balanceOf(lp.address));
      expect(await USDC.balanceOf(lp.address)).to.be.closeTo(usdc(100_000), 1);
      expect(await ex.isMember(lp.address)).to.equal(false);
      expect(await ex.memberCount()).to.equal(0);
    });

    it("does not let membership shares be sold or transferred", async function () {
      const { ex, lp, other } = await loadFixture(deploy);
      await expect(ex.connect(lp).transfer(other.address, 1n)).to.be.revertedWithCustomError(ex, "NonTransferable");
    });

    it("splits member dividends equally regardless of deposit size", async function () {
      const { ex, USDC, lp, other, trader } = await loadFixture(deploy);
      await ex.connect(other).addLiquidity(usdc(100)); // 1,000x smaller than lp's deposit
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);

      const { members } = split(tax(usdc(10_000)));
      expect(await ex.pendingDividend(lp.address)).to.equal(members / 2n);
      expect(await ex.pendingDividend(other.address)).to.equal(members / 2n);

      const before = await USDC.balanceOf(other.address);
      await ex.connect(other).claimDividend();
      expect((await USDC.balanceOf(other.address)) - before).to.equal(members / 2n);
      expect(await ex.pendingDividend(other.address)).to.equal(0);
    });

    it("prices shares net of traders' unrealized profit", async function () {
      const { ex, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      await feed.setPrice(feedPrice(2200)); // +10% => trader up 1,000
      const { pool } = split(tax(usdc(10_000)));
      expect(await ex.poolValue()).to.equal(usdc(100_000) + pool - usdc(1000));
    });

    it("blocks withdrawals that would push utilization over the limit", async function () {
      const { ex, lp, trader, other } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(500), 50); // 25k
      await ex.connect(other).increasePosition(ETH_USD, false, usdc(500), 40); // 20k
      const shares = await ex.balanceOf(lp.address);
      await expect(ex.connect(lp).removeLiquidity(shares / 2n)).to.be.revertedWithCustomError(ex, "UtilizationExceeded");
    });
  });

  describe("progressive fees and whale cap", function () {
    it("charges marginal bracket rates", async function () {
      const { ex, trader } = await loadFixture(deploy);
      expect(await ex.openingFee(trader.address, ETH_USD, usdc(500))).to.equal(usdc("0.25")); // 0.05%
      expect(await ex.openingFee(trader.address, ETH_USD, usdc(10_000))).to.equal(usdc("9.5")); // 1k@0.05% + 9k@0.10%
      expect(await ex.openingFee(trader.address, ETH_USD, usdc(25_000))).to.equal(usdc(47)); // + 15k@0.25%
    });

    it("can't be dodged by splitting a trade into pieces", async function () {
      const { ex, USDC, trader, other } = await loadFixture(deploy);
      const b1 = await USDC.balanceOf(trader.address);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(2000), 10);
      const oneShot = b1 - (await USDC.balanceOf(trader.address));

      const b2 = await USDC.balanceOf(other.address);
      for (let i = 0; i < 4; i++) await ex.connect(other).increasePosition(ETH_USD, true, usdc(500), 10);
      const split4 = b2 - (await USDC.balanceOf(other.address));

      expect(split4).to.equal(oneShot);
    });

    it("splits every fee between the pool, members and the solidarity fund", async function () {
      const { ex, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      const s = split(tax(usdc(10_000)));
      expect(await ex.poolBalance()).to.equal(usdc(100_000) + s.pool);
      expect(await ex.dividendReserve()).to.equal(s.members);
      expect(await ex.solidarityFund()).to.equal(s.solidarity);
    });

    it("caps position size per wallet", async function () {
      const { ex, trader } = await loadFixture(deploy);
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(500), 50)).to.not.be.reverted; // exactly 25k
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(10), 1)).to.be.revertedWithCustomError(ex, "WhaleCapExceeded");
    });
  });

  describe("trading", function () {
    it("opens a long and charges the fee on top of margin", async function () {
      const { ex, USDC, trader } = await loadFixture(deploy);
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10)).to.emit(ex, "PositionIncreased");

      const info = await ex.getPositionInfo(trader.address, ETH_USD);
      expect(info.size).to.equal(usdc(10_000));
      expect(info.margin).to.equal(usdc(1000));
      expect(info.entryPrice).to.equal(price18(2000));
      expect(info.isLong).to.equal(true);
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000) - usdc(1000) - tax(usdc(10_000)));
    });

    it("pays profit on a winning long", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      await feed.setPrice(feedPrice(2200));
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(10_000));

      const fee = tax(usdc(10_000));
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000) - usdc(1000) - fee + usdc(2000) - fee);
      expect(await ex.totalOpenInterest()).to.equal(0);
      await expectSolvent(ex, USDC, [trader]);
    });

    it("collects the loss on a losing short", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, false, usdc(1000), 10);
      await feed.setPrice(feedPrice(2100)); // +5% => short down 500
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(10_000));

      const fee = tax(usdc(10_000));
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000) - usdc(1000) - fee + usdc(500) - fee);
      await expectSolvent(ex, USDC, [trader]);
    });

    it("pays nothing and charges no fee when losses exceed margin", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(400), 50); // 20k
      const afterOpen = await USDC.balanceOf(trader.address);
      const poolBefore = await ex.poolBalance();
      await feed.setPrice(feedPrice(1940)); // -3% => -600 on 400 margin
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(20_000));
      expect(await USDC.balanceOf(trader.address)).to.equal(afterOpen);
      expect(await ex.poolBalance()).to.equal(poolBefore + usdc(400));
      await expectSolvent(ex, USDC, [trader]);
    });

    it("supports partial closes, releasing margin proportionally", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      await feed.setPrice(feedPrice(2200));
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(4000));

      const info = await ex.getPositionInfo(trader.address, ETH_USD);
      expect(info.size).to.equal(usdc(6000));
      expect(info.margin).to.equal(usdc(600));
      expect(info.entryPrice).to.equal(price18(2000));
      const closeFee = tax(usdc(10_000)) - tax(usdc(6000));
      expect(await USDC.balanceOf(trader.address)).to.equal(
        usdc(100_000) - usdc(1000) - tax(usdc(10_000)) + usdc(800) - closeFee
      );
      await expectSolvent(ex, USDC, [trader]);
    });

    it("averages the entry price when adding to a position", async function () {
      const { ex, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10); // 5 ETH @ 2000
      await feed.setPrice(feedPrice(2500));
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10); // 4 ETH @ 2500
      const info = await ex.getPositionInfo(trader.address, ETH_USD);
      expect(info.entryPrice).to.be.closeTo(price18("2222.222222222222222222"), price18("0.000001"));
    });

    it("adds margin and lowers the liquidation price", async function () {
      const { ex, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      const before = (await ex.getPositionInfo(trader.address, ETH_USD)).liquidationPrice;
      await ex.connect(trader).addMargin(ETH_USD, usdc(500));
      expect((await ex.getPositionInfo(trader.address, ETH_USD)).liquidationPrice).to.be.lt(before);
    });

    it("caps profit at 100% of size", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 10); // 1,000 size
      await feed.setPrice(feedPrice(8000)); // 4x
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(1000));
      const fee = tax(usdc(1000));
      // payout = 100 margin + 1,000 capped profit - close fee
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000) - usdc(100) - fee + usdc(1100) - fee);
    });
  });

  describe("liquidation and the solidarity fund", function () {
    it("reports the right liquidation price", async function () {
      const { ex, trader, other } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      expect((await ex.getPositionInfo(trader.address, ETH_USD)).liquidationPrice).to.equal(price18(1820));
      await ex.connect(other).increasePosition(ETH_USD, false, usdc(1000), 10);
      expect((await ex.getPositionInfo(other.address, ETH_USD)).liquidationPrice).to.equal(price18(2180));
    });

    it("liquidates below the liquidation price and rewards the liquidator", async function () {
      const { ex, USDC, feed, trader, liquidator } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);

      await feed.setPrice(feedPrice(1830));
      await expect(ex.connect(liquidator).liquidate(trader.address, ETH_USD)).to.be.revertedWithCustomError(ex, "NotLiquidatable");

      await feed.setPrice(feedPrice(1810));
      const traderBefore = await USDC.balanceOf(trader.address);
      const liquidatorBefore = await USDC.balanceOf(liquidator.address);
      await expect(ex.connect(liquidator).liquidate(trader.address, ETH_USD)).to.emit(ex, "Liquidated");

      expect((await USDC.balanceOf(liquidator.address)) - liquidatorBefore).to.equal(usdc(50)); // 5% of 1,000 margin
      expect(await USDC.balanceOf(trader.address)).to.equal(traderBefore); // margin > $500: no solidarity refund
      expect(await ex.totalOpenInterest()).to.equal(0);
      await expectSolvent(ex, USDC, [trader]);
    });

    it("refunds small traders from the solidarity fund", async function () {
      const { ex, USDC, feed, trader, other, liquidator } = await loadFixture(deploy);
      // Build up the fund with some round trips
      for (let i = 0; i < 12; i++) {
        await ex.connect(other).increasePosition(ETH_USD, true, usdc(500), 50);
        await ex.connect(other).decreasePosition(ETH_USD, usdc(25_000));
      }
      const fundBefore = await ex.solidarityFund();
      expect(fundBefore).to.be.gt(usdc(100));

      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(400), 10); // small: $400 margin
      const fundAfterOpen = await ex.solidarityFund();
      await feed.setPrice(feedPrice(1810));
      const before = await USDC.balanceOf(trader.address);
      await ex.connect(liquidator).liquidate(trader.address, ETH_USD);

      expect((await USDC.balanceOf(trader.address)) - before).to.equal(usdc(100)); // 25% of 400
      expect(await ex.solidarityFund()).to.equal(fundAfterOpen - usdc(100));
      await expectSolvent(ex, USDC, [trader, other]);
    });

    it("pays refunds only up to what the fund holds", async function () {
      const { ex, USDC, feed, trader, liquidator } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(400), 10);
      const fund = await ex.solidarityFund();
      await feed.setPrice(feedPrice(1810));
      const before = await USDC.balanceOf(trader.address);
      await ex.connect(liquidator).liquidate(trader.address, ETH_USD);
      expect((await USDC.balanceOf(trader.address)) - before).to.equal(fund);
      expect(await ex.solidarityFund()).to.equal(0);
    });
  });

  describe("safety checks", function () {
    it("rejects leverage above the market maximum", async function () {
      const { ex, trader } = await loadFixture(deploy);
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 51)).to.be.revertedWithCustomError(ex, "InvalidLeverage");
    });

    it("rejects margin below the minimum", async function () {
      const { ex, trader } = await loadFixture(deploy);
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(5), 2)).to.be.revertedWithCustomError(ex, "MarginTooSmall");
    });

    it("rejects flipping direction without closing first", async function () {
      const { ex, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 5);
      await expect(ex.connect(trader).increasePosition(ETH_USD, false, usdc(100), 5)).to.be.revertedWithCustomError(ex, "DirectionMismatch");
    });

    it("rejects trades that exceed pool utilization", async function () {
      const { ex, signers } = await loadFixture(deploy);
      // 50% of a 100k pool is 50k of open interest
      await ex.connect(signers[5]).increasePosition(ETH_USD, true, usdc(500), 50);
      await ex.connect(signers[6]).increasePosition(ETH_USD, true, usdc(500), 50);
      await expect(ex.connect(signers[7]).increasePosition(ETH_USD, true, usdc(100), 10)).to.be.revertedWithCustomError(
        ex,
        "UtilizationExceeded"
      );
    });

    it("rejects stale oracle prices", async function () {
      const { ex, feed, trader } = await loadFixture(deploy);
      await time.increase(2 * 24 * 60 * 60);
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 5)).to.be.revertedWithCustomError(ex, "StalePrice");
      await feed.setPrice(feedPrice(2000));
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 5)).to.not.be.reverted;
    });

    it("rejects trading on a disabled market but still allows closing", async function () {
      const { ex, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 5);
      await ex.setMarket(ETH_USD, await feed.getAddress(), 50, false);
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 5)).to.be.revertedWithCustomError(ex, "MarketDisabled");
      await expect(ex.connect(trader).decreasePosition(ETH_USD, usdc(250))).to.not.be.reverted;
    });

    it("rejects invalid parameters", async function () {
      const { ex } = await loadFixture(deploy);
      const p = toParams(await ex.getParams());
      await expect(ex.setParams({ ...p, feeBrackets: [usdc(10_000), usdc(1_000), usdc(50_000)] })).to.be.revertedWithCustomError(
        ex,
        "InvalidParams"
      );
      await expect(ex.setParams({ ...p, dividendShareBps: 8_000, solidarityShareBps: 3_000 })).to.be.revertedWithCustomError(ex, "InvalidParams");
    });
  });
});

describe("Council", function () {
  const HOUR = 60 * 60;

  async function deployWithCouncil() {
    const base = await deploy();
    const council = await ethers.deployContract("Council", [await base.ex.getAddress(), HOUR, 2_000]);
    await base.ex.transferOwnership(await council.getAddress());
    return { ...base, council };
  }

  async function proposeWhaleCap(ex, council, proposer, cap) {
    const p = toParams(await ex.getParams());
    const data = ex.interface.encodeFunctionData("setParams", [{ ...p, maxPositionSize: cap }]);
    await council.connect(proposer).propose(data, "Raise the whale cap");
    return (await council.proposalCount()) - 1n;
  }

  it("owns the exchange, so no single wallet can change it", async function () {
    const { ex, owner } = await loadFixture(deployWithCouncil);
    const p = toParams(await ex.getParams());
    await expect(ex.connect(owner).setParams(p)).to.be.revertedWithCustomError(ex, "OwnableUnauthorizedAccount");
  });

  it("only lets members propose", async function () {
    const { ex, council, other } = await loadFixture(deployWithCouncil);
    await expect(proposeWhaleCap(ex, council, other, usdc(50_000))).to.be.revertedWithCustomError(council, "NotMember");
  });

  it("passes and executes a proposal the members vote for", async function () {
    const { ex, council, lp } = await loadFixture(deployWithCouncil);
    const id = await proposeWhaleCap(ex, council, lp, usdc(50_000));
    await council.connect(lp).vote(id, true);

    await expect(council.execute(id)).to.be.revertedWithCustomError(council, "VotingOpen");
    await time.increase(HOUR);
    await council.execute(id);

    expect((await ex.getParams()).maxPositionSize).to.equal(usdc(50_000));
    await expect(council.execute(id)).to.be.revertedWithCustomError(council, "AlreadyExecuted");
  });

  it("gives every member one vote, whatever their deposit", async function () {
    const { ex, council, lp, signers } = await loadFixture(deployWithCouncil);
    // lp has 100,000 deposited; two small members with 100 each outvote them
    await ex.connect(signers[5]).addLiquidity(usdc(100));
    await ex.connect(signers[6]).addLiquidity(usdc(100));
    const id = await proposeWhaleCap(ex, council, lp, usdc(100_000));
    await council.connect(lp).vote(id, true);
    await council.connect(signers[5]).vote(id, false);
    await council.connect(signers[6]).vote(id, false);
    await time.increase(HOUR);
    await expect(council.execute(id)).to.be.revertedWithCustomError(council, "Rejected");
  });

  it("stops wallets that joined after the proposal from voting", async function () {
    const { ex, council, lp, other } = await loadFixture(deployWithCouncil);
    const id = await proposeWhaleCap(ex, council, lp, usdc(50_000));
    await ex.connect(other).addLiquidity(usdc(100));
    await expect(council.connect(other).vote(id, true)).to.be.revertedWithCustomError(council, "NotEligible");
  });

  it("rejects double votes", async function () {
    const { ex, council, lp } = await loadFixture(deployWithCouncil);
    const id = await proposeWhaleCap(ex, council, lp, usdc(50_000));
    await council.connect(lp).vote(id, true);
    await expect(council.connect(lp).vote(id, true)).to.be.revertedWithCustomError(council, "AlreadyVoted");
  });

  it("requires a quorum", async function () {
    const { ex, council, lp, signers } = await loadFixture(deployWithCouncil);
    for (let i = 5; i < 14; i++) await ex.connect(signers[i]).addLiquidity(usdc(100)); // 10 members => quorum 2
    const id = await proposeWhaleCap(ex, council, lp, usdc(50_000));
    await council.connect(lp).vote(id, true);
    await time.increase(HOUR);
    expect(await council.quorumFor(id)).to.equal(2);
    await expect(council.execute(id)).to.be.revertedWithCustomError(council, "Rejected");
  });
});
