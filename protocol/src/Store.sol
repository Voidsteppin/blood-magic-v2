// SPDX-License-Identifier: BUSL-1.1
// Derived from CAP v4 (github.com/capofficial/protocol), (c) cap.io. Non-production use only.
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IStore} from "./interfaces/IStore.sol";
import {CLP} from "./CLP.sol";

/// @title Store
/// @notice Holds every token and every piece of state. Trade and Pool hold the logic and are the
/// only contracts allowed to change state. Governance (the Council, once deployed) sets the rules,
/// but only within hard limits written here.
contract Store is IStore {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // Hard limits governance can never exceed
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant FUNDING_INTERVAL = 1 hours;
    uint256 public constant MAX_FEE_RATE = 500; // 5% top bracket
    uint256 public constant MAX_KEEPER_FEE_SHARE = 2000;
    uint256 public constant MAX_POOL_WITHDRAWAL_FEE = 500;
    uint256 public constant MAX_LEVERAGE = 100;
    uint256 public constant MAX_FUNDING_FACTOR = 50000; // 500% a year at full skew
    uint256 public constant MAX_SETTLEMENT_TIME = 1 hours;

    address public gov;
    address public trade;
    address public pool;
    address public currency;
    address public clp;

    Params private params;

    // Money. The Store's currency balance always equals the sum of trader balances plus these four.
    uint256 public poolBalance;
    uint256 public bufferBalance;
    uint256 public solidarityFund;
    uint256 public dividendReserve;
    uint256 public poolLastPaid;

    mapping(address => uint256) private balances;
    mapping(address => uint256) private lockedMargins;
    EnumerableSet.AddressSet private usersWithLockedMargin;

    // Orders
    uint256 private orderId;
    mapping(uint256 => Order) private orders;
    mapping(address => EnumerableSet.UintSet) private userOrderIds;
    EnumerableSet.UintSet private orderIds;

    // Markets
    string[] private marketList;
    mapping(string => Market) private markets;
    mapping(string => uint256) private OILong;
    mapping(string => uint256) private OIShort;
    uint256 public totalOI;

    // Positions, keyed by (user, market)
    mapping(bytes32 => Position) private positions;
    mapping(address => EnumerableSet.Bytes32Set) private positionKeysForUser;

    // Funding, per market: tracker in UNIT * bps (long side; shorts are the opposite)
    mapping(string => int256) private fundingTrackers;
    mapping(string => uint256) private fundingLastUpdated;

    modifier onlyContract() {
        require(msg.sender == trade || msg.sender == pool, "!contract");
        _;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "!governance");
        _;
    }

    constructor(address _gov, Params memory _params) {
        gov = _gov;
        _setParams(_params);
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    function updateGov(address _gov) external onlyGov {
        require(_gov != address(0), "!address");
        emit GovernanceUpdated(gov, _gov);
        gov = _gov;
    }

    /// @notice One-time wiring. Can't be repeated, so governance can never swap in other contracts.
    function link(address _trade, address _pool, address _currency, address _clp) external onlyGov {
        require(trade == address(0), "!linked");
        require(_trade != address(0) && _pool != address(0) && _currency != address(0) && _clp != address(0), "!address");
        trade = _trade;
        pool = _pool;
        currency = _currency;
        clp = _clp;
    }

    function setParams(Params calldata p) external onlyGov {
        _setParams(p);
    }

    function setMarket(string calldata market, Market calldata info) external onlyGov {
        require(info.feed != address(0), "!feed");
        require(info.maxLeverage <= MAX_LEVERAGE, "!max-leverage");
        require(info.fundingFactor <= MAX_FUNDING_FACTOR, "!max-funding");
        require(info.minSettlementTime <= MAX_SETTLEMENT_TIME, "!max-settlement");
        require(info.minSize > 0, "!min-size");
        if (markets[market].feed == address(0)) marketList.push(market);
        markets[market] = info;
        emit MarketSet(market, info);
    }

    function _setParams(Params memory p) internal {
        for (uint256 i = 0; i < 4; i++) {
            require(p.feeRatesBps[i] <= MAX_FEE_RATE, "!max-fee");
        }
        require(p.feeBrackets[0] < p.feeBrackets[1] && p.feeBrackets[1] < p.feeBrackets[2], "!brackets");
        require(p.maxPositionSize > 0, "!whale-cap");
        require(p.keeperFeeShareBps <= MAX_KEEPER_FEE_SHARE, "!keeper-share");
        require(uint256(p.dividendShareBps) + p.solidarityShareBps <= BPS_DIVIDER, "!fee-split");
        require(p.solidarityRefundBps <= BPS_DIVIDER, "!refund");
        require(p.minMemberDeposit > 0, "!member-deposit");
        require(p.minimumMarginLevelBps >= 500 && p.minimumMarginLevelBps < BPS_DIVIDER, "!margin-level");
        require(p.maxUtilizationBps > 0 && p.maxUtilizationBps <= BPS_DIVIDER, "!utilization");
        require(p.maxProfitBps >= 1000, "!max-profit");
        require(p.poolWithdrawalFeeBps <= MAX_POOL_WITHDRAWAL_FEE, "!withdrawal-fee");
        require(p.bufferPayoutPeriod >= 1 hours && p.bufferPayoutPeriod <= 90 days, "!buffer-period");
        require(p.maxPriceAge >= 1 minutes && p.maxPriceAge <= 2 days, "!price-age");
        params = p;
        emit ParamsUpdated(p);
    }

    function getParams() external view returns (Params memory) {
        return params;
    }

    function getMarket(string calldata market) external view returns (Market memory) {
        return markets[market];
    }

    function getMarketList() external view returns (string[] memory) {
        return marketList;
    }

    // ---------------------------------------------------------------------
    // Tokens
    // ---------------------------------------------------------------------

    function transferIn(address user, uint256 amount) external onlyContract {
        IERC20(currency).safeTransferFrom(user, address(this), amount);
    }

    function transferOut(address user, uint256 amount) external onlyContract {
        IERC20(currency).safeTransfer(user, amount);
    }

    function mintCLP(address user, uint256 amount) external onlyContract {
        CLP(clp).mint(user, amount);
    }

    function burnCLP(address user, uint256 amount) external onlyContract {
        CLP(clp).burn(user, amount);
    }

    function getCLPSupply() external view returns (uint256) {
        return IERC20(clp).totalSupply();
    }

    // ---------------------------------------------------------------------
    // Trader balances and margin
    // ---------------------------------------------------------------------

    function getBalance(address user) external view returns (uint256) {
        return balances[user];
    }

    function incrementBalance(address user, uint256 amount) external onlyContract {
        balances[user] += amount;
    }

    function decrementBalance(address user, uint256 amount) external onlyContract {
        require(amount <= balances[user], "!balance");
        balances[user] -= amount;
    }

    function getLockedMargin(address user) external view returns (uint256) {
        return lockedMargins[user];
    }

    function lockMargin(address user, uint256 amount) external onlyContract {
        lockedMargins[user] += amount;
        usersWithLockedMargin.add(user);
    }

    function unlockMargin(address user, uint256 amount) external onlyContract {
        lockedMargins[user] = amount > lockedMargins[user] ? 0 : lockedMargins[user] - amount;
        if (lockedMargins[user] == 0) usersWithLockedMargin.remove(user);
    }

    function getUsersWithLockedMarginLength() external view returns (uint256) {
        return usersWithLockedMargin.length();
    }

    function getUserWithLockedMargin(uint256 i) external view returns (address) {
        return usersWithLockedMargin.at(i);
    }

    // ---------------------------------------------------------------------
    // Pool, buffer, solidarity fund, member dividends
    // ---------------------------------------------------------------------

    function incrementPoolBalance(uint256 amount) external onlyContract {
        poolBalance += amount;
    }

    function decrementPoolBalance(uint256 amount) external onlyContract {
        poolBalance -= amount;
    }

    function incrementBufferBalance(uint256 amount) external onlyContract {
        bufferBalance += amount;
    }

    function decrementBufferBalance(uint256 amount) external onlyContract {
        bufferBalance -= amount;
    }

    function setPoolLastPaid(uint256 timestamp) external onlyContract {
        poolLastPaid = timestamp;
    }

    function incrementSolidarityFund(uint256 amount) external onlyContract {
        solidarityFund += amount;
    }

    function decrementSolidarityFund(uint256 amount) external onlyContract {
        solidarityFund -= amount;
    }

    function incrementDividendReserve(uint256 amount) external onlyContract {
        dividendReserve += amount;
    }

    function decrementDividendReserve(uint256 amount) external onlyContract {
        dividendReserve -= amount;
    }

    function getUserPoolBalance(address user) external view returns (uint256) {
        uint256 supply = IERC20(clp).totalSupply();
        if (supply == 0) return 0;
        return IERC20(clp).balanceOf(user) * poolBalance / supply;
    }

    // ---------------------------------------------------------------------
    // Open interest
    // ---------------------------------------------------------------------

    function getOILong(string calldata market) external view returns (uint256) {
        return OILong[market];
    }

    function getOIShort(string calldata market) external view returns (uint256) {
        return OIShort[market];
    }

    /// @dev Limits are checked by Trade before calling, so a bad order is rejected rather than reverting a batch.
    function incrementOI(string calldata market, uint256 size, bool isLong) external onlyContract {
        if (isLong) OILong[market] += size;
        else OIShort[market] += size;
        totalOI += size;
    }

    function decrementOI(string calldata market, uint256 size, bool isLong) external onlyContract {
        mapping(string => uint256) storage oi = isLong ? OILong : OIShort;
        uint256 removed = size > oi[market] ? oi[market] : size;
        oi[market] -= removed;
        totalOI -= removed;
    }

    // ---------------------------------------------------------------------
    // Orders
    // ---------------------------------------------------------------------

    function addOrder(Order memory order) external onlyContract returns (uint256) {
        uint256 id = ++orderId;
        order.orderId = uint72(id);
        orders[id] = order;
        userOrderIds[order.user].add(id);
        orderIds.add(id);
        return id;
    }

    function updateOrder(Order calldata order) external onlyContract {
        orders[order.orderId] = order;
    }

    function removeOrder(uint256 id) external onlyContract {
        Order storage order = orders[id];
        if (order.size == 0) return;
        userOrderIds[order.user].remove(id);
        orderIds.remove(id);
        delete orders[id];
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return orders[id];
    }

    function getOrders() external view returns (Order[] memory _orders) {
        uint256 length = orderIds.length();
        _orders = new Order[](length);
        for (uint256 i = 0; i < length; i++) {
            _orders[i] = orders[orderIds.at(i)];
        }
    }

    function getUserOrders(address user) external view returns (Order[] memory _orders) {
        uint256 length = userOrderIds[user].length();
        _orders = new Order[](length);
        for (uint256 i = 0; i < length; i++) {
            _orders[i] = orders[userOrderIds[user].at(i)];
        }
    }

    // ---------------------------------------------------------------------
    // Positions
    // ---------------------------------------------------------------------

    function addOrUpdatePosition(Position calldata position) external onlyContract {
        bytes32 key = _positionKey(position.user, position.market);
        positions[key] = position;
        positionKeysForUser[position.user].add(key);
    }

    function removePosition(address user, string calldata market) external onlyContract {
        bytes32 key = _positionKey(user, market);
        positionKeysForUser[user].remove(key);
        delete positions[key];
    }

    function getPosition(address user, string calldata market) external view returns (Position memory) {
        return positions[_positionKey(user, market)];
    }

    function getUserPositions(address user) external view returns (Position[] memory _positions) {
        uint256 length = positionKeysForUser[user].length();
        _positions = new Position[](length);
        for (uint256 i = 0; i < length; i++) {
            _positions[i] = positions[positionKeysForUser[user].at(i)];
        }
    }

    function _positionKey(address user, string calldata market) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, market));
    }

    // ---------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------

    function getFundingLastUpdated(string calldata market) external view returns (uint256) {
        return fundingLastUpdated[market];
    }

    function getFundingTracker(string calldata market) external view returns (int256) {
        return fundingTrackers[market];
    }

    function setFundingLastUpdated(string calldata market, uint256 timestamp) external onlyContract {
        fundingLastUpdated[market] = timestamp;
    }

    function updateFundingTracker(string calldata market, int256 fundingIncrement) external onlyContract {
        fundingTrackers[market] += fundingIncrement;
    }
}
