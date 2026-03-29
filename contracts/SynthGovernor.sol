// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SynthToken.sol";

/**
 * @title SynthGovernor
 * @notice On-chain governance module for the NovaSynth protocol.
 * @dev    Implements a proposal-based governance flow with snapshot voting:
 *
 *           1. A token holder with at least `quorumThreshold / 100` SYNTH
 *              calls {propose} to open a proposal.
 *           2. The contract records the current `block.number` as the
 *              *snapshot block* — voting power is determined by each
 *              voter's {SynthToken.balanceOfAt} at that block.
 *           3. Voting is open from `startBlock` (proposal block + 1) through
 *              `endBlock` (proposal block + `votingPeriod`).
 *           4. A proposal passes when `forVotes > againstVotes` and
 *              `forVotes >= quorumThreshold`.
 *           5. Any account may call {execute} after voting closes on a
 *              passing proposal; execution forwards the encoded `calldata_`
 *              to the `target` address via a low-level call.
 *
 *         Proposals can be cancelled at any time before execution by the
 *         original proposer or the contract owner.
 *
 * @custom:security-contact security@novasynth.fi
 */
contract SynthGovernor {
    SynthToken public token;
    address public owner;

    uint256 public proposalCount;
    uint256 public votingPeriod; // Duration in blocks
    uint256 public quorumThreshold; // Minimum votes for quorum (absolute amount)

    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        address target;
        bytes calldata_;
        uint256 snapshotBlock; // Block at which voting power is read
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool cancelled;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProposalCreated(uint256 indexed id, address proposer, uint256 snapshotBlock, uint256 endBlock);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);

    modifier onlyOwner() {
        require(msg.sender == owner, "Governor: not owner");
        _;
    }

    constructor(address _token, uint256 _votingPeriod, uint256 _quorum) {
        token = SynthToken(_token);
        owner = msg.sender;
        votingPeriod = _votingPeriod;
        quorumThreshold = _quorum;
    }

    // ═══════════════════════════════════════════════════════════════
    // PROPOSALS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Submit a new governance proposal.
     * @dev    The caller must hold at least `quorumThreshold / 100` SYNTH.
     *         The snapshot block is set to the current `block.number`;
     *         voting power is determined by each voter's balance at that block.
     *         Voting opens on the next block and closes after `votingPeriod` blocks.
     * @param  description  Human-readable description of the proposal.
     * @param  target       Contract address the proposal will call on execution.
     * @param  calldata_    ABI-encoded function call to execute if the proposal passes.
     * @return              The newly assigned proposal ID.
     */
    function propose(string calldata description, address target, bytes calldata calldata_) external returns (uint256) {
        uint256 proposerBalance = token.balanceOf(msg.sender);
        require(proposerBalance >= quorumThreshold / 100, "Governor: insufficient tokens to propose");

        proposalCount++;
        uint256 id = proposalCount;

        proposals[id] = Proposal({
            id: id,
            proposer: msg.sender,
            description: description,
            target: target,
            calldata_: calldata_,
            snapshotBlock: block.number, // Current block is the voting-power snapshot
            startBlock: block.number + 1, // Voting starts next block
            endBlock: block.number + votingPeriod,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            cancelled: false
        });

        emit ProposalCreated(id, msg.sender, block.number, block.number + votingPeriod);
        return id;
    }

    /**
     * @notice Cast a vote on an active proposal.
     * @dev    Voting power equals the caller's {SynthToken.balanceOfAt} at the
     *         proposal's snapshot block. Each address may vote only once.
     *         Reverts if the proposal is cancelled, already executed, outside
     *         its voting window, or if the caller has no recorded balance at
     *         the snapshot block.
     * @param  proposalId  The ID of the proposal to vote on.
     * @param  support     `true` to vote in favour, `false` to vote against.
     */
    function castVote(uint256 proposalId, bool support) external {
        Proposal storage prop = proposals[proposalId];
        require(prop.id != 0, "Governor: proposal not found");
        require(!prop.cancelled, "Governor: cancelled");
        require(!prop.executed, "Governor: already executed");
        require(block.number >= prop.startBlock, "Governor: voting not started");
        require(block.number <= prop.endBlock, "Governor: voting ended");
        require(!hasVoted[proposalId][msg.sender], "Governor: already voted");

        // Read voting power from the snapshot block
        uint256 weight = token.balanceOfAt(msg.sender, prop.snapshotBlock);
        require(weight > 0, "Governor: no voting power");

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            prop.forVotes += weight;
        } else {
            prop.againstVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Execute a successful proposal.
     */
    function execute(uint256 proposalId) external {
        Proposal storage prop = proposals[proposalId];
        require(prop.id != 0, "Governor: proposal not found");
        require(!prop.executed, "Governor: already executed");
        require(!prop.cancelled, "Governor: cancelled");
        require(block.number > prop.endBlock, "Governor: voting in progress");
        require(prop.forVotes > prop.againstVotes, "Governor: not passed");
        require(prop.forVotes >= quorumThreshold, "Governor: quorum not met");

        prop.executed = true;

        (bool success,) = prop.target.call(prop.calldata_);
        require(success, "Governor: execution failed");

        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage prop = proposals[proposalId];
        require(msg.sender == prop.proposer || msg.sender == owner, "Governor: not authorized");
        require(!prop.executed, "Governor: already executed");
        prop.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function getProposalState(uint256 proposalId) external view returns (string memory) {
        Proposal storage prop = proposals[proposalId];
        if (prop.id == 0) return "nonexistent";
        if (prop.cancelled) return "cancelled";
        if (prop.executed) return "executed";
        if (block.number <= prop.endBlock) return "active";
        if (prop.forVotes <= prop.againstVotes) return "defeated";
        if (prop.forVotes < quorumThreshold) return "quorum_not_met";
        return "succeeded";
    }

    function getVotingPower(address voter, uint256 proposalId) external view returns (uint256) {
        Proposal storage prop = proposals[proposalId];
        if (prop.id == 0) return 0;
        return token.balanceOfAt(voter, prop.snapshotBlock);
    }
}
