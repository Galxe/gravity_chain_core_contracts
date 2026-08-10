// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ValidatorConsensusInfo } from "../foundation/Types.sol";
import { IStaking } from "../staking/IStaking.sol";
import { IValidatorManagement } from "../staking/IValidatorManagement.sol";

/// @title LLMBattle
/// @author Gravity Team
/// @notice Proof-of-concept debate arena judged by Gravity's active validators.
/// @dev This is an application-layer contract. It snapshots the active validator set and each
///      validator pool's delegated voter when a completed transcript is locked. It does not
///      participate in block consensus and does not use the native oracle request queue.
contract LLMBattle {
    // ========================================================================
    // TYPES
    // ========================================================================

    enum Phase {
        None,
        Debate,
        Commit,
        Reveal,
        Resolved
    }

    enum Outcome {
        Pending,
        SideA,
        SideB,
        Draw,
        NoQuorum,
        Cancelled
    }

    enum Choice {
        None,
        SideA,
        SideB
    }

    enum Round {
        Opening,
        Rebuttal,
        Finisher
    }

    struct Battle {
        address creator;
        uint64 debateDeadline;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint64 validatorEpoch;
        uint16 validatorCount;
        uint16 quorum;
        uint16 committedVotes;
        uint16 revealedVotes;
        uint16 votesA;
        uint16 votesB;
        uint8 teamSizeA;
        uint8 teamSizeB;
        Phase phase;
        Outcome outcome;
        uint256 winnerPrize;
        uint256 jurorPool;
        uint256 jurorRewardPerVote;
        bytes32 transcriptRoot;
        string question;
        string positionA;
        string positionB;
    }

    struct CreateBattleParams {
        address[] teamA;
        address[] teamB;
        address[3] speakersA;
        address[3] speakersB;
        string question;
        string positionA;
        string positionB;
        uint256 winnerPrize;
        uint256 jurorPool;
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    uint64 public constant DEBATE_WINDOW = 3 days;
    uint64 public constant COMMIT_WINDOW = 1 days;
    uint64 public constant REVEAL_WINDOW = 1 days;

    uint256 public constant MAX_QUESTION_BYTES = 1024;
    uint256 public constant MAX_POSITION_BYTES = 512;
    uint256 public constant MAX_ARGUMENT_BYTES = 4096;
    uint256 public constant MAX_JURY_SIZE = 128;
    uint256 public constant MAX_TEAM_SIZE = 8;

    // ========================================================================
    // IMMUTABLE DEPENDENCIES
    // ========================================================================

    IValidatorManagement public immutable validatorManagement;
    IStaking public immutable staking;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Next battle ID. ID zero is reserved as a not-found sentinel.
    uint64 public nextBattleId = 1;

    mapping(uint64 battleId => Battle battle) private _battles;
    mapping(uint64 battleId => mapping(Choice side => address[] members)) private _teamMembers;
    mapping(uint64 battleId => mapping(Choice side => mapping(Round round => bytes32 contentHash))) private
        _argumentHashes;
    mapping(uint64 battleId => address[] pools) private _juryPools;

    /// @notice A participant's immutable side for a battle. Choice.None means not registered.
    mapping(uint64 battleId => mapping(address participant => Choice side)) public participantSide;
    /// @notice The participant assigned to speak for a side in a round.
    mapping(uint64 battleId => mapping(Choice side => mapping(Round round => address speaker))) public roundSpeaker;
    /// @notice The participant who actually submitted a side's argument in a round.
    mapping(uint64 battleId => mapping(Choice side => mapping(Round round => address author))) public argumentAuthor;

    /// @notice Snapshotted delegated voter for each validator pool in a battle.
    mapping(uint64 battleId => mapping(address pool => address voter)) public juryVoter;
    mapping(uint64 battleId => mapping(address pool => bytes32 commitment)) public voteCommitments;
    mapping(uint64 battleId => mapping(address pool => bool revealed)) public voteRevealed;
    mapping(uint64 battleId => mapping(address pool => bool claimed)) public jurorRewardClaimed;

    /// @notice ETH available for an account to withdraw.
    mapping(address account => uint256 amount) public claimable;

    // ========================================================================
    // EVENTS
    // ========================================================================

    event BattleCreated(
        uint64 indexed battleId,
        address indexed creator,
        uint8 teamSizeA,
        uint8 teamSizeB,
        uint256 winnerPrize,
        uint256 jurorPool,
        uint64 debateDeadline,
        string question,
        string positionA,
        string positionB
    );
    event TeamConfigured(uint64 indexed battleId, Choice indexed side, address[] members, address[3] roundSpeakers);
    event ArgumentSubmitted(
        uint64 indexed battleId,
        Choice indexed side,
        Round indexed round,
        address author,
        bytes32 contentHash,
        bytes32 transcriptRoot,
        string content
    );
    event TranscriptLocked(
        uint64 indexed battleId,
        bytes32 indexed transcriptRoot,
        uint64 indexed validatorEpoch,
        uint16 validatorCount,
        uint16 quorum,
        uint64 commitDeadline,
        uint64 revealDeadline
    );
    event VoteCommitted(uint64 indexed battleId, address indexed pool, bytes32 commitment);
    event VoteRevealed(uint64 indexed battleId, address indexed pool, Choice indexed choice, bytes32 reasonHash);
    event BattleResolved(
        uint64 indexed battleId,
        Outcome indexed outcome,
        uint16 votesA,
        uint16 votesB,
        uint16 revealedVotes,
        uint256 jurorRewardPerVote
    );
    event JurorRewardClaimed(uint64 indexed battleId, address indexed pool, address indexed voter, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error ZeroAddress();
    error TextIsEmpty();
    error TextTooLong(uint256 length, uint256 maximum);
    error TeamIsEmpty(Choice side);
    error TeamTooLarge(Choice side, uint256 size, uint256 maximum);
    error DuplicateParticipant(address participant);
    error InvalidRoundSpeaker(Choice side, Round round, address speaker);
    error EmptyRewardPool();
    error IncorrectFunding(uint256 expected, uint256 actual);
    error BattleNotFound(uint64 battleId);
    error WrongPhase(uint64 battleId, Phase expected, Phase actual);
    error DeadlinePassed(uint64 deadline);
    error DeadlineNotReached(uint64 deadline);
    error NotParticipant(address caller);
    error NotRoundSpeaker(Choice side, Round round, address expected, address actual);
    error ArgumentAlreadySubmitted(Choice side, Round round);
    error PreviousRoundIncomplete(Round round);
    error TranscriptIncomplete();
    error InvalidJurySize(uint256 size);
    error InvalidJuryMember(address pool, address voter);
    error DuplicateJuryMember(address pool);
    error NotJuryVoter(address pool, address expected, address actual);
    error EmptyCommitment();
    error VoteAlreadyCommitted(address pool);
    error VoteNotCommitted(address pool);
    error VoteAlreadyRevealed(address pool);
    error InvalidVoteReveal();
    error InvalidChoice(Choice choice);
    error ResolutionNotReady();
    error NoJurorReward(address pool);
    error JurorRewardAlreadyClaimed(address pool);
    error NothingToWithdraw();
    error WithdrawalFailed();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    constructor(
        address validatorManagement_,
        address staking_
    ) {
        if (validatorManagement_ == address(0) || staking_ == address(0)) revert ZeroAddress();
        validatorManagement = IValidatorManagement(validatorManagement_);
        staking = IStaking(staking_);
    }

    // ========================================================================
    // BATTLE LIFECYCLE
    // ========================================================================

    /// @notice Create and fund a battle between two immutable teams.
    /// @dev Each side has one designated speaker per round. A speaker may cover multiple rounds.
    function createBattle(
        CreateBattleParams calldata params
    ) external payable returns (uint64 battleId) {
        if (params.winnerPrize == 0 || params.jurorPool == 0) revert EmptyRewardPool();

        _checkText(params.question, MAX_QUESTION_BYTES);
        _checkText(params.positionA, MAX_POSITION_BYTES);
        _checkText(params.positionB, MAX_POSITION_BYTES);

        uint256 expectedFunding = params.winnerPrize + params.jurorPool;
        if (msg.value != expectedFunding) revert IncorrectFunding(expectedFunding, msg.value);

        battleId = nextBattleId++;
        _configureTeam(battleId, Choice.SideA, params.teamA, params.speakersA);
        _configureTeam(battleId, Choice.SideB, params.teamB, params.speakersB);

        Battle storage battle = _battles[battleId];
        battle.creator = msg.sender;
        battle.debateDeadline = uint64(block.timestamp) + DEBATE_WINDOW;
        // Safe because each team is bounded by MAX_TEAM_SIZE (8).
        // forge-lint: disable-next-line(unsafe-typecast)
        battle.teamSizeA = uint8(params.teamA.length);
        // forge-lint: disable-next-line(unsafe-typecast)
        battle.teamSizeB = uint8(params.teamB.length);
        battle.phase = Phase.Debate;
        battle.winnerPrize = params.winnerPrize;
        battle.jurorPool = params.jurorPool;
        battle.question = params.question;
        battle.positionA = params.positionA;
        battle.positionB = params.positionB;

        emit BattleCreated(
            battleId,
            msg.sender,
            battle.teamSizeA,
            battle.teamSizeB,
            params.winnerPrize,
            params.jurorPool,
            battle.debateDeadline,
            params.question,
            params.positionA,
            params.positionB
        );
        emit TeamConfigured(battleId, Choice.SideA, params.teamA, params.speakersA);
        emit TeamConfigured(battleId, Choice.SideB, params.teamB, params.speakersB);
    }

    /// @notice Submit a team's argument through its designated speaker for the round.
    /// @dev The full text is recorded in the event log; its hash is stored in contract state.
    function submitArgument(
        uint64 battleId,
        Round round,
        string calldata content
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Debate);
        if (block.timestamp >= battle.debateDeadline) revert DeadlinePassed(battle.debateDeadline);
        _checkText(content, MAX_ARGUMENT_BYTES);

        Choice side = participantSide[battleId][msg.sender];
        if (side == Choice.None) revert NotParticipant(msg.sender);
        address expectedSpeaker = roundSpeaker[battleId][side][round];
        if (msg.sender != expectedSpeaker) revert NotRoundSpeaker(side, round, expectedSpeaker, msg.sender);

        if (_argumentHashes[battleId][side][round] != bytes32(0)) {
            revert ArgumentAlreadySubmitted(side, round);
        }
        if (round != Round.Opening && !_isRoundComplete(battleId, Round(uint8(round) - 1))) {
            revert PreviousRoundIncomplete(round);
        }

        bytes32 contentHash = keccak256(bytes(content));
        _argumentHashes[battleId][side][round] = contentHash;
        argumentAuthor[battleId][side][round] = msg.sender;
        battle.transcriptRoot = keccak256(abi.encode(battle.transcriptRoot, battleId, side, round, contentHash));

        emit ArgumentSubmitted(battleId, side, round, msg.sender, contentHash, battle.transcriptRoot, content);
    }

    /// @notice Lock a completed transcript and snapshot the current active-validator jury.
    function lockTranscript(
        uint64 battleId
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Debate);
        if (block.timestamp >= battle.debateDeadline) revert DeadlinePassed(battle.debateDeadline);
        if (!_hasCompleteTranscript(battleId)) revert TranscriptIncomplete();

        // Set the phase before trusted system-contract calls so re-entry cannot snapshot twice.
        battle.phase = Phase.Commit;
        ValidatorConsensusInfo[] memory validators = validatorManagement.getActiveValidators();
        uint256 validatorCount = validators.length;
        if (validatorCount == 0 || validatorCount > MAX_JURY_SIZE) revert InvalidJurySize(validatorCount);

        battle.validatorEpoch = validatorManagement.getCurrentEpoch();
        // Safe because validatorCount is bounded by MAX_JURY_SIZE (128) above.
        // forge-lint: disable-next-line(unsafe-typecast)
        battle.validatorCount = uint16(validatorCount);
        // Two-thirds attendance, rounded up. Each validator has one jury vote.
        battle.quorum = uint16((2 * validatorCount + 2) / 3);
        battle.commitDeadline = uint64(block.timestamp) + COMMIT_WINDOW;
        battle.revealDeadline = battle.commitDeadline + REVEAL_WINDOW;

        for (uint256 i; i < validatorCount; ++i) {
            address pool = validators[i].validator;
            address voter = pool == address(0) ? address(0) : staking.getPoolVoter(pool);
            if (pool == address(0) || voter == address(0)) revert InvalidJuryMember(pool, voter);
            if (juryVoter[battleId][pool] != address(0)) revert DuplicateJuryMember(pool);

            juryVoter[battleId][pool] = voter;
            _juryPools[battleId].push(pool);
        }

        emit TranscriptLocked(
            battleId,
            battle.transcriptRoot,
            battle.validatorEpoch,
            battle.validatorCount,
            battle.quorum,
            battle.commitDeadline,
            battle.revealDeadline
        );
    }

    /// @notice Cancel an unlocked battle after its debate window and refund its creator.
    function cancelExpiredBattle(
        uint64 battleId
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Debate);
        if (block.timestamp < battle.debateDeadline) revert DeadlineNotReached(battle.debateDeadline);
        battle.phase = Phase.Resolved;
        battle.outcome = Outcome.Cancelled;
        claimable[battle.creator] += battle.winnerPrize + battle.jurorPool;

        emit BattleResolved(battleId, Outcome.Cancelled, 0, 0, 0, 0);
    }

    // ========================================================================
    // VALIDATOR VOTING
    // ========================================================================

    /// @notice Commit a validator jury vote during the hidden-vote window.
    function commitVote(
        uint64 battleId,
        address pool,
        bytes32 commitment
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Commit);
        if (block.timestamp >= battle.commitDeadline) revert DeadlinePassed(battle.commitDeadline);
        _requireJuryVoter(battleId, pool);
        if (commitment == bytes32(0)) revert EmptyCommitment();
        if (voteCommitments[battleId][pool] != bytes32(0)) revert VoteAlreadyCommitted(pool);

        voteCommitments[battleId][pool] = commitment;
        ++battle.committedVotes;
        emit VoteCommitted(battleId, pool, commitment);
    }

    /// @notice Advance a battle from commit to reveal after the commit deadline.
    function openReveal(
        uint64 battleId
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Commit);
        if (block.timestamp < battle.commitDeadline) revert DeadlineNotReached(battle.commitDeadline);
        battle.phase = Phase.Reveal;
    }

    /// @notice Reveal a previously committed jury vote.
    function revealVote(
        uint64 battleId,
        address pool,
        Choice choice,
        bytes32 reasonHash,
        bytes32 salt
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Reveal);
        if (block.timestamp >= battle.revealDeadline) revert DeadlinePassed(battle.revealDeadline);
        _requireJuryVoter(battleId, pool);
        if (choice != Choice.SideA && choice != Choice.SideB) revert InvalidChoice(choice);

        bytes32 commitment = voteCommitments[battleId][pool];
        if (commitment == bytes32(0)) revert VoteNotCommitted(pool);
        if (voteRevealed[battleId][pool]) revert VoteAlreadyRevealed(pool);
        if (commitment != computeCommitment(battleId, pool, choice, reasonHash, salt)) revert InvalidVoteReveal();

        voteRevealed[battleId][pool] = true;
        ++battle.revealedVotes;
        if (choice == Choice.SideA) {
            ++battle.votesA;
        } else {
            ++battle.votesB;
        }

        emit VoteRevealed(battleId, pool, choice, reasonHash);
    }

    /// @notice Resolve a vote after the reveal deadline, or early after every juror reveals.
    function resolve(
        uint64 battleId
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Reveal);
        if (block.timestamp < battle.revealDeadline && battle.revealedVotes != battle.validatorCount) {
            revert ResolutionNotReady();
        }

        battle.phase = Phase.Resolved;

        if (battle.revealedVotes < battle.quorum) {
            battle.outcome = Outcome.NoQuorum;
            claimable[battle.creator] += battle.winnerPrize + battle.jurorPool;
        } else {
            _allocateValidResult(battleId, battle);
        }

        emit BattleResolved(
            battleId, battle.outcome, battle.votesA, battle.votesB, battle.revealedVotes, battle.jurorRewardPerVote
        );
    }

    /// @notice Move one revealed juror's share into its snapshotted voter's withdrawable balance.
    function claimJurorReward(
        uint64 battleId,
        address pool
    ) external {
        Battle storage battle = _requireBattle(battleId);
        _requirePhase(battleId, battle, Phase.Resolved);
        _requireJuryVoter(battleId, pool);
        if (!voteRevealed[battleId][pool] || battle.jurorRewardPerVote == 0) revert NoJurorReward(pool);
        if (jurorRewardClaimed[battleId][pool]) revert JurorRewardAlreadyClaimed(pool);

        jurorRewardClaimed[battleId][pool] = true;
        claimable[msg.sender] += battle.jurorRewardPerVote;
        emit JurorRewardClaimed(battleId, pool, msg.sender, battle.jurorRewardPerVote);
    }

    /// @notice Withdraw all ETH currently credited to the caller.
    function withdraw() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        claimable[msg.sender] = 0;
        (bool success,) = payable(msg.sender).call{ value: amount }("");
        if (!success) revert WithdrawalFailed();

        emit Withdrawal(msg.sender, amount);
    }

    // ========================================================================
    // VIEWS
    // ========================================================================

    function getBattle(
        uint64 battleId
    ) external view returns (Battle memory) {
        return _requireBattle(battleId);
    }

    function getArgumentHash(
        uint64 battleId,
        Choice side,
        Round round
    ) external view returns (bytes32) {
        _requireBattle(battleId);
        return _argumentHashes[battleId][side][round];
    }

    function getTeamMembers(
        uint64 battleId,
        Choice side
    ) external view returns (address[] memory) {
        _requireBattle(battleId);
        _checkSide(side);
        return _teamMembers[battleId][side];
    }

    function getJuryPools(
        uint64 battleId
    ) external view returns (address[] memory) {
        _requireBattle(battleId);
        return _juryPools[battleId];
    }

    /// @notice Compute the domain-separated commitment for a jury vote.
    function computeCommitment(
        uint64 battleId,
        address pool,
        Choice choice,
        bytes32 reasonHash,
        bytes32 salt
    ) public view returns (bytes32) {
        Battle storage battle = _requireBattle(battleId);
        return keccak256(
            abi.encode(block.chainid, address(this), battleId, battle.transcriptRoot, pool, choice, reasonHash, salt)
        );
    }

    // ========================================================================
    // INTERNAL HELPERS
    // ========================================================================

    function _allocateValidResult(
        uint64 battleId,
        Battle storage battle
    ) internal {
        if (battle.votesA > battle.votesB) {
            battle.outcome = Outcome.SideA;
            _creditTeam(battleId, Choice.SideA, battle.winnerPrize, battle.creator);
        } else if (battle.votesB > battle.votesA) {
            battle.outcome = Outcome.SideB;
            _creditTeam(battleId, Choice.SideB, battle.winnerPrize, battle.creator);
        } else {
            battle.outcome = Outcome.Draw;
            uint256 halfPrize = battle.winnerPrize / 2;
            _creditTeam(battleId, Choice.SideA, halfPrize, battle.creator);
            _creditTeam(battleId, Choice.SideB, halfPrize, battle.creator);
            claimable[battle.creator] += battle.winnerPrize - (2 * halfPrize);
        }

        battle.jurorRewardPerVote = battle.jurorPool / battle.revealedVotes;
        claimable[battle.creator] += battle.jurorPool % battle.revealedVotes;
    }

    function _configureTeam(
        uint64 battleId,
        Choice side,
        address[] calldata members,
        address[3] calldata speakers
    ) internal {
        uint256 teamSize = members.length;
        if (teamSize == 0) revert TeamIsEmpty(side);
        if (teamSize > MAX_TEAM_SIZE) revert TeamTooLarge(side, teamSize, MAX_TEAM_SIZE);

        for (uint256 i; i < teamSize; ++i) {
            address member = members[i];
            if (member == address(0)) revert ZeroAddress();
            if (participantSide[battleId][member] != Choice.None) revert DuplicateParticipant(member);
            participantSide[battleId][member] = side;
            _teamMembers[battleId][side].push(member);
        }

        for (uint256 i; i < speakers.length; ++i) {
            address speaker = speakers[i];
            // forge-lint: disable-next-line(unsafe-typecast)
            Round round = Round(uint8(i));
            if (participantSide[battleId][speaker] != side) revert InvalidRoundSpeaker(side, round, speaker);
            roundSpeaker[battleId][side][round] = speaker;
        }
    }

    function _creditTeam(
        uint64 battleId,
        Choice side,
        uint256 amount,
        address remainderRecipient
    ) internal {
        address[] storage members = _teamMembers[battleId][side];
        uint256 share = amount / members.length;
        for (uint256 i; i < members.length; ++i) {
            claimable[members[i]] += share;
        }
        claimable[remainderRecipient] += amount % members.length;
    }

    function _checkSide(
        Choice side
    ) internal pure {
        if (side != Choice.SideA && side != Choice.SideB) revert InvalidChoice(side);
    }

    function _checkText(
        string calldata text,
        uint256 maximum
    ) internal pure {
        uint256 length = bytes(text).length;
        if (length == 0) revert TextIsEmpty();
        if (length > maximum) revert TextTooLong(length, maximum);
    }

    function _requireBattle(
        uint64 battleId
    ) internal view returns (Battle storage battle) {
        battle = _battles[battleId];
        if (battle.phase == Phase.None) revert BattleNotFound(battleId);
    }

    function _requirePhase(
        uint64 battleId,
        Battle storage battle,
        Phase expected
    ) internal view {
        if (battle.phase != expected) revert WrongPhase(battleId, expected, battle.phase);
    }

    function _requireJuryVoter(
        uint64 battleId,
        address pool
    ) internal view {
        address expected = juryVoter[battleId][pool];
        if (expected == address(0) || msg.sender != expected) {
            revert NotJuryVoter(pool, expected, msg.sender);
        }
    }

    function _isRoundComplete(
        uint64 battleId,
        Round round
    ) internal view returns (bool) {
        return _argumentHashes[battleId][Choice.SideA][round] != bytes32(0)
            && _argumentHashes[battleId][Choice.SideB][round] != bytes32(0);
    }

    function _hasCompleteTranscript(
        uint64 battleId
    ) internal view returns (bool) {
        return _isRoundComplete(battleId, Round.Opening) && _isRoundComplete(battleId, Round.Rebuttal)
            && _isRoundComplete(battleId, Round.Finisher);
    }
}
