// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title PerpExchange ("People's Perps")
/// @notice A perpetual futures exchange run as a cooperative. Traders post USDC margin and open
/// leveraged long/short positions priced by Chainlink. The Collective (LPs, holding
/// non-transferable PLP membership shares) is the counterparty to every trade.
///
/// What makes it different from a normal perps DEX:
/// - Progressive fees: marginal fee rates rise with a wallet's total position size, like tax brackets.
/// - Whale cap: a maximum position size per wallet per market.
/// - Fee split: part of every fee goes to the pool (pro rata to capital), part is split EQUALLY
///   among members regardless of deposit size, and part funds a solidarity fund.
/// - Solidarity fund: small traders who get liquidated receive part of their margin back.
/// - Non-transferable shares: membership can be earned by depositing, never bought or sold.
/// - Ownership is meant to be handed to the Council contract, so every parameter change is voted on.
///
/// Accounting model: a position stores its notional `size` (USDC) and `units` (size / entry
/// price). PnL is linear (long: units*price - size, short: size - units*price), so per-market
/// sums of size and units give the exact aggregate unrealized PnL of all traders. Pool shares
/// are priced against pool balance minus that PnL, so members can't exit ahead of losses.
contract PerpExchange is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 private constant ACC_PRECISION = 1e18;
    /// @dev Virtual shares/assets offset that neutralizes first-depositor share inflation.
    uint256 private constant VIRTUAL_SHARES = 1e12;
    uint256 private constant VIRTUAL_ASSETS = 1;

    struct Params {
        uint16[4] feeRatesBps; // marginal fee rate for each bracket
        uint256[3] feeBrackets; // bracket upper bounds, USDC (6 decimals), strictly increasing
        uint16 maintenanceMarginBps; // liquidatable when equity < this share of size
        uint16 liquidatorRewardBps; // share of margin paid to the liquidator
        uint16 maxUtilizationBps; // total open interest <= this share of pool value
        uint16 maxProfitBps; // profit per position capped at this share of size
        uint256 minMargin; // USDC
        uint256 maxPriceAge; // seconds
        uint256 maxPositionSize; // whale cap per wallet per market, USDC
        uint16 dividendShareBps; // share of fees split equally among members
        uint16 solidarityShareBps; // share of fees sent to the solidarity fund
        uint16 solidarityRefundBps; // share of margin refunded to small liquidated traders
        uint256 solidarityMarginCap; // positions with margin <= this qualify for a refund, USDC
        uint256 minMemberDeposit; // pool value a wallet must hold to be a member, USDC
    }

    struct Market {
        AggregatorV3Interface feed;
        uint8 feedDecimals;
        bool enabled;
        uint32 maxLeverage; // e.g. 50 = 50x
        uint256 longSize;
        uint256 longUnits;
        uint256 shortSize;
        uint256 shortUnits;
    }

    struct Position {
        uint256 size; // notional in USDC (6 decimals)
        uint256 margin; // collateral in USDC (6 decimals)
        uint256 units; // size * PRICE_PRECISION / entryPrice
        bool isLong;
    }

    IERC20 public immutable usdc;
    Params internal _params;

    /// @notice USDC owned by the Collective's capital pool (excludes margin, dividends and the fund).
    uint256 public poolBalance;
    /// @notice USDC set aside to refund small traders who get liquidated.
    uint256 public solidarityFund;
    /// @notice USDC owed to members as equal-share dividends but not yet claimed.
    uint256 public dividendReserve;

    uint256 public memberCount;
    uint256 public accDividendPerMember; // scaled by ACC_PRECISION
    mapping(address => uint256) public memberSince; // 0 = not a member
    mapping(address => uint256) internal _dividendDebt;

    bytes32[] public marketIds;
    mapping(bytes32 => Market) public markets;
    mapping(address => mapping(bytes32 => Position)) public positions;

    event MarketSet(bytes32 indexed marketId, address feed, uint32 maxLeverage, bool enabled);
    event PositionIncreased(
        address indexed trader, bytes32 indexed marketId, bool isLong, uint256 sizeDelta, uint256 marginDelta, uint256 price, uint256 fee
    );
    event PositionDecreased(
        address indexed trader, bytes32 indexed marketId, bool isLong, uint256 sizeDelta, int256 pnl, uint256 price, uint256 fee, uint256 payout
    );
    event MarginAdded(address indexed trader, bytes32 indexed marketId, uint256 amount);
    event Liquidated(
        address indexed trader, bytes32 indexed marketId, address indexed liquidator, uint256 price, uint256 reward, uint256 solidarityRefund
    );
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount, uint256 shares);
    event FeeDistributed(uint256 toPool, uint256 toMembers, uint256 toSolidarity);
    event MemberJoined(address indexed member);
    event MemberLeft(address indexed member);
    event DividendClaimed(address indexed member, uint256 amount);
    event ParamsUpdated();

    error MarketDisabled();
    error UnknownMarket();
    error InvalidPrice();
    error StalePrice();
    error MarginTooSmall();
    error InvalidLeverage();
    error DirectionMismatch();
    error NoPosition();
    error InvalidSize();
    error UtilizationExceeded();
    error WhaleCapExceeded();
    error NotLiquidatable();
    error WouldBeLiquidatable();
    error InsufficientLiquidity();
    error ZeroAmount();
    error NotMember();
    error NonTransferable();
    error InvalidParams();

    constructor(IERC20 _usdc) ERC20("People's Perps Collective", "PLP") Ownable(msg.sender) {
        usdc = _usdc;
        _setParams(
            Params({
                feeRatesBps: [uint16(5), 10, 25, 50],
                feeBrackets: [uint256(1_000e6), 10_000e6, 50_000e6],
                maintenanceMarginBps: 100,
                liquidatorRewardBps: 500,
                maxUtilizationBps: 5_000,
                maxProfitBps: 10_000,
                minMargin: 10e6,
                maxPriceAge: 1 days,
                maxPositionSize: 25_000e6,
                dividendShareBps: 3_000,
                solidarityShareBps: 2_000,
                solidarityRefundBps: 2_500,
                solidarityMarginCap: 500e6,
                minMemberDeposit: 100e6
            })
        );
    }

    // ---------------------------------------------------------------------
    // Governance (owner = the Council)
    // ---------------------------------------------------------------------

    function setMarket(bytes32 marketId, AggregatorV3Interface feed, uint32 maxLeverage, bool enabled) external onlyOwner {
        require(maxLeverage >= 1 && maxLeverage <= 100, "leverage");
        Market storage m = markets[marketId];
        if (address(m.feed) == address(0)) marketIds.push(marketId);
        m.feed = feed;
        m.feedDecimals = feed.decimals();
        m.maxLeverage = maxLeverage;
        m.enabled = enabled;
        emit MarketSet(marketId, address(feed), maxLeverage, enabled);
    }

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function getParams() external view returns (Params memory) {
        return _params;
    }

    function _setParams(Params memory p) internal {
        for (uint256 i = 0; i < 4; i++) {
            if (p.feeRatesBps[i] > 200) revert InvalidParams(); // no bracket above 2%
        }
        if (p.feeBrackets[0] == 0 || p.feeBrackets[0] >= p.feeBrackets[1] || p.feeBrackets[1] >= p.feeBrackets[2]) {
            revert InvalidParams();
        }
        if (
            p.maintenanceMarginBps > 1_000 || p.liquidatorRewardBps > 5_000 || p.maxUtilizationBps > BPS || p.maxProfitBps == 0
                || p.maxPriceAge == 0 || p.maxPositionSize == 0 || p.minMemberDeposit == 0
                || uint256(p.dividendShareBps) + p.solidarityShareBps > BPS || p.solidarityRefundBps > BPS
        ) revert InvalidParams();
        _params = p;
        emit ParamsUpdated();
    }

    // ---------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------

    /// @notice Open a position, or add to an existing one in the same direction.
    /// @param margin USDC collateral to post. The (progressive) opening fee is charged on top.
    /// @param leverage Multiplier applied to `margin` to get the added notional size.
    function increasePosition(bytes32 marketId, bool isLong, uint256 margin, uint256 leverage) external nonReentrant {
        Market storage m = _market(marketId);
        if (!m.enabled) revert MarketDisabled();
        if (margin == 0) revert ZeroAmount();
        if (leverage < 1 || leverage > m.maxLeverage) revert InvalidLeverage();

        Position storage p = positions[msg.sender][marketId];
        if (p.size > 0 && p.isLong != isLong) revert DirectionMismatch();

        uint256 price = getPrice(marketId);
        uint256 sizeDelta = margin * leverage;
        uint256 unitsDelta = (sizeDelta * PRICE_PRECISION) / price;
        uint256 fee = _tax(p.size + sizeDelta) - _tax(p.size);

        p.size += sizeDelta;
        p.margin += margin;
        p.units += unitsDelta;
        p.isLong = isLong;

        if (p.size > _params.maxPositionSize) revert WhaleCapExceeded();
        if (p.margin < _params.minMargin) revert MarginTooSmall();
        if (p.size > p.margin * m.maxLeverage) revert InvalidLeverage();
        if (_isLiquidatable(p, price)) revert WouldBeLiquidatable();

        if (isLong) {
            m.longSize += sizeDelta;
            m.longUnits += unitsDelta;
        } else {
            m.shortSize += sizeDelta;
            m.shortUnits += unitsDelta;
        }

        usdc.safeTransferFrom(msg.sender, address(this), margin + fee);
        _distributeFee(fee);

        if (totalOpenInterest() * BPS > poolValue() * _params.maxUtilizationBps) revert UtilizationExceeded();

        emit PositionIncreased(msg.sender, marketId, isLong, sizeDelta, margin, price, fee);
    }

    /// @notice Close all or part of a position. Margin is released in proportion to size closed.
    function decreasePosition(bytes32 marketId, uint256 sizeDelta) external nonReentrant {
        Market storage m = _market(marketId);
        Position storage p = positions[msg.sender][marketId];
        if (p.size == 0) revert NoPosition();
        if (sizeDelta == 0 || sizeDelta > p.size) revert InvalidSize();

        uint256 price = getPrice(marketId);
        bool isLong = p.isLong;

        uint256 unitsDelta = sizeDelta == p.size ? p.units : (p.units * sizeDelta) / p.size;
        uint256 marginDelta = sizeDelta == p.size ? p.margin : (p.margin * sizeDelta) / p.size;

        int256 pnl = _pnl(isLong, sizeDelta, unitsDelta, price);
        int256 maxProfit = int256((sizeDelta * _params.maxProfitBps) / BPS);
        if (pnl > maxProfit) pnl = maxProfit;
        uint256 fee = _tax(p.size) - _tax(p.size - sizeDelta);

        p.size -= sizeDelta;
        p.units -= unitsDelta;
        p.margin -= marginDelta;
        _removeOpenInterest(m, isLong, sizeDelta, unitsDelta);

        if (p.size > 0) {
            if (p.margin < _params.minMargin) revert MarginTooSmall();
            if (_isLiquidatable(p, price)) revert WouldBeLiquidatable();
        } else {
            delete positions[msg.sender][marketId];
        }

        // Trader is owed margin + pnl - fee, floored at zero. The fee is only collected out of
        // what the trader has left; the pool absorbs the rest of any difference.
        int256 beforeFee = int256(marginDelta) + pnl;
        uint256 feeCollected = beforeFee <= 0 ? 0 : (uint256(beforeFee) < fee ? uint256(beforeFee) : fee);
        uint256 owed = beforeFee > 0 ? uint256(beforeFee) - feeCollected : 0;
        uint256 payout;
        (payout, feeCollected) = _settleWithPool(marginDelta, owed, feeCollected);

        if (payout > 0) usdc.safeTransfer(msg.sender, payout);

        emit PositionDecreased(msg.sender, marketId, isLong, sizeDelta, pnl, price, feeCollected, payout);
    }

    /// @notice Post extra collateral to an open position, lowering its leverage and liquidation risk.
    function addMargin(bytes32 marketId, uint256 amount) external nonReentrant {
        _market(marketId);
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender][marketId];
        if (p.size == 0) revert NoPosition();
        p.margin += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit MarginAdded(msg.sender, marketId, amount);
    }

    /// @notice Liquidate an underwater position. Anyone can call; the caller earns a reward.
    /// Small traders get part of their margin back from the solidarity fund.
    function liquidate(address trader, bytes32 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        Position memory p = positions[trader][marketId];
        if (p.size == 0) revert NoPosition();

        uint256 price = getPrice(marketId);
        if (!_isLiquidatable(p, price)) revert NotLiquidatable();

        delete positions[trader][marketId];
        _removeOpenInterest(m, p.isLong, p.size, p.units);

        uint256 reward = (p.margin * _params.liquidatorRewardBps) / BPS;
        poolBalance += p.margin - reward;

        uint256 refund;
        if (p.margin <= _params.solidarityMarginCap) {
            refund = _min((p.margin * _params.solidarityRefundBps) / BPS, solidarityFund);
            solidarityFund -= refund;
        }

        usdc.safeTransfer(msg.sender, reward);
        if (refund > 0) usdc.safeTransfer(trader, refund);

        emit Liquidated(trader, marketId, msg.sender, price, reward, refund);
    }

    // ---------------------------------------------------------------------
    // The Collective (liquidity + membership)
    // ---------------------------------------------------------------------

    function addLiquidity(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        shares = (amount * (totalSupply() + VIRTUAL_SHARES)) / (poolValue() + VIRTUAL_ASSETS);
        if (shares == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        poolBalance += amount;
        _mint(msg.sender, shares);
        _syncMembership(msg.sender);
        emit LiquidityAdded(msg.sender, amount, shares);
    }

    function removeLiquidity(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        amount = sharesToUsdc(shares);
        if (amount > poolBalance) revert InsufficientLiquidity();
        _burn(msg.sender, shares);
        poolBalance -= amount;
        if (totalOpenInterest() * BPS > poolValue() * _params.maxUtilizationBps) revert UtilizationExceeded();
        _syncMembership(msg.sender);
        usdc.safeTransfer(msg.sender, amount);
        emit LiquidityRemoved(msg.sender, amount, shares);
    }

    /// @notice Claim your equal share of fee dividends.
    function claimDividend() external nonReentrant returns (uint256 amount) {
        if (memberSince[msg.sender] == 0) revert NotMember();
        amount = _claimDividend(msg.sender);
    }

    function isMember(address account) external view returns (bool) {
        return memberSince[account] != 0;
    }

    function pendingDividend(address account) public view returns (uint256) {
        if (memberSince[account] == 0) return 0;
        return (accDividendPerMember - _dividendDebt[account]) / ACC_PRECISION;
    }

    /// @dev Membership shares can't be traded: only minted by deposits and burned by withdrawals.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Oracle price scaled to 18 decimals. Reverts on a non-positive or stale answer.
    function getPrice(bytes32 marketId) public view returns (uint256) {
        Market storage m = _market(marketId);
        (, int256 answer,, uint256 updatedAt,) = m.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > _params.maxPriceAge) revert StalePrice();
        return uint256(answer) * 10 ** (18 - m.feedDecimals);
    }

    /// @notice Pool balance minus all traders' unrealized PnL (floored at zero).
    function poolValue() public view returns (uint256) {
        int256 value = int256(poolBalance) - totalTraderPnl();
        return value > 0 ? uint256(value) : 0;
    }

    function sharesToUsdc(uint256 shares) public view returns (uint256) {
        return (shares * (poolValue() + VIRTUAL_ASSETS)) / (totalSupply() + VIRTUAL_SHARES);
    }

    /// @notice Aggregate unrealized PnL of every open position across all markets.
    function totalTraderPnl() public view returns (int256 total) {
        for (uint256 i = 0; i < marketIds.length; i++) {
            Market storage m = markets[marketIds[i]];
            if (m.longSize == 0 && m.shortSize == 0) continue;
            uint256 price = getPrice(marketIds[i]);
            total += _pnl(true, m.longSize, m.longUnits, price);
            total += _pnl(false, m.shortSize, m.shortUnits, price);
        }
    }

    function totalOpenInterest() public view returns (uint256 total) {
        for (uint256 i = 0; i < marketIds.length; i++) {
            Market storage m = markets[marketIds[i]];
            total += m.longSize + m.shortSize;
        }
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice The progressive fee `trader` would pay to add `sizeDelta` to their position.
    function openingFee(address trader, bytes32 marketId, uint256 sizeDelta) external view returns (uint256) {
        uint256 size = positions[trader][marketId].size;
        return _tax(size + sizeDelta) - _tax(size);
    }

    /// @notice Everything a UI needs about one position.
    function getPositionInfo(address trader, bytes32 marketId)
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            bool isLong,
            int256 pnl,
            uint256 liquidationPrice,
            bool liquidatable
        )
    {
        Position memory p = positions[trader][marketId];
        if (p.size == 0) return (0, 0, 0, false, 0, 0, false);
        uint256 price = getPrice(marketId);
        size = p.size;
        margin = p.margin;
        isLong = p.isLong;
        entryPrice = (p.size * PRICE_PRECISION) / p.units;
        pnl = _pnl(p.isLong, p.size, p.units, price);
        liquidationPrice = _liquidationPrice(p);
        liquidatable = _isLiquidatable(p, price);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _market(bytes32 marketId) internal view returns (Market storage m) {
        m = markets[marketId];
        if (address(m.feed) == address(0)) revert UnknownMarket();
    }

    /// @dev Cumulative progressive fee on a total position size, bracket by bracket.
    function _tax(uint256 size) internal view returns (uint256 total) {
        uint256 lower;
        for (uint256 i = 0; i < 4 && size > lower; i++) {
            uint256 upper = i < 3 ? _params.feeBrackets[i] : type(uint256).max;
            uint256 slice = (size < upper ? size : upper) - lower;
            total += (slice * _params.feeRatesBps[i]) / BPS;
            lower = upper;
        }
    }

    /// @dev Splits a fee between the capital pool, equal member dividends and the solidarity fund.
    function _distributeFee(uint256 fee) internal {
        if (fee == 0) return;
        uint256 toSolidarity = (fee * _params.solidarityShareBps) / BPS;
        uint256 toMembers = memberCount > 0 ? (fee * _params.dividendShareBps) / BPS : 0;
        uint256 toPool = fee - toSolidarity - toMembers;

        solidarityFund += toSolidarity;
        if (toMembers > 0) {
            accDividendPerMember += (toMembers * ACC_PRECISION) / memberCount;
            dividendReserve += toMembers;
        }
        poolBalance += toPool;
        emit FeeDistributed(toPool, toMembers, toSolidarity);
    }

    function _syncMembership(address account) internal {
        bool qualifies = sharesToUsdc(balanceOf(account)) >= _params.minMemberDeposit;
        bool member = memberSince[account] != 0;
        if (qualifies && !member) {
            memberSince[account] = block.timestamp;
            _dividendDebt[account] = accDividendPerMember;
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
        _dividendDebt[account] = accDividendPerMember;
        if (amount == 0) return 0;
        dividendReserve -= amount;
        usdc.safeTransfer(account, amount);
        emit DividendClaimed(account, amount);
    }

    function _pnl(bool isLong, uint256 size, uint256 units, uint256 price) internal pure returns (int256) {
        int256 value = int256((units * price) / PRICE_PRECISION);
        return isLong ? value - int256(size) : int256(size) - value;
    }

    function _isLiquidatable(Position memory p, uint256 price) internal view returns (bool) {
        int256 equity = int256(p.margin) + _pnl(p.isLong, p.size, p.units, price);
        return equity < int256((p.size * _params.maintenanceMarginBps) / BPS);
    }

    /// @dev Price at which equity equals the maintenance margin. Zero if the long can't be liquidated.
    function _liquidationPrice(Position memory p) internal view returns (uint256) {
        uint256 maintenance = (p.size * _params.maintenanceMarginBps) / BPS;
        if (p.isLong) {
            // margin + units*P - size = maintenance  =>  P = (size + maintenance - margin) / units
            if (p.size + maintenance <= p.margin) return 0;
            return ((p.size + maintenance - p.margin) * PRICE_PRECISION) / p.units;
        }
        // margin + size - units*P = maintenance  =>  P = (margin + size - maintenance) / units
        return ((p.margin + p.size - maintenance) * PRICE_PRECISION) / p.units;
    }

    function _removeOpenInterest(Market storage m, bool isLong, uint256 size, uint256 units) internal {
        if (isLong) {
            m.longSize -= size;
            m.longUnits -= units;
        } else {
            m.shortSize -= size;
            m.shortUnits -= units;
        }
    }

    /// @dev Settles a close: the released margin joins the pool, then the pool pays the trader
    /// and hands the fee out for distribution. Anything the pool can't cover in full is capped
    /// at what it holds.
    function _settleWithPool(uint256 marginReleased, uint256 payout, uint256 fee) internal returns (uint256, uint256) {
        uint256 available = poolBalance + marginReleased;
        fee = _min(fee, available);
        payout = _min(payout, available - fee);
        poolBalance = available - payout - fee;
        _distributeFee(fee);
        return (payout, fee);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
