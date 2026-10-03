// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface, IChainlink} from "./interfaces/IChainlink.sol";

/// @title Chainlink
/// @notice Reads Chainlink feeds as 18-decimal prices. Returns 0 instead of reverting when a price
/// can't be trusted (stale, non-positive, sequencer down), so callers can skip rather than fail a
/// whole keeper batch.
contract Chainlink is IChainlink {
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant GRACE_PERIOD_TIME = 3600;

    /// @dev Chainlink L2 sequencer uptime feed; zero on L1s and testnets that don't have one.
    AggregatorV3Interface public immutable sequencerUptimeFeed;

    constructor(address sequencer) {
        sequencerUptimeFeed = AggregatorV3Interface(sequencer);
    }

    function getPrice(address feed, uint256 maxAge) external view returns (uint256) {
        if (feed == address(0)) return 0;

        if (address(sequencerUptimeFeed) != address(0)) {
            (, int256 status, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
            // 0 = up, 1 = down; prices right after a restart may be stale, so wait out a grace period
            if (status != 0 || block.timestamp - startedAt <= GRACE_PERIOD_TIME) return 0;
        }

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (price <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return 0;
        if (block.timestamp - updatedAt > maxAge) return 0;

        return uint256(price) * UNIT / 10 ** priceFeed.decimals();
    }
}
