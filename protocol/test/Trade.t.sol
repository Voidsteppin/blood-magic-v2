// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {IStore} from "../src/interfaces/IStore.sol";
import {ITrade} from "../src/interfaces/ITrade.sol";

contract TradeTest is Base {
    // ---------- deposits ----------

    function test_DepositAndWithdraw() public {
        _deposit(alice, 1_000 * U);
        assertEq(store.getBalance(alice), 1_000 * U);
        vm.prank(alice);
        trade.withdraw(400 * U);
        assertEq(store.getBalance(alice), 600 * U);
        _assertSolvent();
    }

    function test_CannotWithdrawLockedMargin() public {
        _deposit(alice, 1_000 * U);
        _order(alice, true, 900 * U, 9_000 * U);
        vm.prank(alice);
        vm.expectRevert("!equity");
        trade.withdraw(200 * U);
    }

    // ---------- order flow ----------

    function test_MarketOrderWaitsForKeeperAndNewPrice() public {
        _deposit(alice, 1_000 * U);
        uint256 id = _order(alice, true, 100 * U, 1_000 * U);

        // Nothing fills at the price the trader already saw
        assertEq(trade.getExecutableOrderIds().length, 0);

        _setPrice(2010e8);
        uint256[] memory ids = trade.getExecutableOrderIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], id);

        _execute();
        IStore.Position memory p = _position(alice);
        assertEq(p.size, 1_000 * U);
        assertEq(p.margin, 100 * U);
        assertEq(p.price, 2010e18, "filled at the new price, not the submit price");
        assertEq(store.getOrders().length, 0);
        _assertSolvent();
    }

    function test_MarketOrderFillsAfterSettlementTimeWithoutNewPrice() public {
        _deposit(alice, 1_000 * U);
        _order(alice, true, 100 * U, 1_000 * U);
        _settleAndExecute();
        assertEq(_position(alice).size, 1_000 * U);
    }

    function test_KeeperEarnsShareOfFee() public {
        _deposit(alice, 1_000 * U);
        _order(alice, true, 100 * U, 5_000 * U);
        _setPrice(2001e8);
        _execute();
        uint256 fee = _tax(5_000 * U);
        assertEq(store.getBalance(keeper), fee * 1000 / 10000);
        assertEq(store.getBalance(alice), 1_000 * U - fee);
    }

    function test_TraderChoosesLeverage() public {
        _deposit(alice, 10_000 * U);
        _order(alice, true, 1_000 * U, 3_000 * U); // 3x
        assertEq(store.getLockedMargin(alice), 1_000 * U);

        IStore.Order memory o;
        o.market = ETH;
        o.isLong = true;
        o.margin = 100 * U;
        o.size = 5_001 * U; // just over 50x
        vm.prank(alice);
        vm.expectRevert("!leverage");
        trade.submitOrder(o, 0, 0);
    }

    function test_CannotOrderBeyondEquity() public {
        _deposit(alice, 100 * U);
        IStore.Order memory o;
        o.market = ETH;
        o.isLong = true;
        o.margin = 100 * U; // leaves nothing for the fee
        o.size = 1_000 * U;
        vm.prank(alice);
        vm.expectRevert("!equity");
        trade.submitOrder(o, 0, 0);
    }

    // ---------- progressive fees & whale cap ----------

    function test_ProgressiveFeeBrackets() public {
        // $1K at 0.05% + $9K at 0.10% + $10K at 0.25%
        assertEq(_tax(20_000 * U), 500_000 + 9_000_000 + 25_000_000);
        // Splitting a position into pieces costs the same as opening it at once
        assertEq(trade.getOpeningFee(alice, ETH, true, 20_000 * U), _tax(20_000 * U));

        _deposit(alice, 10_000 * U);
        _order(alice, true, 500 * U, 5_000 * U);
        _setPrice(2000e8 + 1);
        _execute();
        assertEq(trade.getOpeningFee(alice, ETH, true, 15_000 * U), _tax(20_000 * U) - _tax(5_000 * U));
    }

    function test_WhaleCapRejectsWithoutBlockingOtherOrders() public {
        _deposit(alice, 10_000 * U);
        _deposit(bob, 1_000 * U);
        _order(alice, true, 1_000 * U, 20_000 * U);
        uint256 tooBig = _order(alice, true, 1_000 * U, 10_000 * U); // would take her to $30K
        _order(bob, false, 100 * U, 1_000 * U);

        _setPrice(2005e8);
        vm.expectEmit(true, true, false, true);
        emit ITrade.OrderRejected(tooBig, alice, "!whale-cap");
        _execute();

        assertEq(_position(alice).size, 20_000 * U);
        assertEq(store.getLockedMargin(alice), 1_000 * U, "rejected order's margin is unlocked");
        assertEq(_position(bob).size, 1_000 * U, "bob's order still filled");
        assertEq(store.getOrders().length, 0);
        _assertSolvent();
    }

    function test_UtilizationLimitRejects() public {
        // Pool is $100K, so open interest is capped at $50K
        address[3] memory traders = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            _deposit(traders[i], 5_000 * U);
            _order(traders[i], true, 2_000 * U, 20_000 * U);
        }
        _setPrice(2001e8);
        _execute();
        assertEq(store.totalOI(), 40_000 * U, "third $20K order would exceed 50% of the pool");
        assertEq(_position(carol).size, 0);
    }

    // ---------- limit, stop, TP / SL ----------

    function test_LimitOrderFillsWhenPriceCrosses() public {
        _deposit(alice, 1_000 * U);
        vm.expectRevert("!trigger-price");
        _orderFull(alice, true, false, 1, 2100e18, 100 * U, 1_000 * U, 0, 0); // buy limit above market

        _orderFull(alice, true, false, 1, 1950e18, 100 * U, 1_000 * U, 0, 0);
        _setPrice(1960e8);
        assertEq(trade.getExecutableOrderIds().length, 0);
        _setPrice(1950e8);
        _execute();
        assertEq(_position(alice).price, 1950e18);
    }

    function test_TakeProfitClosesAndStopLossIsDropped() public {
        _deposit(alice, 1_000 * U);
        _orderFull(alice, true, false, 0, 0, 100 * U, 1_000 * U, 2100e18, 1900e18);
        assertEq(store.getUserOrders(alice).length, 3);
        _setPrice(2001e8);
        _execute();

        _setPrice(2100e8);
        _execute();
        assertEq(_position(alice).size, 0, "take-profit closed the long");
        assertEq(store.getLockedMargin(alice), 0);
        assertGt(store.getBalance(alice), 1_000 * U, "closed in profit");

        // The stop-loss is still resting; when it triggers it finds no position and is removed
        _setPrice(1890e8);
        _execute();
        assertEq(store.getUserOrders(alice).length, 0);
        _assertSolvent();
    }

    function test_CancelLimitOrderUnlocksMargin() public {
        _deposit(alice, 1_000 * U);
        uint256 id = _orderFull(alice, false, false, 1, 2100e18, 200 * U, 1_000 * U, 0, 0);
        assertEq(store.getLockedMargin(alice), 200 * U);
        vm.prank(alice);
        trade.cancelOrder(id);
        assertEq(store.getLockedMargin(alice), 0);
    }

    // ---------- closing ----------

    function test_CloseInLossChargesTraderFromFirstLoss() public {
        // CAP v4 skipped charging the very first trader loss; it must be charged
        _deposit(alice, 1_000 * U);
        _order(alice, true, 500 * U, 5_000 * U);
        _setPrice(2000e8 + 1);
        _execute();

        _setPrice(1900e8); // -5%
        _orderFull(alice, false, true, 0, 0, 0, 5_000 * U, 0, 0);
        _setPrice(1900e8 - 1);
        _execute();

        uint256 loss = 1_000 * U - store.getBalance(alice);
        assertApproxEqAbs(loss, 250 * U + _tax(5_000 * U) * 2, 2 * U, "~5% of $5K plus open and close fees");
        assertGt(store.bufferBalance(), 249 * U, "loss went into the buffer");
        assertEq(store.getLockedMargin(alice), 0);
        _assertSolvent();
    }

    function test_PartialCloseKeepsEntryAndReportsRemainder() public {
        _deposit(alice, 1_000 * U);
        _order(alice, false, 200 * U, 2_000 * U);
        _setPrice(2000e8 + 1);
        _execute();

        _orderFull(alice, true, true, 0, 0, 0, 1_000 * U, 0, 0);
        _setPrice(1990e8);
        _execute();
        IStore.Position memory p = _position(alice);
        assertEq(p.size, 1_000 * U);
        assertEq(p.margin, 100 * U);
        assertEq(p.price, 2000e18 + 1e10);
        _assertSolvent();
    }

    function test_ProfitIsCappedAtSize() public {
        _deposit(alice, 1_000 * U);
        _order(alice, true, 100 * U, 1_000 * U);
        _setPrice(2000e8 + 1);
        _execute();

        _setPrice(6000e8); // +200%
        _orderFull(alice, false, true, 0, 0, 0, 1_000 * U, 0, 0);
        _setPrice(6000e8 + 1);
        _execute();
        uint256 gain = store.getBalance(alice) - 1_000 * U;
        assertLe(gain, 1_000 * U, "profit capped at 100% of size");
        assertGt(gain, 990 * U);
    }

    function test_OppositeOrderFlipsPosition() public {
        _deposit(alice, 2_000 * U);
        _order(alice, true, 100 * U, 1_000 * U);
        _setPrice(2000e8 + 1);
        _execute();

        _order(alice, false, 300 * U, 3_000 * U);
        _setPrice(2000e8 + 2);
        _execute();
        IStore.Position memory p = _position(alice);
        assertFalse(p.isLong);
        assertEq(p.size, 2_000 * U);
        assertEq(p.margin, 200 * U);
        assertEq(store.getLockedMargin(alice), 200 * U);
        _assertSolvent();
    }

    // ---------- liquidation ----------

    function test_LiquidationChargesMarginOnceAndRefundsSmallTraders() public {
        // Fees from earlier trading fill the solidarity fund
        _deposit(bob, 20_000 * U);
        _order(bob, false, 2_000 * U, 20_000 * U);
        _setPrice(2000e8 + 1);
        _execute();
        uint256 fund = store.solidarityFund();
        assertGt(fund, 0);

        _deposit(alice, 120 * U);
        _order(alice, true, 100 * U, 5_000 * U); // 50x
        _setPrice(2000e8 + 2);
        _execute();
        uint256 balanceBefore = store.getBalance(alice);

        _setPrice(1955e8); // -2.25%: equity below 20% of locked margin
        address[] memory liq = trade.getLiquidatableUsers();
        assertEq(liq.length, 1);
        assertEq(liq[0], alice);

        // The liquidation fee itself pays into the fund before the refund comes out
        uint256 liqFee = _tax(5_000 * U);
        fund = store.solidarityFund() + (liqFee - liqFee / 10) * 2000 / 10000;
        vm.prank(keeper);
        trade.liquidateUsers();

        uint256 refund = fund < 25 * U ? fund : 25 * U;
        assertEq(store.getBalance(alice), balanceBefore - 100 * U + refund, "margin taken once, 25% refunded");
        assertEq(_position(alice).size, 0);
        assertEq(store.getLockedMargin(alice), 0);
        assertEq(trade.getLiquidatableUsers().length, 0);
        _assertSolvent();
    }

    function test_LiquidationCancelsPendingOrders() public {
        _deposit(alice, 63 * U);
        _order(alice, true, 50 * U, 2_500 * U);
        _setPrice(2000e8 + 1);
        _execute();
        _orderFull(alice, true, false, 1, 1000e18, 10 * U, 100 * U, 0, 0);

        _setPrice(1960e8);
        vm.prank(keeper);
        trade.liquidateUsers();
        assertEq(store.getUserOrders(alice).length, 0);
        assertEq(store.getLockedMargin(alice), 0);
    }

    // ---------- funding ----------

    function test_LongsPayFundingWhenSkewed() public {
        _deposit(alice, 1_100 * U);
        _order(alice, true, 1_000 * U, 10_000 * U);
        _setPrice(2000e8 + 1);
        _execute();
        int256 uplBefore = trade.getUpl(alice);

        vm.warp(block.timestamp + 10 hours);
        feed.setUpdatedAt(block.timestamp);
        int256 uplAfter = trade.getUpl(alice);
        // 50% a year, fully skewed, for 10 hours on $10K ≈ $5.71
        assertApproxEqAbs(uplBefore - uplAfter, 5_707_762, 10);
    }

    // ---------- oracle ----------

    function test_StalePriceBlocksOrdersAndExecution() public {
        _deposit(alice, 1_000 * U);
        _order(alice, true, 100 * U, 1_000 * U);
        vm.warp(block.timestamp + 27 hours);
        assertEq(trade.getExecutableOrderIds().length, 0, "nothing fills on a stale price");

        IStore.Order memory o;
        o.market = ETH;
        o.isLong = true;
        o.margin = 100 * U;
        o.size = 1_000 * U;
        vm.prank(alice);
        vm.expectRevert("!price");
        trade.submitOrder(o, 0, 0);
    }

    // ---------- wiring ----------

    function test_LinkOnlyOnce() public {
        vm.expectRevert("!linked");
        store.link(address(1), address(2), address(3), address(4));
        vm.expectRevert("!linked");
        trade.link(address(1), address(2), address(3));
        vm.expectRevert("!linked");
        pool.link(address(1), address(2));
    }
}
