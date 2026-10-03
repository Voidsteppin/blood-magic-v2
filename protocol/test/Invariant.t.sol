// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {Trade} from "../src/Trade.sol";
import {Pool} from "../src/Pool.sol";
import {Store} from "../src/Store.sol";
import {IStore} from "../src/interfaces/IStore.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";

/// @dev Random traders, LPs, price moves, keepers and liquidations.
contract Handler is Test {
    Trade internal trade;
    Pool internal pool;
    Store internal store;
    MockAggregator internal feed;
    address[] internal traders;
    address internal keeper;
    int256 internal price = 2000e8;

    constructor(Trade _trade, Pool _pool, Store _store, MockAggregator _feed, address[] memory _traders, address _keeper) {
        trade = _trade;
        pool = _pool;
        store = _store;
        feed = _feed;
        traders = _traders;
        keeper = _keeper;
    }

    function _trader(uint256 seed) internal view returns (address) {
        return traders[seed % traders.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1e6, 20_000e6);
        vm.prank(_trader(seed));
        trade.deposit(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address t = _trader(seed);
        uint256 bal = store.getBalance(t);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(t);
        try trade.withdraw(amount) {} catch {}
    }

    function order(uint256 seed, bool isLong, bool reduceOnly, uint8 orderType, uint256 margin, uint256 leverage, int256 offset)
        external
    {
        IStore.Order memory o;
        o.market = "ETH-USD";
        o.isLong = isLong;
        o.isReduceOnly = reduceOnly;
        o.orderType = uint8(bound(orderType, 0, 2));
        o.margin = bound(margin, 1e6, 3_000e6);
        o.size = o.margin * bound(leverage, 1, 50);
        if (o.size < 20e6) o.size = 20e6;
        o.price = uint256(price + bound(offset, -200e8, 200e8)) * 1e10;
        vm.prank(_trader(seed));
        try trade.submitOrder(o, 0, 0) {} catch {}
    }

    function movePrice(int256 move) external {
        price += bound(move, -60e8, 60e8);
        if (price < 500e8) price = 500e8;
        vm.warp(block.timestamp + 61);
        feed.setPrice(price);
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 6 hours));
        feed.setUpdatedAt(block.timestamp);
    }

    function keep() external {
        vm.startPrank(keeper);
        trade.executeOrders();
        trade.liquidateUsers();
        vm.stopPrank();
    }

    function addLiquidity(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1e6, 50_000e6);
        vm.prank(_trader(seed));
        pool.addLiquidity(amount);
    }

    function removeLiquidity(uint256 seed, uint256 amount) external {
        address t = _trader(seed);
        if (store.getUserPoolBalance(t) == 0) return;
        amount = bound(amount, 1, store.getUserPoolBalance(t));
        vm.prank(t);
        try pool.removeLiquidity(amount) {} catch {}
    }

    function claim(uint256 seed) external {
        vm.prank(_trader(seed));
        pool.claimDividend();
    }
}

contract InvariantTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory traders = new address[](3);
        traders[0] = alice;
        traders[1] = bob;
        traders[2] = carol;
        handler = new Handler(trade, pool, store, feed, traders, keeper);
        targetContract(address(handler));
    }

    function invariant_StoreIsSolvent() public view {
        _assertSolvent();
    }

    function invariant_OpenInterestMatchesPositions() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += store.getPosition(actors[i], ETH).size;
        }
        assertEq(store.totalOI(), sum);
        assertEq(store.getOILong(ETH) + store.getOIShort(ETH), sum);
    }

    function invariant_LockedMarginCoversPositionsAndOrders() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint256 locked = store.getPosition(a, ETH).margin;
            IStore.Order[] memory orders = store.getUserOrders(a);
            for (uint256 j = 0; j < orders.length; j++) {
                locked += orders[j].margin;
            }
            assertEq(store.getLockedMargin(a), locked);
        }
    }

    function invariant_KeepersNeverBlocked() public {
        vm.startPrank(keeper);
        trade.executeOrders();
        trade.liquidateUsers();
        vm.stopPrank();
    }
}
