// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {Council} from "../src/Council.sol";
import {Store} from "../src/Store.sol";
import {IStore} from "../src/interfaces/IStore.sol";

contract CouncilTest is Base {
    Council internal council;

    function setUp() public override {
        super.setUp();
        council = new Council(address(store), address(trade), address(pool), 1 hours, 2000);
        store.updateGov(address(council));
        trade.updateGov(address(council));
        pool.updateGov(address(council));

        vm.prank(alice);
        pool.addLiquidity(100 * U);
        vm.prank(bob);
        pool.addLiquidity(100 * U);
        vm.warp(block.timestamp + 1);
    }

    function _whaleCapProposal(uint256 newCap) internal view returns (bytes memory) {
        IStore.Params memory p = store.getParams();
        p.maxPositionSize = newCap;
        return abi.encodeCall(Store.setParams, (p));
    }

    function test_CouncilIsTheOnlyGovernance() public {
        assertEq(store.gov(), address(council));
        assertEq(trade.gov(), address(council));
        assertEq(pool.gov(), address(council));
        IStore.Params memory p = store.getParams();
        vm.expectRevert("!governance");
        store.setParams(p);
    }

    function test_MembersVoteToChangeRules() public {
        bytes memory data = _whaleCapProposal(10_000 * U);
        vm.prank(alice);
        uint256 id = council.propose(address(store), data, "Lower the whale cap");

        vm.prank(alice);
        council.vote(id, true);
        vm.prank(bob);
        council.vote(id, true);
        vm.prank(lp);
        council.vote(id, false); // the biggest depositor is outvoted: one member, one vote

        vm.expectRevert(Council.VotingOpen.selector);
        council.execute(id);

        vm.warp(block.timestamp + 1 hours);
        council.execute(id);
        assertEq(store.getParams().maxPositionSize, 10_000 * U);
    }

    function test_RejectedProposalCannotRun() public {
        bytes memory data = _whaleCapProposal(10_000 * U);
        vm.prank(alice);
        uint256 id = council.propose(address(store), data, "Lower the whale cap");
        vm.prank(bob);
        council.vote(id, false);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(Council.Rejected.selector);
        council.execute(id);
    }

    function test_OnlyMembersPropose() public {
        bytes memory data = _whaleCapProposal(1);
        vm.prank(carol);
        vm.expectRevert(Council.NotMember.selector);
        council.propose(address(store), data, "x");
    }

    function test_ProposalsCanOnlyTargetTheProtocol() public {
        vm.prank(alice);
        vm.expectRevert(Council.InvalidTarget.selector);
        council.propose(address(usdc), abi.encodeWithSignature("mint(address,uint256)", alice, 1), "x");
    }

    function test_LateJoinersCannotVote() public {
        bytes memory data = _whaleCapProposal(10_000 * U);
        vm.prank(alice);
        uint256 id = council.propose(address(store), data, "x");
        vm.prank(carol);
        pool.addLiquidity(100 * U);
        vm.prank(carol);
        vm.expectRevert(Council.NotEligible.selector);
        council.vote(id, true);
    }

    function test_HardLimitsBindTheCouncilToo() public {
        IStore.Params memory p = store.getParams();
        p.feeRatesBps[3] = 600; // above the 5% ceiling
        vm.prank(alice);
        uint256 id = council.propose(address(store), abi.encodeCall(Store.setParams, (p)), "Gouge whales");
        vm.prank(alice);
        council.vote(id, true);
        vm.prank(bob);
        council.vote(id, true);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert("!max-fee");
        council.execute(id);
    }
}
