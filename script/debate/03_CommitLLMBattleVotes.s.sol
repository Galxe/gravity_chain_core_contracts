// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "forge-std/console.sol";
import { LLMBattle } from "src/debate/LLMBattle.sol";
import { LLMBattleDemoBase } from "./LLMBattleDemoBase.sol";

/// @notice Commits the configured validator votes without revealing their choices on-chain.
contract CommitLLMBattleVotes is LLMBattleDemoBase {
    function run() external {
        Deployment memory deployment = _loadDeployment();
        uint64 battleId = _loadBattleId();
        LLMBattle llmBattle = LLMBattle(deployment.llmBattle);
        uint256[] memory validatorKeys = _validatorKeys();
        uint256[] memory votes = _votes(deployment.validatorPools.length);

        require(validatorKeys.length == deployment.validatorPools.length, "CommitVotes: validator key mismatch");
        require(
            deployment.validatorVoters.length == deployment.validatorPools.length,
            "CommitVotes: voter artifact mismatch"
        );

        for (uint256 i; i < validatorKeys.length; ++i) {
            address voter = vm.addr(validatorKeys[i]);
            address pool = deployment.validatorPools[i];
            require(voter == deployment.validatorVoters[i], "CommitVotes: voter key mismatch");
            require(llmBattle.juryVoter(battleId, pool) == voter, "CommitVotes: voter snapshot mismatch");

            LLMBattle.Choice choice = _choice(votes[i]);
            bytes32 reasonHash = _reasonHash(i, choice);
            bytes32 salt = _salt(deployment.llmBattle, battleId, pool, i);
            bytes32 commitment = llmBattle.computeCommitment(battleId, pool, choice, reasonHash, salt);

            vm.broadcast(validatorKeys[i]);
            llmBattle.commitVote(battleId, pool, commitment);
        }

        LLMBattle.Battle memory battle = llmBattle.getBattle(battleId);
        require(battle.committedVotes == validatorKeys.length, "CommitVotes: not every validator committed");
        console.log("Validator votes committed:", validatorKeys.length);
    }
}
