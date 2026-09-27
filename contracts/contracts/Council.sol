// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMembership {
    function memberSince(address account) external view returns (uint256);
    function memberCount() external view returns (uint256);
}

/// @title Council
/// @notice Owns the exchange so that no single wallet controls it. Any member of the Collective
/// can propose a call to the exchange (change fees, add a market, ...). Members then vote, one
/// member one vote. Only wallets that were already members when the proposal was made can vote
/// on it, so fresh wallets created mid-vote don't count.
contract Council {
    uint256 public constant BPS = 10_000;

    struct Proposal {
        address proposer;
        uint64 createdAt;
        uint64 endsAt;
        uint32 yes;
        uint32 no;
        uint32 electorate; // member count when the proposal was made
        bool executed;
        bytes data; // calldata for the exchange
        string description;
    }

    address public immutable exchange;
    uint256 public immutable votingPeriod;
    uint256 public immutable quorumBps; // share of the electorate that must vote

    Proposal[] internal _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event Proposed(uint256 indexed id, address indexed proposer, string description, uint256 endsAt);
    event Voted(uint256 indexed id, address indexed voter, bool support);
    event Executed(uint256 indexed id);

    error NotMember();
    error NotEligible();
    error AlreadyVoted();
    error VotingClosed();
    error VotingOpen();
    error AlreadyExecuted();
    error Rejected();
    error UnknownProposal();

    constructor(address _exchange, uint256 _votingPeriod, uint256 _quorumBps) {
        require(_votingPeriod > 0 && _quorumBps <= BPS, "config");
        exchange = _exchange;
        votingPeriod = _votingPeriod;
        quorumBps = _quorumBps;
    }

    function propose(bytes calldata data, string calldata description) external returns (uint256 id) {
        if (IMembership(exchange).memberSince(msg.sender) == 0) revert NotMember();
        id = _proposals.length;
        Proposal storage p = _proposals.push();
        p.proposer = msg.sender;
        p.createdAt = uint64(block.timestamp);
        p.endsAt = uint64(block.timestamp + votingPeriod);
        p.electorate = uint32(IMembership(exchange).memberCount());
        p.data = data;
        p.description = description;
        emit Proposed(id, msg.sender, description, p.endsAt);
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = _proposal(id);
        if (block.timestamp >= p.endsAt) revert VotingClosed();
        uint256 since = IMembership(exchange).memberSince(msg.sender);
        if (since == 0 || since >= p.createdAt) revert NotEligible();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        hasVoted[id][msg.sender] = true;
        if (support) p.yes++;
        else p.no++;
        emit Voted(id, msg.sender, support);
    }

    /// @notice Anyone can execute a proposal that passed once voting has ended.
    function execute(uint256 id) external {
        Proposal storage p = _proposal(id);
        if (block.timestamp < p.endsAt) revert VotingOpen();
        if (p.executed) revert AlreadyExecuted();
        if (!passed(id)) revert Rejected();
        p.executed = true;
        (bool ok, bytes memory ret) = exchange.call(p.data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit Executed(id);
    }

    function passed(uint256 id) public view returns (bool) {
        Proposal storage p = _proposal(id);
        uint256 quorum = (uint256(p.electorate) * quorumBps + BPS - 1) / BPS;
        if (quorum == 0) quorum = 1;
        return p.yes > p.no && p.yes + p.no >= quorum;
    }

    function quorumFor(uint256 id) external view returns (uint256 quorum) {
        Proposal storage p = _proposal(id);
        quorum = (uint256(p.electorate) * quorumBps + BPS - 1) / BPS;
        if (quorum == 0) quorum = 1;
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposal(id);
    }

    function _proposal(uint256 id) internal view returns (Proposal storage) {
        if (id >= _proposals.length) revert UnknownProposal();
        return _proposals[id];
    }
}
