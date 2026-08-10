// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { LLMBattle } from "src/debate/LLMBattle.sol";
import { ValidatorConsensusInfo } from "src/foundation/Types.sol";

contract MockBattleValidatorManagement {
    ValidatorConsensusInfo[] private _activeValidators;
    uint64 private _currentEpoch = 7;

    function addValidator(
        address pool
    ) external {
        _activeValidators.push(
            ValidatorConsensusInfo({
                validator: pool,
                consensusPubkey: "",
                consensusPop: "",
                votingPower: 100 ether,
                validatorIndex: uint64(_activeValidators.length),
                networkAddresses: "",
                fullnodeAddresses: ""
            })
        );
    }

    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        return _activeValidators;
    }

    function getCurrentEpoch() external view returns (uint64) {
        return _currentEpoch;
    }
}

contract MockBattleStaking {
    mapping(address pool => address voter) private _poolVoters;

    function setPoolVoter(
        address pool,
        address voter
    ) external {
        _poolVoters[pool] = voter;
    }

    function getPoolVoter(
        address pool
    ) external view returns (address) {
        return _poolVoters[pool];
    }
}

contract LLMBattleTest is Test {
    LLMBattle private battle;
    MockBattleValidatorManagement private validatorManagement;
    MockBattleStaking private staking;

    address private constant SPONSOR = address(0x5000);
    address private constant CONTENDER_A = address(0xA11CE);
    address private constant CONTENDER_B = address(0xB0B);
    address private constant TEAM_A_2 = address(0xA12);
    address private constant TEAM_B_2 = address(0xB02);
    address private constant TEAM_B_3 = address(0xB03);
    address private constant OUTSIDER = address(0xBAD);

    uint256 private constant WINNER_PRIZE = 10 ether;
    uint256 private constant JUROR_POOL = 4 ether;

    bytes32 private constant REASON_A = keccak256("Rust has the stronger case");
    bytes32 private constant REASON_B = keccak256("Zig has the stronger case");
    bytes32 private constant SALT_1 = keccak256("validator-1-secret");
    bytes32 private constant SALT_2 = keccak256("validator-2-secret");
    bytes32 private constant SALT_3 = keccak256("validator-3-secret");
    bytes32 private constant SALT_4 = keccak256("validator-4-secret");

    address[4] private pools = [address(0x101), address(0x102), address(0x103), address(0x104)];
    address[4] private voters = [address(0x201), address(0x202), address(0x203), address(0x204)];

    function setUp() public {
        validatorManagement = new MockBattleValidatorManagement();
        staking = new MockBattleStaking();

        for (uint256 i; i < pools.length; ++i) {
            validatorManagement.addValidator(pools[i]);
            staking.setPoolVoter(pools[i], voters[i]);
            vm.deal(voters[i], 1 ether);
        }

        battle = new LLMBattle(address(validatorManagement), address(staking));
        vm.deal(SPONSOR, 100 ether);
    }

    function test_FourValidatorBattle_SideAWinsAndEveryoneCanWithdraw() public {
        uint64 battleId = _createAndLockBattle();

        LLMBattle.Battle memory locked = battle.getBattle(battleId);
        assertEq(uint8(locked.phase), uint8(LLMBattle.Phase.Commit));
        assertEq(locked.validatorEpoch, 7);
        assertEq(locked.validatorCount, 4);
        assertEq(locked.quorum, 3);
        assertTrue(locked.transcriptRoot != bytes32(0));

        _commit(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _commit(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _commit(battleId, 2, LLMBattle.Choice.SideA, REASON_A, SALT_3);
        _commit(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);

        vm.warp(locked.commitDeadline);
        battle.openReveal(battleId);

        _reveal(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _reveal(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _reveal(battleId, 2, LLMBattle.Choice.SideA, REASON_A, SALT_3);
        _reveal(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);

        // All four validators revealed, so resolution need not wait for the deadline.
        battle.resolve(battleId);

        LLMBattle.Battle memory resolved = battle.getBattle(battleId);
        assertEq(uint8(resolved.phase), uint8(LLMBattle.Phase.Resolved));
        assertEq(uint8(resolved.outcome), uint8(LLMBattle.Outcome.SideA));
        assertEq(resolved.votesA, 3);
        assertEq(resolved.votesB, 1);
        assertEq(resolved.revealedVotes, 4);
        assertEq(resolved.jurorRewardPerVote, 1 ether);
        assertEq(battle.claimable(CONTENDER_A), WINNER_PRIZE);

        for (uint256 i; i < voters.length; ++i) {
            vm.prank(voters[i]);
            battle.claimJurorReward(battleId, pools[i]);
            assertEq(battle.claimable(voters[i]), 1 ether);
        }

        uint256 contenderBalanceBefore = CONTENDER_A.balance;
        vm.prank(CONTENDER_A);
        battle.withdraw();
        assertEq(CONTENDER_A.balance, contenderBalanceBefore + WINNER_PRIZE);

        for (uint256 i; i < voters.length; ++i) {
            uint256 voterBalanceBefore = voters[i].balance;
            vm.prank(voters[i]);
            battle.withdraw();
            assertEq(voters[i].balance, voterBalanceBefore + 1 ether);
        }
        assertEq(address(battle).balance, 0);
    }

    function test_TwoVersusThreeBattle_AssignedSpeakersDebateAndWinningTeamSplitsPrize() public {
        uint64 battleId = _createTwoVersusThreeBattle();

        address[] memory teamA = battle.getTeamMembers(battleId, LLMBattle.Choice.SideA);
        address[] memory teamB = battle.getTeamMembers(battleId, LLMBattle.Choice.SideB);
        assertEq(teamA.length, 2);
        assertEq(teamB.length, 3);
        assertEq(teamA[0], CONTENDER_A);
        assertEq(teamA[1], TEAM_A_2);
        assertEq(teamB[0], CONTENDER_B);
        assertEq(teamB[1], TEAM_B_2);
        assertEq(teamB[2], TEAM_B_3);
        assertEq(uint8(battle.participantSide(battleId, TEAM_B_3)), uint8(LLMBattle.Choice.SideB));

        vm.prank(TEAM_A_2);
        vm.expectRevert(
            abi.encodeWithSelector(
                LLMBattle.NotRoundSpeaker.selector,
                LLMBattle.Choice.SideA,
                LLMBattle.Round.Opening,
                CONTENDER_A,
                TEAM_A_2
            )
        );
        battle.submitArgument(battleId, LLMBattle.Round.Opening, "A teammate cannot steal the opening");

        _submitTwoVersusThreeDebate(battleId);
        assertEq(battle.argumentAuthor(battleId, LLMBattle.Choice.SideA, LLMBattle.Round.Rebuttal), TEAM_A_2);
        assertEq(battle.argumentAuthor(battleId, LLMBattle.Choice.SideB, LLMBattle.Round.Finisher), TEAM_B_3);
        battle.lockTranscript(battleId);

        LLMBattle.Battle memory locked = battle.getBattle(battleId);
        assertEq(locked.teamSizeA, 2);
        assertEq(locked.teamSizeB, 3);

        _commit(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _commit(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _commit(battleId, 2, LLMBattle.Choice.SideA, REASON_A, SALT_3);
        _commit(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);

        vm.warp(locked.commitDeadline);
        battle.openReveal(battleId);
        _reveal(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _reveal(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _reveal(battleId, 2, LLMBattle.Choice.SideA, REASON_A, SALT_3);
        _reveal(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);
        battle.resolve(battleId);

        assertEq(uint8(battle.getBattle(battleId).outcome), uint8(LLMBattle.Outcome.SideA));
        assertEq(battle.claimable(CONTENDER_A), WINNER_PRIZE / 2);
        assertEq(battle.claimable(TEAM_A_2), WINNER_PRIZE / 2);
        assertEq(battle.claimable(CONTENDER_B), 0);
        assertEq(battle.claimable(TEAM_B_2), 0);
        assertEq(battle.claimable(TEAM_B_3), 0);
    }

    function test_NoQuorum_RefundsBothPoolsAndPaysNoJurorReward() public {
        uint64 battleId = _createAndLockBattle();
        LLMBattle.Battle memory locked = battle.getBattle(battleId);

        _commit(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _commit(battleId, 1, LLMBattle.Choice.SideB, REASON_B, SALT_2);

        vm.warp(locked.commitDeadline);
        battle.openReveal(battleId);
        _reveal(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _reveal(battleId, 1, LLMBattle.Choice.SideB, REASON_B, SALT_2);

        vm.warp(locked.revealDeadline);
        battle.resolve(battleId);

        LLMBattle.Battle memory resolved = battle.getBattle(battleId);
        assertEq(uint8(resolved.outcome), uint8(LLMBattle.Outcome.NoQuorum));
        assertEq(resolved.revealedVotes, 2);
        assertEq(resolved.jurorRewardPerVote, 0);
        assertEq(battle.claimable(SPONSOR), WINNER_PRIZE + JUROR_POOL);

        vm.prank(voters[0]);
        vm.expectRevert(abi.encodeWithSelector(LLMBattle.NoJurorReward.selector, pools[0]));
        battle.claimJurorReward(battleId, pools[0]);
    }

    function test_ThreeOfFourReveals_MeetsQuorumAndOnlyRevealersEarn() public {
        uint64 battleId = _createAndLockBattle();
        LLMBattle.Battle memory locked = battle.getBattle(battleId);

        _commit(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _commit(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _commit(battleId, 2, LLMBattle.Choice.SideB, REASON_B, SALT_3);

        vm.warp(locked.commitDeadline);
        battle.openReveal(battleId);
        _reveal(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _reveal(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _reveal(battleId, 2, LLMBattle.Choice.SideB, REASON_B, SALT_3);

        vm.warp(locked.revealDeadline);
        battle.resolve(battleId);

        LLMBattle.Battle memory resolved = battle.getBattle(battleId);
        uint256 expectedJurorReward = JUROR_POOL / 3;
        assertEq(uint8(resolved.outcome), uint8(LLMBattle.Outcome.SideA));
        assertEq(resolved.revealedVotes, 3);
        assertEq(resolved.jurorRewardPerVote, expectedJurorReward);
        assertEq(battle.claimable(CONTENDER_A), WINNER_PRIZE);
        assertEq(battle.claimable(SPONSOR), JUROR_POOL % 3);

        vm.prank(voters[2]);
        battle.claimJurorReward(battleId, pools[2]);
        assertEq(battle.claimable(voters[2]), expectedJurorReward);

        vm.prank(voters[3]);
        vm.expectRevert(abi.encodeWithSelector(LLMBattle.NoJurorReward.selector, pools[3]));
        battle.claimJurorReward(battleId, pools[3]);
    }

    function test_Draw_SplitsWinnerPrizeAndPaysAllRevealingJurors() public {
        uint64 battleId = _createAndLockBattle();
        LLMBattle.Battle memory locked = battle.getBattle(battleId);

        _commit(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _commit(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _commit(battleId, 2, LLMBattle.Choice.SideB, REASON_B, SALT_3);
        _commit(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);

        vm.warp(locked.commitDeadline);
        battle.openReveal(battleId);
        _reveal(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _reveal(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _reveal(battleId, 2, LLMBattle.Choice.SideB, REASON_B, SALT_3);
        _reveal(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);
        battle.resolve(battleId);

        LLMBattle.Battle memory resolved = battle.getBattle(battleId);
        assertEq(uint8(resolved.outcome), uint8(LLMBattle.Outcome.Draw));
        assertEq(battle.claimable(CONTENDER_A), WINNER_PRIZE / 2);
        assertEq(battle.claimable(CONTENDER_B), WINNER_PRIZE / 2);
        assertEq(resolved.jurorRewardPerVote, 1 ether);
    }

    function test_ValidatorVoterIsSnapshottedWhenTranscriptLocks() public {
        uint64 battleId = _createAndLockBattle();
        address replacementVoter = address(0x999);
        staking.setPoolVoter(pools[0], replacementVoter);

        bytes32 commitment = battle.computeCommitment(battleId, pools[0], LLMBattle.Choice.SideA, REASON_A, SALT_1);

        vm.prank(replacementVoter);
        vm.expectRevert(abi.encodeWithSelector(LLMBattle.NotJuryVoter.selector, pools[0], voters[0], replacementVoter));
        battle.commitVote(battleId, pools[0], commitment);

        vm.prank(voters[0]);
        battle.commitVote(battleId, pools[0], commitment);
        assertEq(battle.voteCommitments(battleId, pools[0]), commitment);
    }

    function test_RevertWhen_RevealDoesNotMatchCommitment() public {
        uint64 battleId = _createAndLockBattle();
        LLMBattle.Battle memory locked = battle.getBattle(battleId);
        _commit(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);

        vm.warp(locked.commitDeadline);
        battle.openReveal(battleId);

        vm.prank(voters[0]);
        vm.expectRevert(LLMBattle.InvalidVoteReveal.selector);
        battle.revealVote(battleId, pools[0], LLMBattle.Choice.SideB, REASON_B, SALT_1);
    }

    function test_ArgumentRoundsRequireBothPreviousArguments() public {
        uint64 battleId = _createBattle();

        vm.prank(CONTENDER_A);
        battle.submitArgument(battleId, LLMBattle.Round.Opening, "Rust opening");

        vm.prank(CONTENDER_A);
        vm.expectRevert(abi.encodeWithSelector(LLMBattle.PreviousRoundIncomplete.selector, LLMBattle.Round.Rebuttal));
        battle.submitArgument(battleId, LLMBattle.Round.Rebuttal, "Rust premature rebuttal");

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(LLMBattle.NotParticipant.selector, OUTSIDER));
        battle.submitArgument(battleId, LLMBattle.Round.Opening, "Outsider opening");
    }

    function test_RevertWhen_ParticipantAppearsOnBothTeams() public {
        LLMBattle.CreateBattleParams memory params = _singleContenderParams();
        params.teamB[0] = CONTENDER_A;
        params.speakersB = [CONTENDER_A, CONTENDER_A, CONTENDER_A];

        vm.prank(SPONSOR);
        vm.expectRevert(abi.encodeWithSelector(LLMBattle.DuplicateParticipant.selector, CONTENDER_A));
        battle.createBattle{ value: WINNER_PRIZE + JUROR_POOL }(params);
    }

    function test_RevertWhen_RoundSpeakerIsNotOnItsTeam() public {
        LLMBattle.CreateBattleParams memory params = _singleContenderParams();
        params.speakersA[1] = OUTSIDER;

        vm.prank(SPONSOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                LLMBattle.InvalidRoundSpeaker.selector, LLMBattle.Choice.SideA, LLMBattle.Round.Rebuttal, OUTSIDER
            )
        );
        battle.createBattle{ value: WINNER_PRIZE + JUROR_POOL }(params);
    }

    function test_RevertWhen_TeamIsEmpty() public {
        LLMBattle.CreateBattleParams memory params = _singleContenderParams();
        params.teamA = new address[](0);

        vm.prank(SPONSOR);
        vm.expectRevert(abi.encodeWithSelector(LLMBattle.TeamIsEmpty.selector, LLMBattle.Choice.SideA));
        battle.createBattle{ value: WINNER_PRIZE + JUROR_POOL }(params);
    }

    function test_RevertWhen_TeamExceedsMaximum() public {
        LLMBattle.CreateBattleParams memory params = _singleContenderParams();
        params.teamA = new address[](9);
        for (uint256 i; i < params.teamA.length; ++i) {
            params.teamA[i] = address(uint160(i + 1));
        }

        vm.prank(SPONSOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                LLMBattle.TeamTooLarge.selector, LLMBattle.Choice.SideA, uint256(9), battle.MAX_TEAM_SIZE()
            )
        );
        battle.createBattle{ value: WINNER_PRIZE + JUROR_POOL }(params);
    }

    function test_WinningTeamSplit_RemainderReturnsToCreator() public {
        LLMBattle.CreateBattleParams memory params = _singleContenderParams();
        params.teamA = new address[](3);
        params.teamA[0] = CONTENDER_A;
        params.teamA[1] = TEAM_A_2;
        params.teamA[2] = OUTSIDER;
        params.winnerPrize = 10 wei;

        vm.prank(SPONSOR);
        uint64 battleId = battle.createBattle{ value: JUROR_POOL + 10 wei }(params);
        _submitCompleteDebate(battleId);
        battle.lockTranscript(battleId);
        LLMBattle.Battle memory locked = battle.getBattle(battleId);

        _commit(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _commit(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _commit(battleId, 2, LLMBattle.Choice.SideA, REASON_A, SALT_3);
        _commit(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);
        vm.warp(locked.commitDeadline);
        battle.openReveal(battleId);
        _reveal(battleId, 0, LLMBattle.Choice.SideA, REASON_A, SALT_1);
        _reveal(battleId, 1, LLMBattle.Choice.SideA, REASON_A, SALT_2);
        _reveal(battleId, 2, LLMBattle.Choice.SideA, REASON_A, SALT_3);
        _reveal(battleId, 3, LLMBattle.Choice.SideB, REASON_B, SALT_4);
        battle.resolve(battleId);

        assertEq(battle.claimable(CONTENDER_A), 3 wei);
        assertEq(battle.claimable(TEAM_A_2), 3 wei);
        assertEq(battle.claimable(OUTSIDER), 3 wei);
        assertEq(battle.claimable(SPONSOR), 1 wei);
    }

    function test_ExpiredUnlockedBattleCanAlwaysBeCancelled() public {
        uint64 battleId = _createBattle();
        _submitCompleteDebate(battleId);
        LLMBattle.Battle memory created = battle.getBattle(battleId);

        // Even a complete transcript cannot strand escrow if nobody locks it in time.
        vm.warp(created.debateDeadline);
        battle.cancelExpiredBattle(battleId);

        LLMBattle.Battle memory cancelled = battle.getBattle(battleId);
        assertEq(uint8(cancelled.phase), uint8(LLMBattle.Phase.Resolved));
        assertEq(uint8(cancelled.outcome), uint8(LLMBattle.Outcome.Cancelled));
        assertEq(battle.claimable(SPONSOR), WINNER_PRIZE + JUROR_POOL);
    }

    function _createBattle() private returns (uint64 battleId) {
        LLMBattle.CreateBattleParams memory params = _singleContenderParams();
        vm.prank(SPONSOR);
        battleId = battle.createBattle{ value: WINNER_PRIZE + JUROR_POOL }(params);
    }

    function _createTwoVersusThreeBattle() private returns (uint64 battleId) {
        LLMBattle.CreateBattleParams memory params;
        params.teamA = new address[](2);
        params.teamA[0] = CONTENDER_A;
        params.teamA[1] = TEAM_A_2;
        params.teamB = new address[](3);
        params.teamB[0] = CONTENDER_B;
        params.teamB[1] = TEAM_B_2;
        params.teamB[2] = TEAM_B_3;
        params.speakersA = [CONTENDER_A, TEAM_A_2, CONTENDER_A];
        params.speakersB = [CONTENDER_B, TEAM_B_2, TEAM_B_3];
        params.question = "Which is the best systems programming language of the 2020s?";
        params.positionA = "Rust";
        params.positionB = "Zig";
        params.winnerPrize = WINNER_PRIZE;
        params.jurorPool = JUROR_POOL;

        vm.prank(SPONSOR);
        battleId = battle.createBattle{ value: WINNER_PRIZE + JUROR_POOL }(params);
    }

    function _singleContenderParams() private pure returns (LLMBattle.CreateBattleParams memory params) {
        params.teamA = new address[](1);
        params.teamA[0] = CONTENDER_A;
        params.teamB = new address[](1);
        params.teamB[0] = CONTENDER_B;
        params.speakersA = [CONTENDER_A, CONTENDER_A, CONTENDER_A];
        params.speakersB = [CONTENDER_B, CONTENDER_B, CONTENDER_B];
        params.question = "Which is the best systems programming language of the 2020s?";
        params.positionA = "Rust";
        params.positionB = "Zig";
        params.winnerPrize = WINNER_PRIZE;
        params.jurorPool = JUROR_POOL;
    }

    function _createAndLockBattle() private returns (uint64 battleId) {
        battleId = _createBattle();
        _submitCompleteDebate(battleId);
        battle.lockTranscript(battleId);
    }

    function _submitCompleteDebate(
        uint64 battleId
    ) private {
        vm.prank(CONTENDER_A);
        battle.submitArgument(battleId, LLMBattle.Round.Opening, "Rust opening: memory safety without a GC.");
        vm.prank(CONTENDER_B);
        battle.submitArgument(battleId, LLMBattle.Round.Opening, "Zig opening: explicit control and simplicity.");

        vm.prank(CONTENDER_A);
        battle.submitArgument(battleId, LLMBattle.Round.Rebuttal, "Rust rebuttal: safety scales to large teams.");
        vm.prank(CONTENDER_B);
        battle.submitArgument(
            battleId, LLMBattle.Round.Rebuttal, "Zig rebuttal: simpler semantics improve auditability."
        );

        vm.prank(CONTENDER_A);
        battle.submitArgument(battleId, LLMBattle.Round.Finisher, "Rust finisher: ecosystem plus correctness wins.");
        vm.prank(CONTENDER_B);
        battle.submitArgument(battleId, LLMBattle.Round.Finisher, "Zig finisher: transparent tooling wins.");
    }

    function _submitTwoVersusThreeDebate(
        uint64 battleId
    ) private {
        vm.prank(CONTENDER_A);
        battle.submitArgument(battleId, LLMBattle.Round.Opening, "Rust speaker one opens for the team.");
        vm.prank(CONTENDER_B);
        battle.submitArgument(battleId, LLMBattle.Round.Opening, "Zig speaker one opens for the team.");

        vm.prank(TEAM_A_2);
        battle.submitArgument(battleId, LLMBattle.Round.Rebuttal, "Rust speaker two handles the rebuttal.");
        vm.prank(TEAM_B_2);
        battle.submitArgument(battleId, LLMBattle.Round.Rebuttal, "Zig speaker two handles the rebuttal.");

        vm.prank(CONTENDER_A);
        battle.submitArgument(battleId, LLMBattle.Round.Finisher, "Rust speaker one returns to finish.");
        vm.prank(TEAM_B_3);
        battle.submitArgument(battleId, LLMBattle.Round.Finisher, "Zig speaker three closes the debate.");
    }

    function _commit(
        uint64 battleId,
        uint256 validatorIndex,
        LLMBattle.Choice choice,
        bytes32 reasonHash,
        bytes32 salt
    ) private {
        bytes32 commitment = battle.computeCommitment(battleId, pools[validatorIndex], choice, reasonHash, salt);
        vm.prank(voters[validatorIndex]);
        battle.commitVote(battleId, pools[validatorIndex], commitment);
    }

    function _reveal(
        uint64 battleId,
        uint256 validatorIndex,
        LLMBattle.Choice choice,
        bytes32 reasonHash,
        bytes32 salt
    ) private {
        vm.prank(voters[validatorIndex]);
        battle.revealVote(battleId, pools[validatorIndex], choice, reasonHash, salt);
    }
}
