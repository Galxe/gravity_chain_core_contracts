// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "forge-std/console.sol";
import { LLMBattle } from "src/debate/LLMBattle.sol";
import { LLMBattleDemoBase } from "./LLMBattleDemoBase.sol";

/// @notice Opens reveal, reveals every configured vote, resolves, and withdraws all demo payouts.
contract RevealResolveLLMBattle is LLMBattleDemoBase {
    function run() external {
        Deployment memory deployment = _loadDeployment();
        uint64 battleId = _loadBattleId();
        LLMBattle llmBattle = LLMBattle(deployment.llmBattle);
        uint256 sponsorKey = vm.envUint("LLM_BATTLE_SPONSOR_KEY");
        uint256[] memory teamAKeys = _teamAKeys();
        uint256[] memory teamBKeys = _teamBKeys();
        uint256[] memory validatorKeys = _validatorKeys();
        uint256[] memory votes = _votes(deployment.validatorPools.length);

        require(vm.addr(sponsorKey) == deployment.sponsor, "RevealResolve: sponsor key mismatch");
        _requireTeamMatches(teamAKeys, deployment.teamA, "RevealResolve: team A key mismatch");
        _requireTeamMatches(teamBKeys, deployment.teamB, "RevealResolve: team B key mismatch");
        require(validatorKeys.length == deployment.validatorPools.length, "RevealResolve: validator key mismatch");

        vm.broadcast(sponsorKey);
        llmBattle.openReveal(battleId);

        for (uint256 i; i < validatorKeys.length; ++i) {
            LLMBattle.Choice choice = _choice(votes[i]);
            bytes32 reasonHash = _reasonHash(i, choice);
            bytes32 salt = _salt(deployment.llmBattle, battleId, deployment.validatorPools[i], i);

            vm.broadcast(validatorKeys[i]);
            llmBattle.revealVote(battleId, deployment.validatorPools[i], choice, reasonHash, salt);
        }

        vm.broadcast(sponsorKey);
        llmBattle.resolve(battleId);

        LLMBattle.Battle memory result = llmBattle.getBattle(battleId);
        require(result.phase == LLMBattle.Phase.Resolved, "RevealResolve: battle not resolved");

        if (result.jurorRewardPerVote > 0) {
            for (uint256 i; i < validatorKeys.length; ++i) {
                vm.broadcast(validatorKeys[i]);
                llmBattle.claimJurorReward(battleId, deployment.validatorPools[i]);
            }
        }

        for (uint256 i; i < validatorKeys.length; ++i) {
            _withdrawIfClaimable(llmBattle, validatorKeys[i]);
        }
        _withdrawIfClaimable(llmBattle, sponsorKey);
        _withdrawTeam(llmBattle, teamAKeys);
        _withdrawTeam(llmBattle, teamBKeys);

        require(address(llmBattle).balance == 0, "RevealResolve: escrow not fully withdrawn");

        string memory objectKey = "result";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "llmBattle", deployment.llmBattle);
        vm.serializeUint(objectKey, "battleId", battleId);
        vm.serializeString(objectKey, "outcome", _outcomeName(result.outcome));
        vm.serializeUint(objectKey, "outcomeCode", uint256(result.outcome));
        vm.serializeUint(objectKey, "votesA", result.votesA);
        vm.serializeUint(objectKey, "votesB", result.votesB);
        vm.serializeUint(objectKey, "revealedVotes", result.revealedVotes);
        vm.serializeString(objectKey, "jurorRewardPerVoteWei", vm.toString(result.jurorRewardPerVote));
        string memory json =
            vm.serializeString(objectKey, "contractBalanceWei", vm.toString(address(llmBattle).balance));
        vm.writeJson(json, _resultFile());

        console.log("Battle resolved and all demo payouts withdrawn");
        console.log("  Outcome :", _outcomeName(result.outcome));
        console.log("  Votes A :", uint256(result.votesA));
        console.log("  Votes B :", uint256(result.votesB));
        console.log("  Artifact:", _resultFile());
    }

    function _withdrawIfClaimable(
        LLMBattle llmBattle,
        uint256 accountKey
    ) internal {
        address account = vm.addr(accountKey);
        if (llmBattle.claimable(account) == 0) return;

        vm.broadcast(accountKey);
        llmBattle.withdraw();
    }

    function _withdrawTeam(
        LLMBattle llmBattle,
        uint256[] memory teamKeys
    ) internal {
        for (uint256 i; i < teamKeys.length; ++i) {
            _withdrawIfClaimable(llmBattle, teamKeys[i]);
        }
    }

    function _requireTeamMatches(
        uint256[] memory keys,
        address[] memory expectedTeam,
        string memory errorMessage
    ) internal pure {
        require(keys.length == expectedTeam.length, errorMessage);
        for (uint256 i; i < keys.length; ++i) {
            require(vm.addr(keys[i]) == expectedTeam[i], errorMessage);
        }
    }

    function _outcomeName(
        LLMBattle.Outcome outcome
    ) internal pure returns (string memory) {
        if (outcome == LLMBattle.Outcome.SideA) return "SideA";
        if (outcome == LLMBattle.Outcome.SideB) return "SideB";
        if (outcome == LLMBattle.Outcome.Draw) return "Draw";
        if (outcome == LLMBattle.Outcome.NoQuorum) return "NoQuorum";
        if (outcome == LLMBattle.Outcome.Cancelled) return "Cancelled";
        return "Pending";
    }
}
