// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "forge-std/console.sol";
import { LLMBattle } from "src/debate/LLMBattle.sol";
import { LLMBattleDemoBase } from "./LLMBattleDemoBase.sol";

/// @notice Creates, funds, fills, and locks one configurable local debate.
contract CreateLLMBattleLocal is LLMBattleDemoBase {
    function run() external returns (uint64 battleId) {
        Deployment memory deployment = _loadDeployment();
        LLMBattle llmBattle = LLMBattle(deployment.llmBattle);

        uint256 sponsorKey = vm.envUint("LLM_BATTLE_SPONSOR_KEY");
        uint256 contenderAKey = vm.envUint("LLM_BATTLE_CONTENDER_A_KEY");
        uint256 contenderBKey = vm.envUint("LLM_BATTLE_CONTENDER_B_KEY");
        require(vm.addr(sponsorKey) == deployment.sponsor, "CreateLLMBattleLocal: sponsor key mismatch");
        require(vm.addr(contenderAKey) == deployment.contenderA, "CreateLLMBattleLocal: contender A key mismatch");
        require(vm.addr(contenderBKey) == deployment.contenderB, "CreateLLMBattleLocal: contender B key mismatch");

        string memory question =
            vm.envOr("LLM_BATTLE_QUESTION", string("Rust or Zig: which is the best systems language of the 2020s?"));
        string memory positionA = vm.envOr("LLM_BATTLE_POSITION_A", string("Rust"));
        string memory positionB = vm.envOr("LLM_BATTLE_POSITION_B", string("Zig"));
        uint256 winnerPrize = vm.envOr("LLM_BATTLE_WINNER_PRIZE_WEI", uint256(10 ether));
        uint256 jurorPool = vm.envOr("LLM_BATTLE_JUROR_POOL_WEI", uint256(4 ether));

        vm.broadcast(sponsorKey);
        battleId = llmBattle.createBattle{ value: winnerPrize + jurorPool }(
            deployment.contenderA, deployment.contenderB, question, positionA, positionB, winnerPrize, jurorPool
        );

        _submitArguments(llmBattle, battleId, contenderAKey, contenderBKey);

        vm.broadcast(sponsorKey);
        llmBattle.lockTranscript(battleId);

        LLMBattle.Battle memory battle = llmBattle.getBattle(battleId);
        require(battle.phase == LLMBattle.Phase.Commit, "CreateLLMBattleLocal: battle not in commit phase");
        require(
            battle.validatorCount == deployment.validatorPools.length,
            "CreateLLMBattleLocal: validator snapshot mismatch"
        );

        string memory objectKey = "battle";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "llmBattle", deployment.llmBattle);
        vm.serializeUint(objectKey, "battleId", battleId);
        vm.serializeString(objectKey, "question", question);
        vm.serializeString(objectKey, "positionA", positionA);
        vm.serializeString(objectKey, "positionB", positionB);
        vm.serializeString(objectKey, "winnerPrizeWei", vm.toString(winnerPrize));
        vm.serializeString(objectKey, "jurorPoolWei", vm.toString(jurorPool));
        vm.serializeBytes32(objectKey, "transcriptRoot", battle.transcriptRoot);
        vm.serializeUint(objectKey, "validatorEpoch", battle.validatorEpoch);
        vm.serializeUint(objectKey, "validatorCount", battle.validatorCount);
        vm.serializeUint(objectKey, "quorum", battle.quorum);
        vm.serializeUint(objectKey, "debateDeadline", battle.debateDeadline);
        vm.serializeUint(objectKey, "commitDeadline", battle.commitDeadline);
        string memory json = vm.serializeUint(objectKey, "revealDeadline", battle.revealDeadline);
        vm.writeJson(json, _battleFile());

        console.log("Battle created and transcript locked");
        console.log("  Battle ID      :", uint256(battleId));
        console.log("  Question       :", question);
        console.log("  Validator count:", uint256(battle.validatorCount));
        console.log("  Quorum         :", uint256(battle.quorum));
        console.log("  Artifact       :", _battleFile());
    }

    function _submitArguments(
        LLMBattle llmBattle,
        uint64 battleId,
        uint256 contenderAKey,
        uint256 contenderBKey
    ) internal {
        _submit(
            llmBattle,
            battleId,
            contenderAKey,
            LLMBattle.Round.Opening,
            vm.envOr("LLM_BATTLE_A_OPENING", string("Rust: memory safety without a garbage collector."))
        );
        _submit(
            llmBattle,
            battleId,
            contenderBKey,
            LLMBattle.Round.Opening,
            vm.envOr("LLM_BATTLE_B_OPENING", string("Zig: explicit control with a small, transparent language."))
        );
        _submit(
            llmBattle,
            battleId,
            contenderAKey,
            LLMBattle.Round.Rebuttal,
            vm.envOr("LLM_BATTLE_A_REBUTTAL", string("Rust: its type system makes large teams safer."))
        );
        _submit(
            llmBattle,
            battleId,
            contenderBKey,
            LLMBattle.Round.Rebuttal,
            vm.envOr("LLM_BATTLE_B_REBUTTAL", string("Zig: simpler semantics make systems easier to audit."))
        );
        _submit(
            llmBattle,
            battleId,
            contenderAKey,
            LLMBattle.Round.Finisher,
            vm.envOr("LLM_BATTLE_A_FINISHER", string("Rust wins on ecosystem, correctness, and adoption."))
        );
        _submit(
            llmBattle,
            battleId,
            contenderBKey,
            LLMBattle.Round.Finisher,
            vm.envOr("LLM_BATTLE_B_FINISHER", string("Zig wins on clarity, control, and predictable tooling."))
        );
    }

    function _submit(
        LLMBattle llmBattle,
        uint64 battleId,
        uint256 contenderKey,
        LLMBattle.Round round,
        string memory content
    ) internal {
        vm.broadcast(contenderKey);
        llmBattle.submitArgument(battleId, round, content);
    }
}
