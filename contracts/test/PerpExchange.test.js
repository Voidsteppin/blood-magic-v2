const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const ETH_USD = ethers.encodeBytes32String("ETH-USD");
const usdc = (n) => ethers.parseUnits(String(n), 6);
const feedPrice = (n) => ethers.parseUnits(String(n), 8);
const price18 = (n) => ethers.parseUnits(String(n), 18);

describe("PerpExchange", function () {
  async function deploy() {
    const [owner, lp, trader, other, liquidator] = await ethers.getSigners();

    const USDC = await ethers.deployContract("MockUSDC");
    const feed = await ethers.deployContract("MockAggregator", [8, feedPrice(2000)]);
    const ex = await ethers.deployContract("PerpExchange", [await USDC.getAddress()]);
    await ex.setMarket(ETH_USD, await feed.getAddress(), 50, true);

    for (const s of [lp, trader, other]) {
      await USDC.mint(s.address, usdc(100_000));
      await USDC.connect(s).approve(await ex.getAddress(), ethers.MaxUint256);
    }
    await ex.connect(lp).addLiquidity(usdc(100_000));

    return { USDC, feed, ex, owner, lp, trader, other, liquidator };
  }

  describe("liquidity", function () {
    it("mints shares and tracks the pool balance", async function () {
      const { ex, lp } = await loadFixture(deploy);
      expect(await ex.poolBalance()).to.equal(usdc(100_000));
      expect(await ex.balanceOf(lp.address)).to.be.gt(0);
      expect(await ex.poolValue()).to.equal(usdc(100_000));
    });

    it("returns the deposit on full withdrawal when there are no trades", async function () {
      const { ex, USDC, lp } = await loadFixture(deploy);
      await ex.connect(lp).removeLiquidity(await ex.balanceOf(lp.address));
      expect(await USDC.balanceOf(lp.address)).to.be.closeTo(usdc(100_000), 1);
    });

    it("prices LP shares net of traders' unrealized profit", async function () {
      const { ex, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10); // 10k long
      await feed.setPrice(feedPrice(2200)); // +10% => trader up 1,000
      // pool = 100,000 + 10 fee, minus 1,000 unrealized trader profit
      expect(await ex.poolValue()).to.equal(usdc(99_010));
    });

    it("blocks withdrawals that would push utilization over the limit", async function () {
      const { ex, lp, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(800), 50); // 40k OI
      const shares = await ex.balanceOf(lp.address);
      await expect(ex.connect(lp).removeLiquidity(shares / 2n)).to.be.revertedWithCustomError(ex, "UtilizationExceeded");
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
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000 - 1010));
      expect(await ex.poolBalance()).to.equal(usdc(100_010));
    });

    it("pays profit on a winning long", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      await feed.setPrice(feedPrice(2200));
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(10_000));

      // payout = 1000 margin + 1000 pnl - 10 close fee
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000 - 1010 + 1990));
      expect(await ex.poolBalance()).to.equal(usdc(100_010 + 1000 - 1990));
      expect((await ex.getPositionInfo(trader.address, ETH_USD)).size).to.equal(0);
      expect(await ex.totalOpenInterest()).to.equal(0);
    });

    it("collects the loss on a losing short", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, false, usdc(1000), 10);
      await feed.setPrice(feedPrice(2100)); // +5% => short down 500
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(10_000));

      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000 - 1010 + 490));
      expect(await ex.poolBalance()).to.equal(usdc(100_010 + 510));
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
      // closed 40%: 400 margin + 400 pnl - 4 fee
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000 - 1010 + 796));
    });

    it("averages the entry price when adding to a position", async function () {
      const { ex, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10); // 5 ETH @ 2000
      await feed.setPrice(feedPrice(2500));
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10); // 4 ETH @ 2500
      const info = await ex.getPositionInfo(trader.address, ETH_USD);
      // 20,000 notional / 9 ETH
      expect(info.entryPrice).to.be.closeTo(price18("2222.222222222222222222"), price18("0.000001"));
    });

    it("adds margin and lowers the liquidation price", async function () {
      const { ex, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      const before = (await ex.getPositionInfo(trader.address, ETH_USD)).liquidationPrice;
      await ex.connect(trader).addMargin(ETH_USD, usdc(500));
      const after = (await ex.getPositionInfo(trader.address, ETH_USD)).liquidationPrice;
      expect(after).to.be.lt(before);
    });

    it("caps profit at 100% of size", async function () {
      const { ex, USDC, feed, trader } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(100), 10); // 1,000 size
      await feed.setPrice(feedPrice(8000)); // 4x
      await ex.connect(trader).decreasePosition(ETH_USD, usdc(1000));
      // payout = 100 margin + 1000 capped pnl - 1 fee
      expect(await USDC.balanceOf(trader.address)).to.equal(usdc(100_000 - 101 + 1099));
    });
  });

  describe("liquidation", function () {
    it("reports the right liquidation price", async function () {
      const { ex, trader, other } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);
      // long: (10,000 + 100 maintenance - 1,000) / 5 ETH = 1,820
      expect((await ex.getPositionInfo(trader.address, ETH_USD)).liquidationPrice).to.equal(price18(1820));

      await ex.connect(other).increasePosition(ETH_USD, false, usdc(1000), 10);
      // short: (1,000 + 10,000 - 100) / 5 ETH = 2,180
      expect((await ex.getPositionInfo(other.address, ETH_USD)).liquidationPrice).to.equal(price18(2180));
    });

    it("liquidates below the liquidation price and rewards the liquidator", async function () {
      const { ex, USDC, feed, trader, liquidator } = await loadFixture(deploy);
      await ex.connect(trader).increasePosition(ETH_USD, true, usdc(1000), 10);

      await feed.setPrice(feedPrice(1830));
      await expect(ex.connect(liquidator).liquidate(trader.address, ETH_USD)).to.be.revertedWithCustomError(ex, "NotLiquidatable");

      await feed.setPrice(feedPrice(1810));
      await expect(ex.connect(liquidator).liquidate(trader.address, ETH_USD)).to.emit(ex, "Liquidated");

      expect(await USDC.balanceOf(liquidator.address)).to.equal(usdc(50)); // 5% of 1,000 margin
      expect(await ex.poolBalance()).to.equal(usdc(100_010 + 950));
      expect((await ex.getPositionInfo(trader.address, ETH_USD)).size).to.equal(0);
      expect(await ex.totalOpenInterest()).to.equal(0);
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
      const { ex, trader } = await loadFixture(deploy);
      // 50% of a 100k pool is 50k; this is 60k
      await expect(ex.connect(trader).increasePosition(ETH_USD, true, usdc(1200), 50)).to.be.revertedWithCustomError(ex, "UtilizationExceeded");
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
      await expect(ex.connect(trader).decreasePosition(ETH_USD, usdc(500))).to.not.be.reverted;
    });

    it("only lets the owner change markets and parameters", async function () {
      const { ex, feed, trader } = await loadFixture(deploy);
      await expect(ex.connect(trader).setMarket(ETH_USD, await feed.getAddress(), 100, true)).to.be.revertedWithCustomError(
        ex,
        "OwnableUnauthorizedAccount"
      );
      await expect(ex.connect(trader).setParams(10, 100, 500, 5000, 10000, 1, 1)).to.be.revertedWithCustomError(
        ex,
        "OwnableUnauthorizedAccount"
      );
    });
  });
});
