// SPDX-License-Identifier: BUSL-1.1
// Derived from CAP v4 (github.com/capofficial/protocol), (c) cap.io. Non-production use only.
pragma solidity ^0.8.24;

interface IStore {
    event GovernanceUpdated(address indexed oldGov, address indexed newGov);
    event ParamsUpdated(Params params);
    event MarketSet(string market, Market info);

    struct Market {
        string symbol;
        address feed;
        uint16 minSettlementTime; // seconds a market order waits for a fresh price before it can fill at the old one
        uint16 maxLeverage; // 0 disables the market
        uint32 fundingFactor; // yearly funding rate, in bps, when open interest is entirely on one side
        uint256 maxOI; // per side, in currency units
        uint256 minSize;
    }

    struct Order {
        bool isLong;
        bool isReduceOnly;
        uint8 orderType; // 0 = market, 1 = limit, 2 = stop
        uint72 orderId;
        address user;
        string market;
        uint64 timestamp;
        uint256 price;
        uint256 margin;
        uint256 size;
    }

    struct Position {
        bool isLong;
        uint64 timestamp;
        address user;
        string market;
        int256 fundingTracker;
        uint256 price;
        uint256 margin;
        uint256 size;
    }

    /// @notice Every rule the Council can change, in one place.
    struct Params {
        uint16[4] feeRatesBps; // progressive fee rates, like tax brackets, on a wallet's total position in a market
        uint256[3] feeBrackets; // upper bounds of the first three brackets
        uint256 maxPositionSize; // whale cap per wallet per market
        uint16 keeperFeeShareBps; // share of every fee paid to the keeper that executed or liquidated
        uint16 dividendShareBps; // share of the remaining fee split equally between members
        uint16 solidarityShareBps; // share of the remaining fee paid into the solidarity fund
        uint16 solidarityRefundBps; // share of a small trader's margin refunded on liquidation
        uint256 solidarityMarginCap; // positions with margin up to this are "small"
        uint256 minMemberDeposit; // pool deposit needed to be a member
        uint16 minimumMarginLevelBps; // account is liquidated when equity / locked margin falls below this
        uint16 maxUtilizationBps; // total open interest may not exceed this share of the pool
        uint16 maxProfitBps; // profit per close is capped at this share of the size closed
        uint16 poolWithdrawalFeeBps;
        uint32 bufferPayoutPeriod; // trader losses drip from the buffer into the pool over this period
        uint32 maxPriceAge; // oracle answers older than this are rejected
    }

    // Wiring
    function gov() external view returns (address);
    function trade() external view returns (address);
    function pool() external view returns (address);
    function currency() external view returns (address);
    function clp() external view returns (address);

    // Constants
    function BPS_DIVIDER() external view returns (uint256);
    function FUNDING_INTERVAL() external view returns (uint256);

    // Params and markets
    function getParams() external view returns (Params memory);
    function getMarket(string memory market) external view returns (Market memory);
    function getMarketList() external view returns (string[] memory);

    // Tokens
    function transferIn(address user, uint256 amount) external;
    function transferOut(address user, uint256 amount) external;
    function mintCLP(address user, uint256 amount) external;
    function burnCLP(address user, uint256 amount) external;
    function getCLPSupply() external view returns (uint256);

    // Trader balances
    function getBalance(address user) external view returns (uint256);
    function incrementBalance(address user, uint256 amount) external;
    function decrementBalance(address user, uint256 amount) external;
    function getLockedMargin(address user) external view returns (uint256);
    function lockMargin(address user, uint256 amount) external;
    function unlockMargin(address user, uint256 amount) external;
    function getUsersWithLockedMarginLength() external view returns (uint256);
    function getUserWithLockedMargin(uint256 i) external view returns (address);

    // Pool, buffer, solidarity fund, dividends
    function poolBalance() external view returns (uint256);
    function bufferBalance() external view returns (uint256);
    function poolLastPaid() external view returns (uint256);
    function solidarityFund() external view returns (uint256);
    function dividendReserve() external view returns (uint256);
    function incrementPoolBalance(uint256 amount) external;
    function decrementPoolBalance(uint256 amount) external;
    function incrementBufferBalance(uint256 amount) external;
    function decrementBufferBalance(uint256 amount) external;
    function setPoolLastPaid(uint256 timestamp) external;
    function incrementSolidarityFund(uint256 amount) external;
    function decrementSolidarityFund(uint256 amount) external;
    function incrementDividendReserve(uint256 amount) external;
    function decrementDividendReserve(uint256 amount) external;
    function getUserPoolBalance(address user) external view returns (uint256);

    // Open interest
    function getOILong(string memory market) external view returns (uint256);
    function getOIShort(string memory market) external view returns (uint256);
    function totalOI() external view returns (uint256);
    function incrementOI(string memory market, uint256 size, bool isLong) external;
    function decrementOI(string memory market, uint256 size, bool isLong) external;

    // Orders
    function addOrder(Order memory order) external returns (uint256);
    function updateOrder(Order memory order) external;
    function removeOrder(uint256 orderId) external;
    function getOrder(uint256 id) external view returns (Order memory);
    function getOrders() external view returns (Order[] memory);
    function getUserOrders(address user) external view returns (Order[] memory);

    // Positions
    function addOrUpdatePosition(Position memory position) external;
    function removePosition(address user, string memory market) external;
    function getPosition(address user, string memory market) external view returns (Position memory);
    function getUserPositions(address user) external view returns (Position[] memory);

    // Funding
    function getFundingLastUpdated(string memory market) external view returns (uint256);
    function getFundingTracker(string memory market) external view returns (int256);
    function setFundingLastUpdated(string memory market, uint256 timestamp) external;
    function updateFundingTracker(string memory market, int256 fundingIncrement) external;
}
