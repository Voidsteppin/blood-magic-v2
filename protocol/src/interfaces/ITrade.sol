// SPDX-License-Identifier: BUSL-1.1
// Derived from CAP v4 (github.com/capofficial/protocol), (c) cap.io. Non-production use only.
pragma solidity ^0.8.24;

interface ITrade {
    event GovernanceUpdated(address indexed oldGov, address indexed newGov);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event OrderCreated(
        uint256 indexed orderId,
        address indexed user,
        string market,
        bool isLong,
        uint256 margin,
        uint256 size,
        uint256 price,
        uint8 orderType,
        bool isReduceOnly
    );
    event OrderUpdated(uint256 indexed orderId, address indexed user, uint256 price, uint8 orderType);
    event OrderCancelled(uint256 indexed orderId, address indexed user);
    /// @notice A keeper tried to fill an order that broke a rule at execution time (whale cap,
    /// open interest, unaffordable fee...). The order is dropped and its margin unlocked instead
    /// of blocking every other order in the batch.
    event OrderRejected(uint256 indexed orderId, address indexed user, string reason);
    event PositionIncreased(
        uint256 indexed orderId,
        address indexed user,
        string market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 positionMargin,
        uint256 positionSize,
        uint256 positionPrice,
        int256 fundingTracker,
        uint256 fee
    );
    event PositionDecreased(
        uint256 indexed orderId,
        address indexed user,
        string market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 positionMargin,
        uint256 positionSize,
        uint256 positionPrice,
        int256 fundingTracker,
        uint256 fee,
        int256 pnl,
        int256 fundingFee
    );
    event PositionLiquidated(
        address indexed user,
        string market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 fee,
        uint256 solidarityRefund
    );
    event FundingUpdated(string market, int256 fundingTracker, int256 fundingIncrement);
}
