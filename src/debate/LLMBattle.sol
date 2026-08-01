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
        address contenderA;
        address contenderB;
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
    mapping(uint64 battleId => mapping(Choice side => mapping(Round round => bytes32 contentHash))) private
        _argumentHashes;
    mapping(uint64 battleId => address[] pools) private _juryPools;

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
        address indexed contenderA,
        address contenderB,
        uint256 winnerPrize,
        uint256 jurorPool,
        uint64 debateDeadline,
        string question,
        string positionA,
        string positionB
    );
    event ArgumentSubmitted(
        uint64 indexed battleId,
        Choice indexed side,
        Round indexed round,
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
    error SameContender();
    error EmptyRewardPool();
    error IncorrectFunding(uint256 expected, uint256 actual);
    error BattleNotFound(uint64 battleId);
    error WrongPhase(uint64 battleId, Phase expected, Phase actual);
    error DeadlinePassed(uint64 deadline);
    error DeadlineNotReached(uint64 deadline);
    error UnauthorizedContender(address caller);
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

    /// @notice Create and fund a battle between two contenders.
    function createBattle(
        address contenderA,
        address contenderB,
        string calldata question,
        string calldata positionA,
        string calldata positionB,
        uint256 winnerPrize,
        uint256 jurorPool
    ) external payable returns (uint64 battleId) {
        if (contenderA == address(0) || contenderB == address(0)) revert ZeroAddress();
        if (contenderA == contenderB) revert SameContender();
        if (winnerPrize == 0 || jurorPool == 0) revert EmptyRewardPool();

        _checkText(question, MAX_QUESTION_BYTES);
        _checkText(positionA, MAX_POSITION_BYTES);
        _checkText(positionB, MAX_POSITION_BYTES);

        uint256 expectedFunding = winnerPrize + jurorPool;
        if (msg.value != expectedFunding) revert IncorrectFunding(expectedFunding, msg.value);

        battleId = nextBattleId++;
        Battle storage battle = _battles[battleId];
        battle.creator = msg.sender;
        battle.contenderA = contenderA;
        battle.contenderB = contenderB;
        battle.debateDeadline = uint64(block.timestamp) + DEBATE_WINDOW;
        battle.phase = Phase.Debate;
        battle.winnerPrize = winnerPrize;
        battle.jurorPool = jurorPool;
        battle.question = question;
        battle.positionA = positionA;
        battle.positionB = positionB;

        emit BattleCreated(
            battleId,
            msg.sender,
            contenderA,
            contenderB,
            winnerPrize,
            jurorPool,
            battle.debateDeadline,
            question,
            positionA,
            positionB
        );
    }

    /// @notice Submit one contender's argument for a debate round.
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

        Choice side;
        if (msg.sender == battle.contenderA) {
            side = Choice.SideA;
        } else if (msg.sender == battle.contenderB) {
            side = Choice.SideB;
        } else {
            revert UnauthorizedContender(msg.sender);
        }

        if (_argumentHashes[battleId][side][round] != bytes32(0)) {
            revert ArgumentAlreadySubmitted(side, round);
        }
        if (round != Round.Opening && !_isRoundComplete(battleId, Round(uint8(round) - 1))) {
            revert PreviousRoundIncomplete(round);
        }

        bytes32 contentHash = keccak256(bytes(content));
        _argumentHashes[battleId][side][round] = contentHash;
        battle.transcriptRoot = keccak256(abi.encode(battle.transcriptRoot, battleId, side, round, contentHash));

        emit ArgumentSubmitted(battleId, side, round, contentHash, battle.transcriptRoot, content);
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
            _allocateValidResult(battle);
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
        Battle storage battle
    ) internal {
        if (battle.votesA > battle.votesB) {
            battle.outcome = Outcome.SideA;
            claimable[battle.contenderA] += battle.winnerPrize;
        } else if (battle.votesB > battle.votesA) {
            battle.outcome = Outcome.SideB;
            claimable[battle.contenderB] += battle.winnerPrize;
        } else {
            battle.outcome = Outcome.Draw;
            uint256 halfPrize = battle.winnerPrize / 2;
            claimable[battle.contenderA] += halfPrize;
            claimable[battle.contenderB] += halfPrize;
            claimable[battle.creator] += battle.winnerPrize - (2 * halfPrize);
        }

        battle.jurorRewardPerVote = battle.jurorPool / battle.revealedVotes;
        claimable[battle.creator] += battle.jurorPool % battle.revealedVotes;
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
