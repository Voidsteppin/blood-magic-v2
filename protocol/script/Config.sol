// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStore} from "../src/interfaces/IStore.sol";

/// @notice Launch settings, shared by the deploy script and the tests.
library Config {
    uint256 internal constant USDC = 1e6;

    function defaultParams() internal pure returns (IStore.Params memory p) {
        p.feeRatesBps = [uint16(5), 10, 25, 50]; // 0.05% to $1K, 0.10% to $10K, 0.25% to $50K, 0.50% above
        p.feeBrackets = [1_000 * USDC, 10_000 * USDC, 50_000 * USDC];
        p.maxPositionSize = 25_000 * USDC; // whale cap per wallet per market
        p.keeperFeeShareBps = 1000; // 10% of each fee to the keeper
        p.dividendShareBps = 3000; // then 30% split equally between members
        p.solidarityShareBps = 2000; // 20% to the solidarity fund, the rest to the pool
        p.solidarityRefundBps = 2500; // 25% of margin back when a small trader is liquidated
        p.solidarityMarginCap = 500 * USDC;
        p.minMemberDeposit = 100 * USDC;
        p.minimumMarginLevelBps = 2000; // liquidate when equity < 20% of locked margin
        p.maxUtilizationBps = 5000; // open interest up to 50% of the pool
        p.maxProfitBps = 10000; // profit per close capped at 100% of the size closed
        p.poolWithdrawalFeeBps = 10;
        p.bufferPayoutPeriod = 7 days;
        p.maxPriceAge = 26 hours; // Chainlink ETH/USD heartbeat on Arbitrum is 24h
    }

    function ethMarket(address feed) internal pure returns (IStore.Market memory) {
        return IStore.Market({
            symbol: "ETH-USD",
            feed: feed,
            minSettlementTime: 30,
            maxLeverage: 50,
            fundingFactor: 5000, // 50% a year when all open interest is on one side
            maxOI: 5_000_000 * USDC,
            minSize: 20 * USDC
        });
    }
}
