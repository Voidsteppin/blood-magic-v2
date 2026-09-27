// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title PerpExchange
/// @notice Minimal perpetual futures exchange. Traders post USDC margin and open leveraged
/// long/short positions priced by Chainlink. A shared liquidity pool (LPs hold the PLP token)
/// is the counterparty to every trade: it collects trading fees and trader losses, and pays
/// trader profits.
///
/// Accounting model: a position stores its notional `size` (USDC) and `units` (size / entry
/// price, i.e. the amount of the asset it represents). PnL is linear:
///   long  pnl = units * price - size
///   short pnl = size - units * price
/// Because this is linear, the exchange tracks per-market sums of size and units per side,
/// which gives the exact aggregate unrealized PnL of all traders. LP shares are priced
/// against pool balance minus that PnL, so LPs can't exit ahead of losses already incurred.
contract PerpExchange is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant BPS = 10_000;
    /// @dev Virtual shares/assets offset that neutralizes first-depositor share inflation.
    uint256 private constant VIRTUAL_SHARES = 1e12;
    uint256 private constant VIRTUAL_ASSETS = 1;

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

    /// @notice USDC owned by liquidity providers (excludes trader margin).
    uint256 public poolBalance;

    uint256 public feeBps = 10; // 0.1% of size on open and on close
    uint256 public maintenanceMarginBps = 100; // liquidatable when equity < 1% of size
    uint256 public liquidatorRewardBps = 500; // liquidator receives 5% of the margin
    uint256 public maxUtilizationBps = 5_000; // total open interest <= 50% of pool value
    uint256 public maxProfitBps = 10_000; // profit per position capped at 100% of size
    uint256 public minMargin = 10e6; // 10 USDC
    uint256 public maxPriceAge = 1 days;

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
    event Liquidated(address indexed trader, bytes32 indexed marketId, address indexed liquidator, uint256 price, uint256 reward);
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount, uint256 shares);
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
    error NotLiquidatable();
    error WouldBeLiquidatable();
    error InsufficientLiquidity();
    error ZeroAmount();

    constructor(IERC20 _usdc) ERC20("Perp Liquidity Pool", "PLP") Ownable(msg.sender) {
        usdc = _usdc;
    }

    // ---------------------------------------------------------------------
    // Admin
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

    function setParams(
        uint256 _feeBps,
        uint256 _maintenanceMarginBps,
        uint256 _liquidatorRewardBps,
        uint256 _maxUtilizationBps,
        uint256 _maxProfitBps,
        uint256 _minMargin,
        uint256 _maxPriceAge
    ) external onlyOwner {
        require(_feeBps <= 100 && _maintenanceMarginBps <= 1_000 && _liquidatorRewardBps <= 5_000, "bounds");
        require(_maxUtilizationBps <= BPS && _maxProfitBps > 0 && _maxPriceAge > 0, "bounds");
        feeBps = _feeBps;
        maintenanceMarginBps = _maintenanceMarginBps;
        liquidatorRewardBps = _liquidatorRewardBps;
        maxUtilizationBps = _maxUtilizationBps;
        maxProfitBps = _maxProfitBps;
        minMargin = _minMargin;
        maxPriceAge = _maxPriceAge;
        emit ParamsUpdated();
    }

    // ---------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------

    /// @notice Open a position, or add to an existing one in the same direction.
    /// @param margin USDC collateral to post. The opening fee is charged on top of this.
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
        uint256 fee = (sizeDelta * feeBps) / BPS;

        p.size += sizeDelta;
        p.margin += margin;
        p.units += unitsDelta;
        p.isLong = isLong;

        if (p.margin < minMargin) revert MarginTooSmall();
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
        poolBalance += fee;

        if (totalOpenInterest() * BPS > poolValue() * maxUtilizationBps) revert UtilizationExceeded();

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

        // Portion of the position being closed.
        uint256 unitsDelta = sizeDelta == p.size ? p.units : (p.units * sizeDelta) / p.size;
        uint256 marginDelta = sizeDelta == p.size ? p.margin : (p.margin * sizeDelta) / p.size;

        int256 pnl = _pnl(isLong, sizeDelta, unitsDelta, price);
        int256 maxProfit = int256((sizeDelta * maxProfitBps) / BPS);
        if (pnl > maxProfit) pnl = maxProfit;
        uint256 fee = (sizeDelta * feeBps) / BPS;

        p.size -= sizeDelta;
        p.units -= unitsDelta;
        p.margin -= marginDelta;
        _removeOpenInterest(m, isLong, sizeDelta, unitsDelta);

        if (p.size > 0) {
            if (p.margin < minMargin) revert MarginTooSmall();
            if (_isLiquidatable(p, price)) revert WouldBeLiquidatable();
        } else {
            delete positions[msg.sender][marketId];
        }

        // Trader receives margin + pnl - fee, floored at zero. The pool absorbs the difference.
        int256 owed = int256(marginDelta) + pnl - int256(fee);
        uint256 payout = _settleWithPool(marginDelta, owed > 0 ? uint256(owed) : 0);

        if (payout > 0) usdc.safeTransfer(msg.sender, payout);

        emit PositionDecreased(msg.sender, marketId, isLong, sizeDelta, pnl, price, fee, payout);
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
    function liquidate(address trader, bytes32 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        Position memory p = positions[trader][marketId];
        if (p.size == 0) revert NoPosition();

        uint256 price = getPrice(marketId);
        if (!_isLiquidatable(p, price)) revert NotLiquidatable();

        delete positions[trader][marketId];
        _removeOpenInterest(m, p.isLong, p.size, p.units);

        uint256 reward = (p.margin * liquidatorRewardBps) / BPS;
        poolBalance += p.margin - reward;
        usdc.safeTransfer(msg.sender, reward);

        emit Liquidated(trader, marketId, msg.sender, price, reward);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    function addLiquidity(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        shares = (amount * (totalSupply() + VIRTUAL_SHARES)) / (poolValue() + VIRTUAL_ASSETS);
        if (shares == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        poolBalance += amount;
        _mint(msg.sender, shares);
        emit LiquidityAdded(msg.sender, amount, shares);
    }

    function removeLiquidity(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        amount = (shares * (poolValue() + VIRTUAL_ASSETS)) / (totalSupply() + VIRTUAL_SHARES);
        if (amount > poolBalance) revert InsufficientLiquidity();
        _burn(msg.sender, shares);
        poolBalance -= amount;
        if (totalOpenInterest() * BPS > poolValue() * maxUtilizationBps) revert UtilizationExceeded();
        usdc.safeTransfer(msg.sender, amount);
        emit LiquidityRemoved(msg.sender, amount, shares);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Oracle price scaled to 18 decimals. Reverts on a non-positive or stale answer.
    function getPrice(bytes32 marketId) public view returns (uint256) {
        Market storage m = _market(marketId);
        (, int256 answer,, uint256 updatedAt,) = m.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice();
        return uint256(answer) * 10 ** (18 - m.feedDecimals);
    }

    /// @notice Pool balance minus all traders' unrealized PnL (floored at zero).
    function poolValue() public view returns (uint256) {
        int256 value = int256(poolBalance) - totalTraderPnl();
        return value > 0 ? uint256(value) : 0;
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

    function _pnl(bool isLong, uint256 size, uint256 units, uint256 price) internal pure returns (int256) {
        int256 value = int256((units * price) / PRICE_PRECISION);
        return isLong ? value - int256(size) : int256(size) - value;
    }

    function _isLiquidatable(Position memory p, uint256 price) internal view returns (bool) {
        int256 equity = int256(p.margin) + _pnl(p.isLong, p.size, p.units, price);
        return equity < int256((p.size * maintenanceMarginBps) / BPS);
    }

    /// @dev Price at which equity equals the maintenance margin. Zero if the long can't be liquidated.
    function _liquidationPrice(Position memory p) internal view returns (uint256) {
        uint256 maintenance = (p.size * maintenanceMarginBps) / BPS;
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

    /// @dev Moves released margin into the pool and pays the trader out of it.
    /// If the pool can't cover a winning trade in full, the payout is capped at what it holds.
    function _settleWithPool(uint256 marginReleased, uint256 payout) internal returns (uint256) {
        uint256 available = poolBalance + marginReleased;
        if (payout > available) payout = available;
        poolBalance = available - payout;
        return payout;
    }
}
