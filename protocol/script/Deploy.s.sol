// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {Store} from "../src/Store.sol";
import {Trade} from "../src/Trade.sol";
import {Pool} from "../src/Pool.sol";
import {CLP} from "../src/CLP.sol";
import {Chainlink} from "../src/Chainlink.sol";
import {Council} from "../src/Council.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {Config} from "./Config.sol";

/// @notice Deploys Blood Magic: test USDC, Store, Trade, Pool, CLP, the Chainlink reader and the
/// ETH-USD market; seeds the Collective so the deployer is its first member; then hands every
/// contract to the Council. Addresses are written to deployments/<chainId>.json.
///
/// Env (all optional):
///   FEED            Chainlink ETH/USD feed. Unset = deploy a settable mock (local chains).
///   START_PRICE     Mock starting price, 8 decimals (default 2700e8).
///   SEQUENCER       Chainlink L2 sequencer uptime feed (default none).
///   SEED_LIQUIDITY  Test USDC the deployer puts in the pool (default 100,000).
///   VOTING_PERIOD   Council voting period in seconds (default 1 hour, short for testnet).
///   QUORUM_BPS      Share of members who must vote (default 2000 = 20%).
contract Deploy is Script {
    function run() external {
        address feed = vm.envOr("FEED", address(0));
        int256 startPrice = vm.envOr("START_PRICE", int256(2700e8));
        address sequencer = vm.envOr("SEQUENCER", address(0));
        uint256 seed = vm.envOr("SEED_LIQUIDITY", uint256(100_000e6));
        uint256 votingPeriod = vm.envOr("VOTING_PERIOD", uint256(1 hours));
        uint256 quorumBps = vm.envOr("QUORUM_BPS", uint256(2000));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        console.log("Deploying from", deployer, "on chain", block.chainid);

        MockUSDC usdc = new MockUSDC();
        if (feed == address(0)) {
            feed = address(new MockAggregator(8, startPrice));
            console.log("MockAggregator (run keeper/price-relay.js for live prices):", feed);
        }

        Store store = new Store(deployer, Config.defaultParams());
        Trade trade = new Trade(deployer);
        Pool pool = new Pool(deployer);
        CLP clp = new CLP(address(store));
        Chainlink chainlink = new Chainlink(sequencer);

        store.link(address(trade), address(pool), address(usdc), address(clp));
        trade.link(address(chainlink), address(pool), address(store));
        pool.link(address(trade), address(store));
        store.setMarket("ETH-USD", Config.ethMarket(feed));
        require(trade.getPrice("ETH-USD") > 0, "ETH-USD feed returns no usable price");

        usdc.mint(deployer, seed);
        usdc.approve(address(store), seed);
        pool.addLiquidity(seed);

        Council council = new Council(address(store), address(trade), address(pool), votingPeriod, quorumBps);
        store.updateGov(address(council));
        trade.updateGov(address(council));
        pool.updateGov(address(council));

        vm.stopBroadcast();

        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "deployedAt", block.timestamp);
        vm.serializeAddress(key, "usdc", address(usdc));
        vm.serializeAddress(key, "store", address(store));
        vm.serializeAddress(key, "trade", address(trade));
        vm.serializeAddress(key, "pool", address(pool));
        vm.serializeAddress(key, "clp", address(clp));
        vm.serializeAddress(key, "chainlink", address(chainlink));
        vm.serializeAddress(key, "council", address(council));
        string memory json = vm.serializeAddress(key, "ethUsdFeed", feed);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);

        console.log("Store:  ", address(store));
        console.log("Trade:  ", address(trade));
        console.log("Pool:   ", address(pool));
        console.log("Council:", address(council), "(governs all three)");
        console.log("Wrote", path);
    }
}
