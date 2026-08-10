// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "forge-std/console.sol";
import { LLMBattle } from "src/debate/LLMBattle.sol";
import { LocalBattleStaking, LocalBattleValidatorManagement } from "./LocalBattleInfrastructure.sol";
import { LLMBattleDemoBase } from "./LLMBattleDemoBase.sol";

/// @notice Deploys a local Gravity-shaped jury and the LLMBattle application contract.
contract DeployLLMBattleLocal is LLMBattleDemoBase {
    uint64 internal constant LOCAL_EPOCH = 42;
    uint256 internal constant LOCAL_VALIDATOR_POWER = 100 ether;

    function run() external returns (address llmBattleAddress) {
        uint256 deployerKey = vm.envUint("LLM_BATTLE_DEPLOYER_KEY");
        uint256 sponsorKey = vm.envUint("LLM_BATTLE_SPONSOR_KEY");
        uint256[] memory teamAKeys = _teamAKeys();
        uint256[] memory teamBKeys = _teamBKeys();
        uint256[] memory validatorKeys = _validatorKeys();
        require(teamAKeys.length <= 8 && teamBKeys.length <= 8, "DeployLLMBattleLocal: team exceeds maximum");
        require(validatorKeys.length <= 128, "DeployLLMBattleLocal: jury exceeds LLMBattle maximum");

        address deployer = vm.addr(deployerKey);
        address sponsor = vm.addr(sponsorKey);
        address[] memory teamA = _addresses(teamAKeys);
        address[] memory teamB = _addresses(teamBKeys);
        address[] memory pools = new address[](validatorKeys.length);
        address[] memory voters = new address[](validatorKeys.length);

        vm.startBroadcast(deployerKey);
        LocalBattleStaking staking = new LocalBattleStaking(deployer);
        LocalBattleValidatorManagement validatorManagement = new LocalBattleValidatorManagement(deployer, LOCAL_EPOCH);

        for (uint256 i; i < validatorKeys.length; ++i) {
            voters[i] = vm.addr(validatorKeys[i]);
            pools[i] = staking.createPool(voters[i]);
            validatorManagement.addValidator(pools[i], LOCAL_VALIDATOR_POWER);
        }

        LLMBattle llmBattle = new LLMBattle(address(validatorManagement), address(staking));
        vm.stopBroadcast();

        require(address(llmBattle).code.length > 0, "DeployLLMBattleLocal: LLMBattle has no code");
        require(
            address(llmBattle.validatorManagement()) == address(validatorManagement),
            "DeployLLMBattleLocal: validator management mismatch"
        );
        require(address(llmBattle.staking()) == address(staking), "DeployLLMBattleLocal: staking mismatch");

        string memory objectKey = "deployment";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "validatorManagement", address(validatorManagement));
        vm.serializeAddress(objectKey, "staking", address(staking));
        vm.serializeAddress(objectKey, "llmBattle", address(llmBattle));
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "sponsor", sponsor);
        vm.serializeAddress(objectKey, "teamA", teamA);
        vm.serializeAddress(objectKey, "teamB", teamB);
        vm.serializeAddress(objectKey, "validatorPools", pools);
        vm.serializeAddress(objectKey, "validatorVoters", voters);
        string memory json = vm.serializeUint(objectKey, "validatorCount", validatorKeys.length);
        vm.writeJson(json, _deploymentFile());

        console.log("LLMBattle local deployment complete");
        console.log("  LLMBattle          :", address(llmBattle));
        console.log("  ValidatorManagement:", address(validatorManagement));
        console.log("  Staking            :", address(staking));
        console.log("  Team A members     :", teamA.length);
        console.log("  Team B members     :", teamB.length);
        console.log("  Validators         :", validatorKeys.length);
        console.log("  Artifact           :", _deploymentFile());

        llmBattleAddress = address(llmBattle);
    }
}
