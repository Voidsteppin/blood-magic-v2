// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMembership {
    function memberSince(address account) external view returns (uint256);
    function memberCount() external view returns (uint256);
}

/// @title Council
/// @notice Governs Store, Trade and Pool so that no single wallet controls the exchange. Any member
/// of the Collective can propose a call to one of those three contracts (change fees, add a market,
/// ...). Members vote, one member one vote. Only wallets that were already members when the
/// proposal was made can vote on it, so wallets created mid-vote don't count.
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
        address target;
        bytes data;
        string description;
    }

    IMembership public immutable pool;
    address public immutable store;
    address public immutable trade;
    uint256 public immutable votingPeriod;
    uint256 public immutable quorumBps; // share of the electorate that must vote

    Proposal[] internal _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event Proposed(uint256 indexed id, address indexed proposer, address target, string description, uint256 endsAt);
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
    error InvalidTarget();

    constructor(address _store, address _trade, address _pool, uint256 _votingPeriod, uint256 _quorumBps) {
        require(_votingPeriod > 0 && _quorumBps <= BPS, "config");
        store = _store;
        trade = _trade;
        pool = IMembership(_pool);
        votingPeriod = _votingPeriod;
        quorumBps = _quorumBps;
    }

    function propose(address target, bytes calldata data, string calldata description) external returns (uint256 id) {
        if (target != store && target != trade && target != address(pool)) revert InvalidTarget();
        if (pool.memberSince(msg.sender) == 0) revert NotMember();
        id = _proposals.length;
        Proposal storage p = _proposals.push();
        p.proposer = msg.sender;
        p.createdAt = uint64(block.timestamp);
        p.endsAt = uint64(block.timestamp + votingPeriod);
        p.electorate = uint32(pool.memberCount());
        p.target = target;
        p.data = data;
        p.description = description;
        emit Proposed(id, msg.sender, target, description, p.endsAt);
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = _proposal(id);
        if (block.timestamp >= p.endsAt) revert VotingClosed();
        uint256 since = pool.memberSince(msg.sender);
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
        (bool ok, bytes memory ret) = p.target.call(p.data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit Executed(id);
    }

    function passed(uint256 id) public view returns (bool) {
        Proposal storage p = _proposal(id);
        return p.yes > p.no && p.yes + p.no >= _quorum(p.electorate);
    }

    function quorumFor(uint256 id) external view returns (uint256) {
        return _quorum(_proposal(id).electorate);
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposal(id);
    }

    function _quorum(uint256 electorate) internal view returns (uint256 quorum) {
        quorum = (electorate * quorumBps + BPS - 1) / BPS;
        if (quorum == 0) quorum = 1;
    }

    function _proposal(uint256 id) internal view returns (Proposal storage) {
        if (id >= _proposals.length) revert UnknownProposal();
        return _proposals[id];
    }
}
