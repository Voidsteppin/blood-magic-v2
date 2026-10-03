// SPDX-License-Identifier: BUSL-1.1
// Derived from CAP v4 (github.com/capofficial/protocol), (c) cap.io. Non-production use only.
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IStore} from "./interfaces/IStore.sol";

/// @title Pool
/// @notice The Collective: depositors are the counterparty to every trade. Anyone who keeps at
/// least `minMemberDeposit` in the pool is a member. Members split a share of every fee equally,
/// one member one share, whatever they deposited, and they vote on the Council.
///
/// Trader losses go into a buffer that drips into the pool over `bufferPayoutPeriod`, so a lucky
/// deposit right before a big loss can't capture it. Trader profits are paid from the buffer first.
contract Pool is IPool {
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 private constant ACC_PRECISION = 1e18;

    address public gov;
    address public trade;
    IStore public store;

    // Membership and equal dividends
    mapping(address => uint256) public memberSince; // 0 = not a member
    uint256 public memberCount;
    uint256 public accDividendPerMember; // scaled by ACC_PRECISION
    mapping(address => uint256) private dividendDebt;

    modifier onlyTrade() {
        require(msg.sender == trade, "!trade");
        _;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "!governance");
        _;
    }

    constructor(address _gov) {
        gov = _gov;
    }

    function updateGov(address _gov) external onlyGov {
        require(_gov != address(0), "!address");
        emit GovernanceUpdated(gov, _gov);
        gov = _gov;
    }

    /// @notice One-time wiring.
    function link(address _trade, address _store) external onlyGov {
        require(trade == address(0), "!linked");
        require(_trade != address(0) && _store != address(0), "!address");
        trade = _trade;
        store = IStore(_store);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    function addLiquidity(uint256 amount) external {
        require(amount > 0, "!amount");
        address user = msg.sender;
        uint256 balance = store.poolBalance();
        uint256 clpSupply = store.getCLPSupply();
        uint256 clpAmount = balance == 0 || clpSupply == 0 ? amount : amount * clpSupply / balance;
        require(clpAmount > 0, "!clp-amount");

        store.transferIn(user, amount);
        store.incrementPoolBalance(amount);
        store.mintCLP(user, clpAmount);
        _syncMembership(user);

        emit AddLiquidity(user, amount, clpAmount, store.poolBalance());
    }

    /// @param amount Currency to withdraw (capped at the user's share). A small fee stays in the pool.
    function removeLiquidity(uint256 amount) external {
        require(amount > 0, "!amount");
        address user = msg.sender;
        uint256 balance = store.poolBalance();
        uint256 clpSupply = store.getCLPSupply();
        require(balance > 0 && clpSupply > 0, "!empty");

        uint256 userBalance = store.getUserPoolBalance(user);
        if (amount > userBalance) amount = userBalance;

        IStore.Params memory p = store.getParams();
        uint256 feeAmount = amount * p.poolWithdrawalFeeBps / BPS_DIVIDER;
        uint256 amountMinusFee = amount - feeAmount;
        // Burn shares for the full amount; the fee's share of value is left to the remaining depositors
        uint256 clpAmount = amount == userBalance ? IERC20(store.clp()).balanceOf(user) : amount * clpSupply / balance;
        require(clpAmount > 0 && amountMinusFee > 0, "!amount");

        // Liquidity can't be pulled out from under open positions
        require(store.totalOI() * BPS_DIVIDER <= (balance - amountMinusFee) * p.maxUtilizationBps, "!utilization");

        _claimDividend(user);
        store.decrementPoolBalance(amountMinusFee);
        store.burnCLP(user, clpAmount);
        _syncMembership(user);
        store.transferOut(user, amountMinusFee);

        emit RemoveLiquidity(user, amount, feeAmount, clpAmount, store.poolBalance());
    }

    // ---------------------------------------------------------------------
    // Member dividends
    // ---------------------------------------------------------------------

    function pendingDividend(address account) public view returns (uint256) {
        if (memberSince[account] == 0) return 0;
        return (accDividendPerMember - dividendDebt[account]) / ACC_PRECISION;
    }

    function claimDividend() external returns (uint256) {
        return _claimDividend(msg.sender);
    }

    function isMember(address account) external view returns (bool) {
        return memberSince[account] != 0;
    }

    // ---------------------------------------------------------------------
    // Trade hooks
    // ---------------------------------------------------------------------

    /// @notice Moves a realized trader loss from the trader's balance into the buffer, and drips
    /// the buffer into the pool for the time elapsed since the last payment.
    function creditTraderLoss(address user, string memory market, uint256 amount) external onlyTrade {
        if (amount > 0) {
            store.decrementBalance(user, amount);
            store.incrementBufferBalance(amount);
        }

        uint256 lastPaid = store.poolLastPaid();
        uint256 amountToSendPool;
        if (lastPaid != 0) {
            uint256 bufferBalance = store.bufferBalance();
            amountToSendPool = bufferBalance * (block.timestamp - lastPaid) / store.getParams().bufferPayoutPeriod;
            if (amountToSendPool > bufferBalance) amountToSendPool = bufferBalance;
            if (amountToSendPool > 0) {
                store.decrementBufferBalance(amountToSendPool);
                store.incrementPoolBalance(amountToSendPool);
            }
        }
        store.setPoolLastPaid(block.timestamp);

        emit PoolPayIn(user, market, amount, amountToSendPool, store.poolBalance(), store.bufferBalance());
    }

    /// @notice Pays a trader's profit from the buffer, then the pool. Never reverts: if the
    /// Collective can't cover it all, the trader gets what's there.
    function debitTraderProfit(address user, string memory market, uint256 amount) external onlyTrade returns (uint256 paid) {
        if (amount == 0) return 0;
        uint256 bufferBalance = store.bufferBalance();
        uint256 poolBalance = store.poolBalance();

        uint256 fromBuffer = amount < bufferBalance ? amount : bufferBalance;
        uint256 fromPool = amount - fromBuffer;
        if (fromPool > poolBalance) fromPool = poolBalance;

        if (fromBuffer > 0) store.decrementBufferBalance(fromBuffer);
        if (fromPool > 0) store.decrementPoolBalance(fromPool);
        paid = fromBuffer + fromPool;
        store.incrementBalance(user, paid);

        emit PoolPayOut(user, market, paid, store.poolBalance(), store.bufferBalance());
    }

    /// @notice Splits a fee the trader has already paid: keeper share first, then the rest between
    /// the equal member dividend, the solidarity fund and the pool.
    function creditFee(address user, string memory market, uint256 fee, address keeper, bool isLiquidation)
        external
        onlyTrade
    {
        if (fee == 0) return;
        IStore.Params memory p = store.getParams();

        uint256 keeperFee = keeper == address(0) ? 0 : fee * p.keeperFeeShareBps / BPS_DIVIDER;
        uint256 rest = fee - keeperFee;
        uint256 toSolidarity = rest * p.solidarityShareBps / BPS_DIVIDER;
        uint256 toMembers = memberCount > 0 ? rest * p.dividendShareBps / BPS_DIVIDER : 0;
        uint256 toPool = rest - toSolidarity - toMembers;

        if (keeperFee > 0) store.incrementBalance(keeper, keeperFee);
        if (toSolidarity > 0) store.incrementSolidarityFund(toSolidarity);
        if (toMembers > 0) {
            accDividendPerMember += toMembers * ACC_PRECISION / memberCount;
            store.incrementDividendReserve(toMembers);
        }
        if (toPool > 0) store.incrementPoolBalance(toPool);

        emit FeePaid(user, market, fee, keeperFee, toPool, toMembers, toSolidarity, isLiquidation);
    }

    /// @notice On liquidation, small traders get part of their margin back while the fund lasts.
    /// Credited to their trading balance.
    function paySolidarityRefund(address user, uint256 margin) external onlyTrade returns (uint256 refund) {
        IStore.Params memory p = store.getParams();
        if (margin > p.solidarityMarginCap) return 0;
        refund = margin * p.solidarityRefundBps / BPS_DIVIDER;
        uint256 fund = store.solidarityFund();
        if (refund > fund) refund = fund;
        if (refund == 0) return 0;
        store.decrementSolidarityFund(refund);
        store.incrementBalance(user, refund);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _syncMembership(address account) internal {
        bool qualifies = store.getUserPoolBalance(account) >= store.getParams().minMemberDeposit;
        bool member = memberSince[account] != 0;
        if (qualifies && !member) {
            memberSince[account] = block.timestamp;
            dividendDebt[account] = accDividendPerMember;
            memberCount++;
            emit MemberJoined(account);
        } else if (!qualifies && member) {
            _claimDividend(account);
            memberSince[account] = 0;
            memberCount--;
            emit MemberLeft(account);
        }
    }

    function _claimDividend(address account) internal returns (uint256 amount) {
        amount = pendingDividend(account);
        dividendDebt[account] = accDividendPerMember;
        if (amount == 0) return 0;
        store.decrementDividendReserve(amount);
        store.transferOut(account, amount);
        emit DividendClaimed(account, amount);
    }
}
