// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../interfaces/IChainlink.sol";

/// @notice Settable price feed for tests and local chains (kept live by keeper/price-relay.js).
contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        setPrice(_answer);
    }

    function setPrice(int256 _answer) public {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function description() external pure override returns (string memory) {
        return "MOCK / USD";
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
