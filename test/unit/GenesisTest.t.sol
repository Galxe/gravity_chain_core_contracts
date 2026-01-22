// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Genesis } from "../../src/Genesis.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

// Configs
import { ValidatorConfig } from "../../src/runtime/ValidatorConfig.sol";
import { StakingConfig } from "../../src/runtime/StakingConfig.sol";
import { EpochConfig } from "../../src/runtime/EpochConfig.sol";
import { ConsensusConfig } from "../../src/runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "../../src/runtime/ExecutionConfig.sol";
import { GovernanceConfig } from "../../src/runtime/GovernanceConfig.sol";
import { VersionConfig } from "../../src/runtime/VersionConfig.sol";
import { RandomnessConfig } from "../../src/runtime/RandomnessConfig.sol";

// Systems
import { Staking } from "../../src/staking/Staking.sol";
import { ValidatorManagement } from "../../src/staking/ValidatorManagement.sol";
import { Reconfiguration } from "../../src/blocker/Reconfiguration.sol";
import { Blocker } from "../../src/blocker/Blocker.sol";
import { NativeOracle } from "../../src/oracle/NativeOracle.sol";
import { JWKManager, IJWKManager } from "../../src/oracle/jwk/JWKManager.sol";
import { Timestamp } from "../../src/runtime/Timestamp.sol";

contract GenesisTest is Test {
    Genesis genesis;

    function setUp() public {
        // Etch all system contracts
        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        vm.etch(SystemAddresses.EPOCH_CONFIG, address(new EpochConfig()).code);
        vm.etch(SystemAddresses.CONSENSUS_CONFIG, address(new ConsensusConfig()).code);
        vm.etch(SystemAddresses.EXECUTION_CONFIG, address(new ExecutionConfig()).code);
        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);
        vm.etch(SystemAddresses.VERSION_CONFIG, address(new VersionConfig()).code);
        vm.etch(SystemAddresses.RANDOMNESS_CONFIG, address(new RandomnessConfig()).code);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new Reconfiguration()).code);
        vm.etch(SystemAddresses.BLOCK, address(new Blocker()).code);
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        vm.etch(SystemAddresses.JWK_MANAGER, address(new JWKManager()).code);
        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);

        // Etch Genesis
        vm.etch(SystemAddresses.GENESIS, address(new Genesis()).code);
        genesis = Genesis(SystemAddresses.GENESIS);
    }

    function test_Genesis_Success() public {
        // Setup initial params
        Genesis.GenesisInitParams memory params;

        // Validator Config
        params.validatorConfig.minimumBond = 100 ether;
        params.validatorConfig.maximumBond = 10000 ether;
        params.validatorConfig.unbondingDelayMicros = 7 days * 1_000_000;
        params.validatorConfig.allowValidatorSetChange = true;
        params.validatorConfig.votingPowerIncreaseLimitPct = 20;
        params.validatorConfig.maxValidatorSetSize = 100;

        // Staking Config
        params.stakingConfig.minimumStake = 10 ether;
        params.stakingConfig.lockupDurationMicros = 14 days * 1_000_000;
        params.stakingConfig.unbondingDelayMicros = 7 days * 1_000_000;
        params.stakingConfig.minimumProposalStake = 100 ether;

        // Epoch Config
        params.epochIntervalMicros = 1 hours * 1_000_000;

        // Governance Config
        params.governanceConfig.minVotingThreshold = 1000 ether;
        params.governanceConfig.requiredProposerStake = 100 ether;
        params.governanceConfig.votingDurationMicros = 2 days * 1_000_000;

        // Version Config
        params.majorVersion = 1;

        // Consensus & Execution Config (Dummy bytes)
        params.consensusConfig = hex"deadbeef";
        params.executionConfig = hex"cafebabe";

        // Randomness Config
        params.randomnessConfig = RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).newOff();

        // Validators (1 Validator)
        Genesis.InitialValidator[] memory validators = new Genesis.InitialValidator[](1);
        validators[0] = Genesis.InitialValidator({
            operator: makeAddr("operator1"),
            owner: makeAddr("owner1"),
            stakeAmount: 200 ether,
            moniker: "Validator 1",
            consensusPubkey: hex"1234",
            consensusPop: hex"5678",
            networkAddresses: bytes("/ip4/127.0.0.1/tcp/8000"),
            fullnodeAddresses: bytes("/ip4/127.0.0.1/tcp/9000"),
            votingPower: 200 ether
        });
        params.validators = validators;

        // Oracle Config
        uint32[] memory sourceTypes = new uint32[](1);
        sourceTypes[0] = 1;
        address[] memory callbacks = new address[](1);
        callbacks[0] = SystemAddresses.JWK_MANAGER;
        Genesis.OracleTaskParams[] memory tasks = new Genesis.OracleTaskParams[](0);
        Genesis.BridgeConfig memory bridgeConfig = Genesis.BridgeConfig(false, address(0));
        params.oracleConfig = Genesis.OracleInitParams(sourceTypes, callbacks, tasks, bridgeConfig);

        // JWK Config
        bytes[] memory issuers = new bytes[](1);
        issuers[0] = "https://accounts.google.com";
        IJWKManager.RSA_JWK[][] memory jwks = new IJWKManager.RSA_JWK[][](1);
        jwks[0] = new IJWKManager.RSA_JWK[](1);
        jwks[0][0] = IJWKManager.RSA_JWK("kid1", "RSA", "RS256", "e", "n");
        params.jwkConfig = Genesis.JWKInitParams(issuers, jwks);

        // Impersonate SYSTEM_CALLER
        vm.startPrank(SystemAddresses.SYSTEM_CALLER);

        // Ensure Genesis has funds to create pools
        vm.deal(SystemAddresses.SYSTEM_CALLER, 1000 ether); // Actually msg.sender pays? No, Genesis calls Staking.
        vm.deal(SystemAddresses.GENESIS, 1000 ether);

        // Execute Initialize
        // Note: Genesis.initialize is payable, but since we prank SYSTEM_CALLER, we can send value?
        // Actually, Genesis logic is: `Staking.createPool{value: v.stakeAmount}`.
        // This value is taken from Genesis contract balance.
        // So we just need to fund Genesis contract.

        genesis.initialize(params);
        vm.stopPrank();

        // Verify Initializations
        assertTrue(ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).isInitialized());
        assertEq(StakingConfig(SystemAddresses.STAKE_CONFIG).minimumStake(), 10 ether);
        assertTrue(EpochConfig(SystemAddresses.EPOCH_CONFIG).isInitialized());
        assertTrue(ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG).isInitialized());
        assertTrue(ExecutionConfig(SystemAddresses.EXECUTION_CONFIG).isInitialized());
        assertTrue(GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG).isInitialized());
        assertTrue(VersionConfig(SystemAddresses.VERSION_CONFIG).isInitialized());
        assertTrue(RandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).isInitialized());
        assertTrue(ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).isInitialized());

        // Verify NativeOracle callback
        assertEq(NativeOracle(SystemAddresses.NATIVE_ORACLE).getDefaultCallback(1), SystemAddresses.JWK_MANAGER);

        // Verify JWK Manager
        IJWKManager.AllProvidersJWKs memory observed = JWKManager(SystemAddresses.JWK_MANAGER).getObservedJWKs();
        assertEq(observed.entries.length, 1);
        assertEq(observed.entries[0].issuer, "https://accounts.google.com");

        // Verify Validator
        assertEq(ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorCount(), 1);
        // We can't easily guess the pool address because of CREATE2 or nonce
        // But we know it should have 200 ether voting power
        assertEq(ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getTotalVotingPower(), 200 ether);
    }
}
