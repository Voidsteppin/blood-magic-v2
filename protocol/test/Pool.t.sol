// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {CLP} from "../src/CLP.sol";

contract PoolTest is Base {
    function test_FirstDepositorIsMember() public view {
        assertEq(store.poolBalance(), 100_000 * U);
        assertEq(clp.balanceOf(lp), 100_000 * U);
        assertTrue(pool.isMember(lp));
        assertEq(pool.memberCount(), 1);
    }

    function test_SmallDepositIsNotMembership() public {
        vm.prank(alice);
        pool.addLiquidity(99 * U);
        assertFalse(pool.isMember(alice));
        vm.prank(alice);
        pool.addLiquidity(1 * U);
        assertTrue(pool.isMember(alice));
    }

    function test_RemoveLiquidityChargesWithdrawalFee() public {
        vm.prank(alice);
        pool.addLiquidity(10_000 * U);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.removeLiquidity(10_000 * U);
        assertEq(usdc.balanceOf(alice) - before, 10_000 * U - 10 * U, "0.1% fee");
        assertEq(clp.balanceOf(alice), 0, "all shares burned, fee included");
        assertEq(store.poolBalance(), 100_000 * U + 10 * U, "fee stays with remaining depositors");
        assertFalse(pool.isMember(alice));
        _assertSolvent();
    }

    function test_CannotWithdrawBelowOpenInterestLimit() public {
        _deposit(alice, 5_000 * U);
        _order(alice, true, 2_000 * U, 25_000 * U);
        _setPrice(2000e8 + 1);
        _execute();
        // $25K open needs a $50K pool at 50% utilization
        vm.prank(lp);
        vm.expectRevert("!utilization");
        pool.removeLiquidity(60_000 * U);
        vm.prank(lp);
        pool.removeLiquidity(40_000 * U);
    }

    function test_TraderLossesDripIntoPoolOverBufferPeriod() public {
        _deposit(alice, 1_000 * U);
        _order(alice, true, 500 * U, 5_000 * U);
        _setPrice(2000e8 + 1);
        _execute();
        _orderFull(alice, false, true, 0, 0, 0, 5_000 * U, 0, 0);
        _setPrice(1800e8);
        _execute();
        uint256 buffer = store.bufferBalance();
        assertGt(buffer, 400 * U);

        uint256 poolBefore = store.poolBalance();
        vm.warp(block.timestamp + 3.5 days);
        feed.setUpdatedAt(block.timestamp);
        // Any loss settlement drips the buffer; a tiny trade triggers one
        _deposit(bob, 100 * U);
        _order(bob, true, 10 * U, 100 * U);
        _setPrice(1800e8 + 1);
        _execute();
        _orderFull(bob, false, true, 0, 0, 0, 100 * U, 0, 0);
        _setPrice(1790e8);
        _execute();
        assertApproxEqRel(store.poolBalance() - poolBefore, buffer / 2, 0.02e18, "about half the buffer after half the period");
        _assertSolvent();
    }

    function test_ClpCannotBeTransferred() public {
        vm.prank(lp);
        vm.expectRevert(CLP.NonTransferable.selector);
        clp.transfer(alice, 1);
    }

    function test_MembersSplitDividendsEquallyWhateverTheyDeposited() public {
        vm.prank(alice);
        pool.addLiquidity(100 * U); // 1,000x smaller than lp
        assertEq(pool.memberCount(), 2);

        _deposit(bob, 3_000 * U);
        _order(bob, true, 2_000 * U, 20_000 * U);
        _setPrice(2000e8 + 1);
        _execute();

        uint256 fee = _tax(20_000 * U);
        uint256 toMembers = (fee - fee / 10) * 3000 / 10000;
        assertEq(pool.pendingDividend(lp), toMembers / 2);
        assertEq(pool.pendingDividend(alice), toMembers / 2);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.claimDividend();
        assertEq(usdc.balanceOf(alice) - before, toMembers / 2);
        assertEq(pool.pendingDividend(alice), 0);
        _assertSolvent();
    }

    function test_NewMembersDontGetPastDividends() public {
        _deposit(bob, 3_000 * U);
        _order(bob, true, 2_000 * U, 20_000 * U);
        _setPrice(2000e8 + 1);
        _execute();
        vm.prank(alice);
        pool.addLiquidity(100 * U);
        assertEq(pool.pendingDividend(alice), 0);
    }

    function test_FeeSplit() public {
        uint256 fundBefore = store.solidarityFund();
        uint256 poolBefore = store.poolBalance();
        _deposit(bob, 3_000 * U);
        _order(bob, true, 2_000 * U, 20_000 * U);
        _setPrice(2000e8 + 1);
        _execute();

        uint256 fee = _tax(20_000 * U);
        uint256 keeperFee = fee / 10;
        uint256 rest = fee - keeperFee;
        assertEq(store.getBalance(keeper), keeperFee);
        assertEq(store.solidarityFund() - fundBefore, rest * 2000 / 10000);
        assertEq(store.dividendReserve(), rest * 3000 / 10000);
        assertEq(store.poolBalance() - poolBefore, rest - rest * 2000 / 10000 - rest * 3000 / 10000);
    }
}
