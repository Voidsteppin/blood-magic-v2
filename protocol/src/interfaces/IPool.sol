// SPDX-License-Identifier: BUSL-1.1
// Derived from CAP v4 (github.com/capofficial/protocol), (c) cap.io. Non-production use only.
pragma solidity ^0.8.24;

interface IPool {
    event GovernanceUpdated(address indexed oldGov, address indexed newGov);
    event AddLiquidity(address indexed user, uint256 amount, uint256 clpAmount, uint256 poolBalance);
    event RemoveLiquidity(address indexed user, uint256 amount, uint256 feeAmount, uint256 clpAmount, uint256 poolBalance);
    event PoolPayIn(address indexed user, string market, uint256 amount, uint256 bufferToPoolAmount, uint256 poolBalance, uint256 bufferBalance);
    event PoolPayOut(address indexed user, string market, uint256 amount, uint256 poolBalance, uint256 bufferBalance);
    event FeePaid(address indexed user, string market, uint256 fee, uint256 keeperFee, uint256 toPool, uint256 toMembers, uint256 toSolidarity, bool isLiquidation);
    event MemberJoined(address indexed member);
    event MemberLeft(address indexed member);
    event DividendClaimed(address indexed member, uint256 amount);

    function memberSince(address account) external view returns (uint256);
    function memberCount() external view returns (uint256);

    function creditTraderLoss(address user, string memory market, uint256 amount) external;
    function debitTraderProfit(address user, string memory market, uint256 amount) external returns (uint256 paid);
    function creditFee(address user, string memory market, uint256 fee, address keeper, bool isLiquidation) external;
}
