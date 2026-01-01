// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Voting} from "../../../src/staking/Voting.sol";
import {IVoting} from "../../../src/staking/IVoting.sol";
import {Proposal, ProposalState} from "../../../src/foundation/Types.sol";
import {SystemAddresses} from "../../../src/foundation/SystemAddresses.sol";
import {Errors} from "../../../src/foundation/Errors.sol";

/// @title VotingTest
/// @notice Unit tests for the Voting contract
contract VotingTest is Test {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    uint64 constant VOTING_DURATION_MICROS = 7 days * 1_000_000; // 7 days in microseconds
    uint128 constant MIN_VOTE_THRESHOLD = 100 ether;
    uint128 constant EARLY_RESOLUTION_THRESHOLD = 1000 ether;

    // ========================================================================
    // STATE
    // ========================================================================

    Voting public voting;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public proposer = makeAddr("proposer");

    bytes32 public executionHash = keccak256("execution payload");
    string public metadataUri = "ipfs://QmTest";

    // ========================================================================
    // SETUP
    // ========================================================================

    function setUp() public {
        // Deploy Voting contract at the system address
        voting = new Voting();
        vm.etch(SystemAddresses.VOTING, address(voting).code);
        voting = Voting(SystemAddresses.VOTING);

        // Initialize nextProposalId to 1 (slot 0)
        // The constructor sets this, but vm.etch doesn't preserve storage
        vm.store(SystemAddresses.VOTING, bytes32(uint256(0)), bytes32(uint256(1)));

        // Deploy mock Timestamp contract
        _deployMockTimestamp(1_000_000_000_000); // Start at 1M seconds in microseconds
    }

    // ========================================================================
    // MOCK DEPLOYMENTS
    // ========================================================================

    function _deployMockTimestamp(uint64 initialTime) internal {
        MockTimestampVoting mockTimestamp = new MockTimestampVoting(initialTime);
        vm.etch(SystemAddresses.TIMESTAMP, address(mockTimestamp).code);
        vm.store(SystemAddresses.TIMESTAMP, bytes32(0), bytes32(uint256(initialTime)));
    }

    function _advanceTime(uint64 deltaMicros) internal {
        uint64 current = MockTimestampVoting(SystemAddresses.TIMESTAMP).nowMicroseconds();
        vm.store(SystemAddresses.TIMESTAMP, bytes32(0), bytes32(uint256(current + deltaMicros)));
    }

    // ========================================================================
    // CREATE PROPOSAL TESTS
    // ========================================================================

    function test_createProposal_createsNewProposal() public {
        uint64 now_ = MockTimestampVoting(SystemAddresses.TIMESTAMP).nowMicroseconds();

        uint64 proposalId = voting.createProposal(
            proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS
        );

        assertEq(proposalId, 1, "First proposal ID should be 1");

        Proposal memory p = voting.getProposal(proposalId);
        assertEq(p.id, proposalId, "Proposal ID mismatch");
        assertEq(p.proposer, proposer, "Proposer mismatch");
        assertEq(p.executionHash, executionHash, "Execution hash mismatch");
        assertEq(p.metadataUri, metadataUri, "Metadata URI mismatch");
        assertEq(p.creationTime, now_, "Creation time mismatch");
        assertEq(p.expirationTime, now_ + VOTING_DURATION_MICROS, "Expiration time mismatch");
        assertEq(p.minVoteThreshold, MIN_VOTE_THRESHOLD, "Min vote threshold mismatch");
        assertEq(p.yesVotes, 0, "Yes votes should be 0");
        assertEq(p.noVotes, 0, "No votes should be 0");
        assertFalse(p.isResolved, "Should not be resolved");
    }

    function test_createProposal_incrementsProposalId() public {
        uint64 id1 = voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);
        uint64 id2 = voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);
        uint64 id3 = voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(voting.getNextProposalId(), 4);
    }

    function test_createProposal_emitsProposalCreatedEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IVoting.ProposalCreated(1, proposer, executionHash);

        voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);
    }

    // ========================================================================
    // VOTE TESTS
    // ========================================================================

    function test_vote_castsYesVote() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        uint128 votingPower = 50 ether;
        voting.vote(proposalId, alice, votingPower, true);

        Proposal memory p = voting.getProposal(proposalId);
        assertEq(p.yesVotes, votingPower, "Yes votes mismatch");
        assertEq(p.noVotes, 0, "No votes should be 0");
    }

    function test_vote_castsNoVote() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        uint128 votingPower = 50 ether;
        voting.vote(proposalId, alice, votingPower, false);

        Proposal memory p = voting.getProposal(proposalId);
        assertEq(p.yesVotes, 0, "Yes votes should be 0");
        assertEq(p.noVotes, votingPower, "No votes mismatch");
    }

    function test_vote_accumulatesVotes() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, 30 ether, true);
        voting.vote(proposalId, bob, 20 ether, true);
        voting.vote(proposalId, makeAddr("charlie"), 15 ether, false);

        Proposal memory p = voting.getProposal(proposalId);
        assertEq(p.yesVotes, 50 ether, "Yes votes mismatch");
        assertEq(p.noVotes, 15 ether, "No votes mismatch");
    }

    function test_vote_emitsVoteCastEvent() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        uint128 votingPower = 50 ether;

        vm.expectEmit(true, true, false, true);
        emit IVoting.VoteCast(proposalId, alice, true, votingPower);

        voting.vote(proposalId, alice, votingPower, true);
    }

    function test_vote_revertsOnNonExistentProposal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, 999));
        voting.vote(999, alice, 50 ether, true);
    }

    function test_vote_revertsAfterVotingPeriod() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        // Advance past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        Proposal memory p = voting.getProposal(proposalId);
        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodEnded.selector, p.expirationTime));
        voting.vote(proposalId, alice, 50 ether, true);
    }

    // ========================================================================
    // PROPOSAL STATE TESTS
    // ========================================================================

    function test_getProposalState_pendingDuringVoting() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        ProposalState state = voting.getProposalState(proposalId);
        assertEq(uint8(state), uint8(ProposalState.PENDING), "Should be PENDING");
    }

    function test_getProposalState_succeededWhenPassed() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        // Cast enough yes votes to meet threshold
        voting.vote(proposalId, alice, MIN_VOTE_THRESHOLD, true);

        // Advance past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        ProposalState state = voting.getProposalState(proposalId);
        assertEq(uint8(state), uint8(ProposalState.SUCCEEDED), "Should be SUCCEEDED");
    }

    function test_getProposalState_failedWhenNotEnoughVotes() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        // Cast some yes votes but below threshold
        voting.vote(proposalId, alice, MIN_VOTE_THRESHOLD / 2, true);

        // Advance past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        ProposalState state = voting.getProposalState(proposalId);
        assertEq(uint8(state), uint8(ProposalState.FAILED), "Should be FAILED");
    }

    function test_getProposalState_failedWhenMoreNoVotes() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        // Cast votes with more no than yes
        voting.vote(proposalId, alice, 60 ether, true);
        voting.vote(proposalId, bob, 70 ether, false);

        // Advance past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        ProposalState state = voting.getProposalState(proposalId);
        assertEq(uint8(state), uint8(ProposalState.FAILED), "Should be FAILED");
    }

    function test_getProposalState_revertsOnNonExistent() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, 999));
        voting.getProposalState(999);
    }

    // ========================================================================
    // IS VOTING CLOSED TESTS
    // ========================================================================

    function test_isVotingClosed_falseBeforeExpiration() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        assertFalse(voting.isVotingClosed(proposalId), "Voting should be open");
    }

    function test_isVotingClosed_trueAfterExpiration() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        _advanceTime(VOTING_DURATION_MICROS + 1);

        assertTrue(voting.isVotingClosed(proposalId), "Voting should be closed");
    }

    function test_isVotingClosed_trueWhenResolved() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, MIN_VOTE_THRESHOLD, true);
        _advanceTime(VOTING_DURATION_MICROS + 1);
        voting.resolve(proposalId);

        assertTrue(voting.isVotingClosed(proposalId), "Voting should be closed after resolution");
    }

    // ========================================================================
    // RESOLVE TESTS
    // ========================================================================

    function test_resolve_resolvesSucceededProposal() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, MIN_VOTE_THRESHOLD, true);
        _advanceTime(VOTING_DURATION_MICROS + 1);

        ProposalState state = voting.resolve(proposalId);
        assertEq(uint8(state), uint8(ProposalState.EXECUTED), "Should be EXECUTED after resolve");

        Proposal memory p = voting.getProposal(proposalId);
        assertTrue(p.isResolved, "Should be marked as resolved");
        assertGt(p.resolutionTime, 0, "Resolution time should be set");
    }

    function test_resolve_resolvesFailedProposal() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        // No votes cast
        _advanceTime(VOTING_DURATION_MICROS + 1);

        ProposalState state = voting.resolve(proposalId);
        assertEq(uint8(state), uint8(ProposalState.FAILED), "Should be FAILED");
    }

    function test_resolve_emitsProposalResolvedEvent() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, MIN_VOTE_THRESHOLD, true);
        _advanceTime(VOTING_DURATION_MICROS + 1);

        vm.expectEmit(true, false, false, true);
        emit IVoting.ProposalResolved(proposalId, ProposalState.EXECUTED);

        voting.resolve(proposalId);
    }

    function test_resolve_revertsBeforeVotingEnds() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        Proposal memory p = voting.getProposal(proposalId);
        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodNotEnded.selector, p.expirationTime));
        voting.resolve(proposalId);
    }

    function test_resolve_revertsOnAlreadyResolved() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        voting.resolve(proposalId);

        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalAlreadyResolved.selector, proposalId));
        voting.resolve(proposalId);
    }

    function test_resolve_revertsOnNonExistent() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, 999));
        voting.resolve(999);
    }

    // ========================================================================
    // EARLY RESOLUTION TESTS
    // ========================================================================

    function test_setEarlyResolutionThreshold_setsThreshold() public {
        vm.prank(SystemAddresses.TIMELOCK);
        voting.setEarlyResolutionThreshold(EARLY_RESOLUTION_THRESHOLD);

        assertEq(voting.getEarlyResolutionThreshold(), EARLY_RESOLUTION_THRESHOLD);
    }

    function test_setEarlyResolutionThreshold_revertsUnauthorized() public {
        vm.expectRevert();
        voting.setEarlyResolutionThreshold(EARLY_RESOLUTION_THRESHOLD);
    }

    function test_canBeResolvedEarly_falseWhenThresholdZero() public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, 1000 ether, true);

        assertFalse(voting.canBeResolvedEarly(proposalId), "Should not allow early resolution when threshold is 0");
    }

    function test_canBeResolvedEarly_trueWhenYesExceedsThreshold() public {
        vm.prank(SystemAddresses.TIMELOCK);
        voting.setEarlyResolutionThreshold(EARLY_RESOLUTION_THRESHOLD);

        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, EARLY_RESOLUTION_THRESHOLD, true);

        assertTrue(voting.canBeResolvedEarly(proposalId), "Should allow early resolution");
    }

    function test_canBeResolvedEarly_trueWhenNoExceedsThreshold() public {
        vm.prank(SystemAddresses.TIMELOCK);
        voting.setEarlyResolutionThreshold(EARLY_RESOLUTION_THRESHOLD);

        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, EARLY_RESOLUTION_THRESHOLD, false);

        assertTrue(voting.canBeResolvedEarly(proposalId), "Should allow early resolution on no votes");
    }

    function test_resolve_earlyWithThreshold() public {
        vm.prank(SystemAddresses.TIMELOCK);
        voting.setEarlyResolutionThreshold(EARLY_RESOLUTION_THRESHOLD);

        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, EARLY_RESOLUTION_THRESHOLD, true);

        // Should be able to resolve without waiting for expiration
        ProposalState state = voting.resolve(proposalId);
        assertEq(uint8(state), uint8(ProposalState.EXECUTED), "Should resolve early");
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_createProposal_variousThresholds(uint128 threshold) public {
        uint64 proposalId = voting.createProposal(proposer, executionHash, metadataUri, threshold, VOTING_DURATION_MICROS);

        Proposal memory p = voting.getProposal(proposalId);
        assertEq(p.minVoteThreshold, threshold);
    }

    function testFuzz_vote_variousAmounts(uint128 yesVotes, uint128 noVotes) public {
        uint64 proposalId =
            voting.createProposal(proposer, executionHash, metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS);

        voting.vote(proposalId, alice, yesVotes, true);
        voting.vote(proposalId, bob, noVotes, false);

        Proposal memory p = voting.getProposal(proposalId);
        assertEq(p.yesVotes, yesVotes);
        assertEq(p.noVotes, noVotes);
    }

    function testFuzz_multipleProposals(uint8 numProposals) public {
        vm.assume(numProposals > 0 && numProposals <= 50);

        for (uint8 i = 0; i < numProposals; i++) {
            uint64 proposalId = voting.createProposal(
                proposer, keccak256(abi.encode(i)), metadataUri, MIN_VOTE_THRESHOLD, VOTING_DURATION_MICROS
            );
            assertEq(proposalId, uint64(i) + 1);
        }

        assertEq(voting.getNextProposalId(), uint64(numProposals) + 1);
    }
}

// ============================================================================
// MOCK CONTRACTS
// ============================================================================

contract MockTimestampVoting {
    uint64 public microseconds;

    constructor(uint64 initialTime) {
        microseconds = initialTime;
    }

    function nowMicroseconds() external view returns (uint64) {
        return microseconds;
    }
}

