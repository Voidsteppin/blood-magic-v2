// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Store} from "../src/Store.sol";
import {Trade} from "../src/Trade.sol";
import {Pool} from "../src/Pool.sol";
import {CLP} from "../src/CLP.sol";
import {Chainlink} from "../src/Chainlink.sol";
import {Council} from "../src/Council.sol";
import {IStore} from "../src/interfaces/IStore.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {Config} from "../script/Config.sol";

abstract contract Base is Test {
    uint256 internal constant U = 1e6; // one USDC
    string internal constant ETH = "ETH-USD";
    int256 internal constant START_PRICE = 2000e8;

    MockUSDC internal usdc;
    MockAggregator internal feed;
    Store internal store;
    Trade internal trade;
    Pool internal pool;
    CLP internal clp;
    Chainlink internal chainlink;

    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address[] internal actors;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        feed = new MockAggregator(8, START_PRICE);

        store = new Store(address(this), Config.defaultParams());
        trade = new Trade(address(this));
        pool = new Pool(address(this));
        clp = new CLP(address(store));
        chainlink = new Chainlink(address(0));

        store.link(address(trade), address(pool), address(usdc), address(clp));
        trade.link(address(chainlink), address(pool), address(store));
        pool.link(address(trade), address(store));
        store.setMarket(ETH, Config.ethMarket(address(feed)));

        actors = [lp, alice, bob, carol, keeper];
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 1_000_000 * U);
            vm.prank(actors[i]);
            usdc.approve(address(store), type(uint256).max);
        }

        vm.prank(lp);
        pool.addLiquidity(100_000 * U);
    }

    // ---------- helpers ----------

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        trade.deposit(amount);
    }

    function _order(address user, bool isLong, uint256 margin, uint256 size) internal returns (uint256) {
        return _orderFull(user, isLong, false, 0, 0, margin, size, 0, 0);
    }

    function _orderFull(
        address user,
        bool isLong,
        bool reduceOnly,
        uint8 orderType,
        uint256 price,
        uint256 margin,
        uint256 size,
        uint256 tp,
        uint256 sl
    ) internal returns (uint256) {
        IStore.Order memory o;
        o.isLong = isLong;
        o.isReduceOnly = reduceOnly;
        o.orderType = orderType;
        o.market = ETH;
        o.price = price;
        o.margin = margin;
        o.size = size;
        vm.prank(user);
        return trade.submitOrder(o, tp, sl);
    }

    /// @dev Moves the oracle (8 decimals) and lets a little time pass, like a real feed update.
    function _setPrice(int256 price) internal {
        vm.warp(block.timestamp + 5);
        feed.setPrice(price);
    }

    function _execute() internal {
        vm.prank(keeper);
        trade.executeOrders();
    }

    /// @dev Waits out the settlement delay so market orders fill at the unchanged price.
    function _settleAndExecute() internal {
        vm.warp(block.timestamp + 31);
        feed.setUpdatedAt(block.timestamp);
        _execute();
    }

    function _position(address user) internal view returns (IStore.Position memory) {
        return store.getPosition(user, ETH);
    }

    function _tax(uint256 size) internal view returns (uint256) {
        return trade.getTax(size);
    }

    /// @dev Every token the Store holds is owed to someone: traders, the pool, the buffer, the fund or members.
    function _assertSolvent() internal view {
        uint256 owed = store.poolBalance() + store.bufferBalance() + store.solidarityFund() + store.dividendReserve();
        for (uint256 i = 0; i < actors.length; i++) {
            owed += store.getBalance(actors[i]);
        }
        assertEq(usdc.balanceOf(address(store)), owed, "store holds exactly what it owes");
    }
}
