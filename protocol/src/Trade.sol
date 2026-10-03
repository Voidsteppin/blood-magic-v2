// SPDX-License-Identifier: BUSL-1.1
// Derived from CAP v4 (github.com/capofficial/protocol), (c) cap.io. Non-production use only.
pragma solidity ^0.8.24;

import {IChainlink} from "./interfaces/IChainlink.sol";
import {IStore} from "./interfaces/IStore.sol";
import {ITrade} from "./interfaces/ITrade.sol";
import {Pool} from "./Pool.sol";

/// @title Trade
/// @notice Cross-margin perpetuals. Traders deposit into one balance, then submit orders. Every
/// order, market ones included, is filled later by a keeper (anyone) at the next oracle price, so
/// nobody can trade against a price they already know. Limit, stop, take-profit and stop-loss
/// orders fill when the oracle crosses their price.
///
/// On top of the CAP v4 engine: traders choose their leverage, fees are progressive on a wallet's
/// total position, positions are capped per wallet, profits are capped per close, and small
/// traders who get liquidated are partly refunded by the solidarity fund.
contract Trade is ITrade {
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant BPS_DIVIDER = 10000;

    address public gov;
    IChainlink public chainlink;
    Pool public pool;
    IStore public store;

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
    function link(address _chainlink, address _pool, address _store) external onlyGov {
        require(address(store) == address(0), "!linked");
        require(_chainlink != address(0) && _pool != address(0) && _store != address(0), "!address");
        chainlink = IChainlink(_chainlink);
        pool = Pool(_pool);
        store = IStore(_store);
    }

    // ---------------------------------------------------------------------
    // Deposit / withdraw
    // ---------------------------------------------------------------------

    function deposit(uint256 amount) external {
        require(amount > 0, "!amount");
        store.transferIn(msg.sender, amount);
        store.incrementBalance(msg.sender, amount);
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "!amount");
        address user = msg.sender;
        store.decrementBalance(user, amount);
        require(int256(store.getLockedMargin(user)) <= getEquity(user), "!equity");
        store.transferOut(user, amount);
        emit Withdraw(user, amount);
    }

    // ---------------------------------------------------------------------
    // Orders
    // ---------------------------------------------------------------------

    /// @param params isLong, isReduceOnly, orderType (0 market, 1 limit, 2 stop), market, price
    /// (ignored for market orders), margin (ignored for reduce-only) and size. Leverage = size / margin.
    /// @param tpPrice Optional take-profit: a reduce-only limit order on the other side.
    /// @param slPrice Optional stop-loss: a reduce-only stop order on the other side.
    function submitOrder(IStore.Order memory params, uint256 tpPrice, uint256 slPrice) external returns (uint256 orderId) {
        address user = msg.sender;
        IStore.Market memory market = store.getMarket(params.market);
        require(market.maxLeverage > 0, "!market");
        require(params.orderType <= 2, "!order-type");
        require(params.size >= market.minSize, "!min-size");

        uint256 price = _getPrice(market.feed);
        require(price > 0, "!price");

        if (params.isReduceOnly) {
            params.margin = 0;
        } else {
            require(params.margin > 0 && params.size >= params.margin, "!margin");
            require(params.size <= params.margin * market.maxLeverage, "!leverage");
            IStore.Position memory position = store.getPosition(user, params.market);
            uint256 currentSize = position.isLong == params.isLong ? position.size : 0;
            uint256 fee = _tax(currentSize + params.size) - _tax(currentSize);
            int256 equity = getEquity(user);
            uint256 lockedMargin = store.getLockedMargin(user);
            require(int256(lockedMargin + params.margin + fee) <= equity, "!equity");
            store.lockMargin(user, params.margin);
        }

        if (params.orderType == 0) {
            params.price = price;
        } else {
            require(params.price > 0, "!price");
            require(!_isTriggered(params.orderType, params.isLong, params.price, price), "!trigger-price");
        }

        params.user = user;
        params.timestamp = uint64(block.timestamp);
        orderId = store.addOrder(params);
        _emitOrderCreated(orderId, params);

        if (tpPrice > 0) _addExitOrder(params, 1, tpPrice, price);
        if (slPrice > 0) _addExitOrder(params, 2, slPrice, price);
    }

    function updateOrder(uint256 orderId, uint256 price) external {
        IStore.Order memory order = store.getOrder(orderId);
        require(order.user == msg.sender, "!user");
        require(order.size > 0, "!order");
        require(order.orderType != 0, "!market-order");
        require(price > 0, "!price");

        uint256 oraclePrice = _getPrice(store.getMarket(order.market).feed);
        require(oraclePrice > 0, "!price");

        // A limit moved past the market becomes a stop, and the other way round
        if (_isTriggered(order.orderType, order.isLong, price, oraclePrice)) {
            order.orderType = order.orderType == 1 ? 2 : 1;
        }
        order.price = price;
        store.updateOrder(order);
        emit OrderUpdated(orderId, order.user, price, order.orderType);
    }

    function cancelOrders(uint256[] calldata orderIds) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            cancelOrder(orderIds[i]);
        }
    }

    function cancelOrder(uint256 orderId) public {
        IStore.Order memory order = store.getOrder(orderId);
        require(order.user == msg.sender, "!user");
        require(order.size > 0, "!order");
        // Market orders can't be pulled once the price they'll fill at may be known
        require(order.orderType != 0, "!market-order");
        if (!order.isReduceOnly) store.unlockMargin(order.user, order.margin);
        store.removeOrder(orderId);
        emit OrderCancelled(orderId, order.user);
    }

    // ---------------------------------------------------------------------
    // Keepers
    // ---------------------------------------------------------------------

    /// @notice Fills every executable order. Anyone can call; the caller earns the keeper share of fees.
    function executeOrders() external {
        uint256[] memory orderIds = getExecutableOrderIds();
        for (uint256 i = 0; i < orderIds.length; i++) {
            IStore.Order memory order = store.getOrder(orderIds[i]);
            if (order.size == 0) continue;
            uint256 price = _getPrice(store.getMarket(order.market).feed);
            if (price == 0) continue;
            _executeOrder(order, price, msg.sender);
        }
    }

    function getExecutableOrderIds() public view returns (uint256[] memory orderIdsToExecute) {
        IStore.Order[] memory orders = store.getOrders();
        uint256[] memory ids = new uint256[](orders.length);
        uint256 j;
        for (uint256 i = 0; i < orders.length; i++) {
            IStore.Order memory order = orders[i];
            IStore.Market memory market = store.getMarket(order.market);
            uint256 price = _getPrice(market.feed);
            if (price == 0) continue;

            if (order.orderType == 0) {
                // A market order fills on the next new price, or at the same price after the settlement delay
                if (price != order.price || block.timestamp - order.timestamp > market.minSettlementTime) ids[j++] = order.orderId;
            } else if (_isTriggered(order.orderType, order.isLong, order.price, price)) {
                ids[j++] = order.orderId;
            }
        }
        orderIdsToExecute = new uint256[](j);
        for (uint256 i = 0; i < j; i++) {
            orderIdsToExecute[i] = ids[i];
        }
    }

    /// @notice Liquidates every account whose equity has fallen below the minimum margin level.
    /// Anyone can call; the caller earns the keeper share of the liquidation fees.
    function liquidateUsers() external {
        address[] memory users = getLiquidatableUsers();
        for (uint256 i = 0; i < users.length; i++) {
            _liquidate(users[i], msg.sender);
        }
    }

    function getLiquidatableUsers() public view returns (address[] memory usersToLiquidate) {
        uint256 length = store.getUsersWithLockedMarginLength();
        uint256 minLevel = store.getParams().minimumMarginLevelBps;
        address[] memory users = new address[](length);
        uint256 j;
        for (uint256 i = 0; i < length; i++) {
            address user = store.getUserWithLockedMargin(i);
            if (store.getUserPositions(user).length == 0) continue;
            int256 equity = getEquity(user);
            uint256 lockedMargin = store.getLockedMargin(user);
            uint256 marginLevel = equity <= 0 ? 0 : BPS_DIVIDER * uint256(equity) / lockedMargin;
            if (marginLevel < minLevel) users[j++] = user;
        }
        usersToLiquidate = new address[](j);
        for (uint256 i = 0; i < j; i++) {
            usersToLiquidate[i] = users[i];
        }
    }

    // ---------------------------------------------------------------------
    // Escape hatch
    // ---------------------------------------------------------------------

    /// @notice Close a profitable position and get its margin back, giving up the profit. For
    /// when the Collective can't pay out (CAP's black-swan exit).
    function closePositionWithoutProfit(string memory marketName) external {
        address user = msg.sender;
        IStore.Position memory position = store.getPosition(user, marketName);
        require(position.size > 0, "!position");
        uint256 price = _getPrice(store.getMarket(marketName).feed);
        require(price > 0, "!price");

        _updateFundingTracker(marketName);
        (int256 pnl,) = _getPnL(marketName, position.isLong, price, position.price, position.size, position.fundingTracker);
        require(pnl >= 0, "pnl < 0");

        store.decrementOI(marketName, position.size, position.isLong);
        store.unlockMargin(user, position.margin);
        store.removePosition(user, marketName);

        uint256 fee = _min(_tax(position.size), store.getBalance(user));
        if (fee > 0) {
            store.decrementBalance(user, fee);
            pool.creditFee(user, marketName, fee, address(0), false);
        }

        emit PositionDecreased(
            0, user, marketName, !position.isLong, position.size, position.margin, price, 0, 0, position.price,
            position.fundingTracker, fee, 0, 0
        );
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Balance plus unrealized P/L (funding included) across all positions.
    function getEquity(address user) public view returns (int256) {
        return int256(store.getBalance(user)) + getUpl(user);
    }

    function getUpl(address user) public view returns (int256 upl) {
        IStore.Position[] memory positions = store.getUserPositions(user);
        for (uint256 i = 0; i < positions.length; i++) {
            IStore.Position memory position = positions[i];
            uint256 price = _getPrice(store.getMarket(position.market).feed);
            if (price == 0) continue;
            (int256 pnl,) =
                _getPnL(position.market, position.isLong, price, position.price, position.size, position.fundingTracker);
            upl += pnl;
        }
    }

    function getUserPositionsWithUpls(address user)
        external
        view
        returns (IStore.Position[] memory positions, int256[] memory upls)
    {
        positions = store.getUserPositions(user);
        upls = new int256[](positions.length);
        for (uint256 i = 0; i < positions.length; i++) {
            IStore.Position memory position = positions[i];
            uint256 price = _getPrice(store.getMarket(position.market).feed);
            if (price == 0) continue;
            (upls[i],) =
                _getPnL(position.market, position.isLong, price, position.price, position.size, position.fundingTracker);
        }
    }

    function getMarketsWithPrices() external view returns (IStore.Market[] memory markets, uint256[] memory prices) {
        string[] memory list = store.getMarketList();
        markets = new IStore.Market[](list.length);
        prices = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            markets[i] = store.getMarket(list[i]);
            prices[i] = _getPrice(markets[i].feed);
        }
    }

    /// @notice Progressive fee for growing `user`'s position in `market` by `size` on the same side.
    function getOpeningFee(address user, string calldata market, bool isLong, uint256 size) external view returns (uint256) {
        IStore.Position memory position = store.getPosition(user, market);
        uint256 current = position.size > 0 && position.isLong == isLong ? position.size : 0;
        return _tax(current + size) - _tax(current);
    }

    /// @notice Cumulative progressive fee on a total position size, bracket by bracket.
    function getTax(uint256 size) external view returns (uint256) {
        return _tax(size);
    }

    function getPrice(string calldata market) external view returns (uint256) {
        return _getPrice(store.getMarket(market).feed);
    }

    function getAccruedFunding(string memory market, uint256 intervals) public view returns (int256) {
        if (intervals == 0) {
            intervals = (block.timestamp - store.getFundingLastUpdated(market)) / store.FUNDING_INTERVAL();
        }
        if (intervals == 0) return 0;

        uint256 oiLong = store.getOILong(market);
        uint256 oiShort = store.getOIShort(market);
        if (oiLong == 0 && oiShort == 0) return 0;

        uint256 oiDiff = oiShort > oiLong ? oiShort - oiLong : oiLong - oiShort;
        uint256 yearlyFundingFactor = store.getMarket(market).fundingFactor; // bps
        // FUNDING_INTERVAL is one hour, so a year is 24 * 365 intervals
        uint256 accrued = UNIT * yearlyFundingFactor * oiDiff * intervals / (24 * 365 * (oiLong + oiShort));
        // Positive: longs pay shorts. Negative: shorts pay longs.
        return oiLong > oiShort ? int256(accrued) : -int256(accrued);
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    function _executeOrder(IStore.Order memory order, uint256 price, address keeper) internal {
        IStore.Position memory position = store.getPosition(order.user, order.market);
        bool sameSide = position.size == 0 || order.isLong == position.isLong;

        if (!order.isReduceOnly && sameSide) {
            _increasePosition(order, price, keeper);
        } else if (position.size > 0 && !sameSide) {
            _decreasePosition(order, price, keeper);
        } else {
            _reject(order, "!position");
        }
    }

    function _increasePosition(IStore.Order memory order, uint256 price, address keeper) internal {
        IStore.Position memory position = store.getPosition(order.user, order.market);
        IStore.Market memory market = store.getMarket(order.market);
        IStore.Params memory p = store.getParams();

        uint256 newSize = position.size + order.size;
        uint256 sideOI = order.isLong ? store.getOILong(order.market) : store.getOIShort(order.market);
        if (newSize > p.maxPositionSize) return _reject(order, "!whale-cap");
        if (sideOI + order.size > market.maxOI) return _reject(order, "!max-oi");
        if ((store.totalOI() + order.size) * BPS_DIVIDER > store.poolBalance() * p.maxUtilizationBps) {
            return _reject(order, "!utilization");
        }

        // The order's margin is already locked; the fee has to come out of what's left
        uint256 fee = _tax(newSize) - _tax(position.size);
        int256 equity = getEquity(order.user);
        if (fee > store.getBalance(order.user) || int256(store.getLockedMargin(order.user) + fee) > equity) {
            return _reject(order, "!fee");
        }

        _updateFundingTracker(order.market);
        int256 currentTracker = store.getFundingTracker(order.market);

        if (position.size == 0) {
            position.user = order.user;
            position.market = order.market;
            position.isLong = order.isLong;
            position.timestamp = uint64(block.timestamp);
            position.fundingTracker = currentTracker;
        } else {
            // Blend so funding already owed on the old size isn't charged to the new size, or forgiven
            position.fundingTracker =
                (position.fundingTracker * int256(position.size) + currentTracker * int256(order.size)) / int256(newSize);
        }
        position.price = (position.size * position.price + order.size * price) / newSize;
        position.size = newSize;
        position.margin += order.margin;

        store.incrementOI(order.market, order.size, order.isLong);
        store.addOrUpdatePosition(position);
        if (order.orderId > 0) store.removeOrder(order.orderId);

        store.decrementBalance(order.user, fee);
        pool.creditFee(order.user, order.market, fee, keeper, false);

        emit PositionIncreased(
            order.orderId, order.user, order.market, order.isLong, order.size, order.margin, price, position.margin,
            position.size, position.price, position.fundingTracker, fee
        );
    }

    function _decreasePosition(IStore.Order memory order, uint256 price, address keeper) internal {
        IStore.Position memory position = store.getPosition(order.user, order.market);
        IStore.Params memory p = store.getParams();

        uint256 executedSize = _min(order.size, position.size);
        uint256 remainingSize = order.size - executedSize;
        uint256 marginToUnlock;
        uint256 remainingOrderMargin;
        if (!order.isReduceOnly) {
            // The part of this order's margin that closes rather than opens is no longer needed
            uint256 executedOrderMargin = order.margin * executedSize / order.size;
            marginToUnlock = executedOrderMargin;
            remainingOrderMargin = order.margin - executedOrderMargin;
        }

        _updateFundingTracker(order.market);

        (int256 pnl, int256 fundingFee) =
            _getPnL(order.market, position.isLong, price, position.price, executedSize, position.fundingTracker);
        uint256 executedMargin = position.margin * executedSize / position.size;

        if (pnl <= -int256(position.margin)) {
            // Losing more than the whole position's margin closes all of it
            pnl = -int256(position.margin);
            executedMargin = position.margin;
            executedSize = position.size;
        }
        int256 maxProfit = int256(executedSize * p.maxProfitBps / BPS_DIVIDER);
        if (pnl > maxProfit) pnl = maxProfit;

        uint256 fee = _tax(position.size) - _tax(position.size - executedSize);

        bool closed = executedSize == position.size;
        store.decrementOI(order.market, executedSize, position.isLong);
        if (closed) {
            store.removePosition(order.user, order.market);
        } else {
            // The remaining size keeps its entry price and funding tracker
            position.size -= executedSize;
            position.margin -= executedMargin;
            store.addOrUpdatePosition(position);
        }
        if (order.orderId > 0) store.removeOrder(order.orderId);

        // Settle P/L against the Collective, then the fee, never taking more than the trader holds
        if (pnl < 0) {
            pool.creditTraderLoss(order.user, order.market, _min(uint256(-pnl), store.getBalance(order.user)));
        } else if (pnl > 0) {
            pool.debitTraderProfit(order.user, order.market, uint256(pnl));
        }
        store.unlockMargin(order.user, marginToUnlock + executedMargin);
        fee = _min(fee, store.getBalance(order.user));
        if (fee > 0) {
            store.decrementBalance(order.user, fee);
            pool.creditFee(order.user, order.market, fee, keeper, false);
        }

        emit PositionDecreased(
            order.orderId, order.user, order.market, order.isLong, executedSize, executedMargin, price, position.margin,
            closed ? 0 : position.size, position.price, position.fundingTracker, fee, pnl, fundingFee
        );

        // Whatever is left of a non-reduce-only order opens a position the other way
        if (!order.isReduceOnly && remainingSize > 0) {
            IStore.Order memory next = order;
            next.orderId = 0;
            next.size = remainingSize;
            next.margin = remainingOrderMargin;
            _increasePosition(next, price, keeper);
        }
    }

    function _liquidate(address user, address keeper) internal {
        IStore.Position[] memory positions = store.getUserPositions(user);
        for (uint256 i = 0; i < positions.length; i++) {
            IStore.Position memory position = positions[i];
            uint256 price = _getPrice(store.getMarket(position.market).feed);
            _updateFundingTracker(position.market);

            // The whole margin is forfeit: the closing fee first, the rest is the trader's loss
            uint256 forfeit = _min(position.margin, store.getBalance(user));
            uint256 fee = _min(_tax(position.size), forfeit);
            if (fee > 0) {
                store.decrementBalance(user, fee);
                pool.creditFee(user, position.market, fee, keeper, true);
            }
            pool.creditTraderLoss(user, position.market, forfeit - fee);

            store.decrementOI(position.market, position.size, position.isLong);
            store.removePosition(user, position.market);
            store.unlockMargin(user, position.margin);

            uint256 refund = pool.paySolidarityRefund(user, position.margin);
            emit PositionLiquidated(user, position.market, position.isLong, position.size, position.margin, price, fee, refund);
        }

        // Pending orders go too, so their locked margin doesn't keep the account flagged
        IStore.Order[] memory orders = store.getUserOrders(user);
        for (uint256 i = 0; i < orders.length; i++) {
            if (!orders[i].isReduceOnly) store.unlockMargin(user, orders[i].margin);
            store.removeOrder(orders[i].orderId);
            emit OrderCancelled(orders[i].orderId, user);
        }
    }

    function _reject(IStore.Order memory order, string memory reason) internal {
        if (!order.isReduceOnly) store.unlockMargin(order.user, order.margin);
        if (order.orderId > 0) store.removeOrder(order.orderId);
        emit OrderRejected(order.orderId, order.user, reason);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _addExitOrder(IStore.Order memory parent, uint8 orderType, uint256 triggerPrice, uint256 oraclePrice) internal {
        IStore.Order memory exit = IStore.Order({
            isLong: !parent.isLong,
            isReduceOnly: true,
            orderType: orderType,
            orderId: 0,
            user: parent.user,
            market: parent.market,
            timestamp: uint64(block.timestamp),
            price: triggerPrice,
            margin: 0,
            size: parent.size
        });
        require(!_isTriggered(orderType, exit.isLong, triggerPrice, oraclePrice), orderType == 1 ? "!tp-price" : "!sl-price");
        uint256 id = store.addOrder(exit);
        _emitOrderCreated(id, exit);
    }

    /// @dev Limit buys and stop sells fill at or below their price; limit sells and stop buys at or above.
    function _isTriggered(uint8 orderType, bool isLong, uint256 orderPrice, uint256 price) internal pure returns (bool) {
        if (orderType == 1) return isLong ? price <= orderPrice : price >= orderPrice;
        if (orderType == 2) return isLong ? price >= orderPrice : price <= orderPrice;
        return true;
    }

    function _getPrice(address feed) internal view returns (uint256) {
        return chainlink.getPrice(feed, store.getParams().maxPriceAge);
    }

    function _getPnL(
        string memory market,
        bool isLong,
        uint256 price,
        uint256 positionPrice,
        uint256 size,
        int256 fundingTracker
    ) internal view returns (int256 pnl, int256 fundingFee) {
        if (price == 0 || positionPrice == 0 || size == 0) return (0, 0);
        pnl = isLong
            ? int256(size) * (int256(price) - int256(positionPrice)) / int256(positionPrice)
            : int256(size) * (int256(positionPrice) - int256(price)) / int256(positionPrice);

        // Tracker is in UNIT * bps. Positive funding: longs pay, shorts receive.
        int256 tracker = store.getFundingTracker(market) + getAccruedFunding(market, 0);
        fundingFee = int256(size) * (tracker - fundingTracker) / (int256(BPS_DIVIDER) * int256(UNIT));
        pnl = isLong ? pnl - fundingFee : pnl + fundingFee;
    }

    function _updateFundingTracker(string memory market) internal {
        uint256 lastUpdated = store.getFundingLastUpdated(market);
        if (lastUpdated == 0) {
            store.setFundingLastUpdated(market, block.timestamp);
            return;
        }
        uint256 intervals = (block.timestamp - lastUpdated) / store.FUNDING_INTERVAL();
        if (intervals == 0) return;

        int256 increment = getAccruedFunding(market, intervals);
        // Advance by whole intervals only, so partial hours aren't lost
        store.setFundingLastUpdated(market, lastUpdated + intervals * store.FUNDING_INTERVAL());
        if (increment == 0) return;
        store.updateFundingTracker(market, increment);
        emit FundingUpdated(market, store.getFundingTracker(market), increment);
    }

    function _tax(uint256 size) internal view returns (uint256 total) {
        IStore.Params memory p = store.getParams();
        uint256 lower;
        for (uint256 i = 0; i < 4 && size > lower; i++) {
            uint256 upper = i < 3 ? p.feeBrackets[i] : type(uint256).max;
            uint256 slice = (size < upper ? size : upper) - lower;
            total += slice * p.feeRatesBps[i] / BPS_DIVIDER;
            lower = upper;
        }
    }

    function _emitOrderCreated(uint256 orderId, IStore.Order memory o) internal {
        emit OrderCreated(orderId, o.user, o.market, o.isLong, o.margin, o.size, o.price, o.orderType, o.isReduceOnly);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
