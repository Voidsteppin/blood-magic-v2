// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IChainlink {
    /// @notice 18-decimal price, or 0 if the feed is unset, stale, non-positive or the L2 sequencer is down.
    function getPrice(address feed, uint256 maxAge) external view returns (uint256);
}
