// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { LLMBattle } from "src/debate/LLMBattle.sol";

/// @notice Shared configuration and artifact helpers for the modular local demo scripts.
abstract contract LLMBattleDemoBase is Script {
    struct Deployment {
        address validatorManagement;
        address staking;
        address llmBattle;
        address deployer;
        address sponsor;
        address[] teamA;
        address[] teamB;
        address[] validatorPools;
        address[] validatorVoters;
    }

    function _deploymentFile() internal view returns (string memory) {
        return vm.envOr("LLM_BATTLE_DEPLOYMENT_FILE", string("./deployments/llm-battle/local-deployment.json"));
    }

    function _battleFile() internal view returns (string memory) {
        return vm.envOr("LLM_BATTLE_STATE_FILE", string("./deployments/llm-battle/local-battle.json"));
    }

    function _resultFile() internal view returns (string memory) {
        return vm.envOr("LLM_BATTLE_RESULT_FILE", string("./deployments/llm-battle/local-result.json"));
    }

    function _loadDeployment() internal view returns (Deployment memory deployment) {
        string memory json = vm.readFile(_deploymentFile());
        deployment.validatorManagement = vm.parseJsonAddress(json, ".validatorManagement");
        deployment.staking = vm.parseJsonAddress(json, ".staking");
        deployment.llmBattle = vm.parseJsonAddress(json, ".llmBattle");
        deployment.deployer = vm.parseJsonAddress(json, ".deployer");
        deployment.sponsor = vm.parseJsonAddress(json, ".sponsor");
        deployment.teamA = vm.parseJsonAddressArray(json, ".teamA");
        deployment.teamB = vm.parseJsonAddressArray(json, ".teamB");
        deployment.validatorPools = vm.parseJsonAddressArray(json, ".validatorPools");
        deployment.validatorVoters = vm.parseJsonAddressArray(json, ".validatorVoters");
    }

    function _loadBattleId() internal view returns (uint64 battleId) {
        string memory json = vm.readFile(_battleFile());
        uint256 rawBattleId = vm.parseJsonUint(json, ".battleId");
        require(rawBattleId <= type(uint64).max, "LLMBattleDemo: battleId overflow");
        battleId = uint64(rawBattleId);
    }

    function _validatorKeys() internal view returns (uint256[] memory keys) {
        keys = vm.envUint("LLM_BATTLE_VALIDATOR_KEYS", ",");
        require(keys.length > 0, "LLMBattleDemo: no validator keys");
    }

    function _teamAKeys() internal view returns (uint256[] memory keys) {
        keys = vm.envUint("LLM_BATTLE_TEAM_A_KEYS", ",");
        require(keys.length > 0, "LLMBattleDemo: no team A keys");
    }

    function _teamBKeys() internal view returns (uint256[] memory keys) {
        keys = vm.envUint("LLM_BATTLE_TEAM_B_KEYS", ",");
        require(keys.length > 0, "LLMBattleDemo: no team B keys");
    }

    function _addresses(
        uint256[] memory keys
    ) internal pure returns (address[] memory accounts) {
        accounts = new address[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            accounts[i] = vm.addr(keys[i]);
        }
    }

    function _roundSpeakers(
        address[] memory team
    ) internal pure returns (address[3] memory speakers) {
        for (uint256 i; i < speakers.length; ++i) {
            speakers[i] = team[i % team.length];
        }
    }

    function _dynamicSpeakers(
        address[3] memory speakers
    ) internal pure returns (address[] memory dynamicSpeakers) {
        dynamicSpeakers = new address[](speakers.length);
        for (uint256 i; i < speakers.length; ++i) {
            dynamicSpeakers[i] = speakers[i];
        }
    }

    function _votes(
        uint256 validatorCount
    ) internal view returns (uint256[] memory votes) {
        uint256[] memory defaults = new uint256[](validatorCount);
        for (uint256 i; i < validatorCount; ++i) {
            defaults[i] = i + 1 == validatorCount ? uint256(LLMBattle.Choice.SideB) : uint256(LLMBattle.Choice.SideA);
        }

        votes = vm.envOr("LLM_BATTLE_VOTES", ",", defaults);
        require(votes.length == validatorCount, "LLMBattleDemo: vote count mismatch");
    }

    function _choice(
        uint256 rawChoice
    ) internal pure returns (LLMBattle.Choice choice) {
        require(
            rawChoice == uint256(LLMBattle.Choice.SideA) || rawChoice == uint256(LLMBattle.Choice.SideB),
            "LLMBattleDemo: vote must be 1 or 2"
        );
        choice = LLMBattle.Choice(rawChoice);
    }

    function _reasonHash(
        uint256 validatorIndex,
        LLMBattle.Choice choice
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("gravity-llm-battle-local-reason", validatorIndex, choice));
    }

    /// @dev Deterministic for repeatable local demos. Production clients must use secret random salts.
    function _salt(
        address llmBattle,
        uint64 battleId,
        address pool,
        uint256 validatorIndex
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode("gravity-llm-battle-local-salt", block.chainid, llmBattle, battleId, pool, validatorIndex)
        );
    }
}
