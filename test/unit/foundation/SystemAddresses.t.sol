// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";

/// @title SystemAddressesTest
/// @notice Unit tests for SystemAddresses library
contract SystemAddressesTest is Test {
    /// @notice Test that all addresses match expected values
    function test_AddressValues() public pure {
        // Consensus Engine (0x1625F0xxx)
        assertEq(SystemAddresses.SYSTEM_CALLER, address(0x0000000000000000000000000001625F0000));
        assertEq(SystemAddresses.GENESIS, address(0x0000000000000000000000000001625F0001));

        // Runtime Configurations (0x1625F1xxx)
        assertEq(SystemAddresses.TIMESTAMP, address(0x0000000000000000000000000001625F1000));
        assertEq(SystemAddresses.STAKE_CONFIG, address(0x0000000000000000000000000001625F1001));
        assertEq(SystemAddresses.VALIDATOR_CONFIG, address(0x0000000000000000000000000001625F1002));
        assertEq(SystemAddresses.RANDOMNESS_CONFIG, address(0x0000000000000000000000000001625F1003));
        assertEq(SystemAddresses.GOVERNANCE_CONFIG, address(0x0000000000000000000000000001625F1004));
        assertEq(SystemAddresses.EPOCH_CONFIG, address(0x0000000000000000000000000001625F1005));
        assertEq(SystemAddresses.VERSION_CONFIG, address(0x0000000000000000000000000001625F1006));
        assertEq(SystemAddresses.CONSENSUS_CONFIG, address(0x0000000000000000000000000001625F1007));
        assertEq(SystemAddresses.EXECUTION_CONFIG, address(0x0000000000000000000000000001625F1008));
        assertEq(SystemAddresses.ORACLE_TASK_CONFIG, address(0x0000000000000000000000000001625F1009));
        assertEq(SystemAddresses.ON_DEMAND_ORACLE_TASK_CONFIG, address(0x0000000000000000000000000001625F100A));

        // Staking & Validator (0x1625F2xxx)
        assertEq(SystemAddresses.STAKING, address(0x0000000000000000000000000001625F2000));
        assertEq(SystemAddresses.VALIDATOR_MANAGER, address(0x0000000000000000000000000001625F2001));
        assertEq(SystemAddresses.DKG, address(0x0000000000000000000000000001625F2002));
        assertEq(SystemAddresses.RECONFIGURATION, address(0x0000000000000000000000000001625F2003));
        assertEq(SystemAddresses.BLOCK, address(0x0000000000000000000000000001625F2004));

        // Governance (0x1625F3xxx)
        assertEq(SystemAddresses.GOVERNANCE, address(0x0000000000000000000000000001625F3000));

        // Oracle (0x1625F4xxx)
        assertEq(SystemAddresses.NATIVE_ORACLE, address(0x0000000000000000000000000001625F4000));
        assertEq(SystemAddresses.JWK_MANAGER, address(0x0000000000000000000000000001625F4001));
        assertEq(SystemAddresses.ORACLE_REQUEST_QUEUE, address(0x0000000000000000000000000001625F4002));

        // Precompiles (0x1625F5xxx)
        assertEq(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(0x0000000000000000000000000001625F5000));
    }

    /// @notice Test that all addresses are non-zero
    function test_AddressesNonZero() public pure {
        // Consensus Engine
        assertTrue(SystemAddresses.SYSTEM_CALLER != address(0), "SYSTEM_CALLER should not be zero");
        assertTrue(SystemAddresses.GENESIS != address(0), "GENESIS should not be zero");

        // Runtime Configurations
        assertTrue(SystemAddresses.TIMESTAMP != address(0), "TIMESTAMP should not be zero");
        assertTrue(SystemAddresses.STAKE_CONFIG != address(0), "STAKE_CONFIG should not be zero");
        assertTrue(SystemAddresses.VALIDATOR_CONFIG != address(0), "VALIDATOR_CONFIG should not be zero");
        assertTrue(SystemAddresses.RANDOMNESS_CONFIG != address(0), "RANDOMNESS_CONFIG should not be zero");
        assertTrue(SystemAddresses.GOVERNANCE_CONFIG != address(0), "GOVERNANCE_CONFIG should not be zero");
        assertTrue(SystemAddresses.EPOCH_CONFIG != address(0), "EPOCH_CONFIG should not be zero");
        assertTrue(SystemAddresses.VERSION_CONFIG != address(0), "VERSION_CONFIG should not be zero");
        assertTrue(SystemAddresses.CONSENSUS_CONFIG != address(0), "CONSENSUS_CONFIG should not be zero");
        assertTrue(SystemAddresses.EXECUTION_CONFIG != address(0), "EXECUTION_CONFIG should not be zero");
        assertTrue(SystemAddresses.ORACLE_TASK_CONFIG != address(0), "ORACLE_TASK_CONFIG should not be zero");
        assertTrue(
            SystemAddresses.ON_DEMAND_ORACLE_TASK_CONFIG != address(0),
            "ON_DEMAND_ORACLE_TASK_CONFIG should not be zero"
        );

        // Staking & Validator
        assertTrue(SystemAddresses.STAKING != address(0), "STAKING should not be zero");
        assertTrue(SystemAddresses.VALIDATOR_MANAGER != address(0), "VALIDATOR_MANAGER should not be zero");
        assertTrue(SystemAddresses.DKG != address(0), "DKG should not be zero");
        assertTrue(SystemAddresses.RECONFIGURATION != address(0), "RECONFIGURATION should not be zero");
        assertTrue(SystemAddresses.BLOCK != address(0), "BLOCK should not be zero");

        // Governance
        assertTrue(SystemAddresses.GOVERNANCE != address(0), "GOVERNANCE should not be zero");

        // Oracle
        assertTrue(SystemAddresses.NATIVE_ORACLE != address(0), "NATIVE_ORACLE should not be zero");
        assertTrue(SystemAddresses.JWK_MANAGER != address(0), "JWK_MANAGER should not be zero");
        assertTrue(SystemAddresses.ORACLE_REQUEST_QUEUE != address(0), "ORACLE_REQUEST_QUEUE should not be zero");

        // Precompiles
        assertTrue(SystemAddresses.NATIVE_MINT_PRECOMPILE != address(0), "NATIVE_MINT_PRECOMPILE should not be zero");
    }

    /// @notice Test that all addresses are unique
    function test_AddressesUnique() public pure {
        address[25] memory addresses = [
            // Consensus Engine
            SystemAddresses.SYSTEM_CALLER,
            SystemAddresses.GENESIS,
            // Runtime Configurations
            SystemAddresses.TIMESTAMP,
            SystemAddresses.STAKE_CONFIG,
            SystemAddresses.VALIDATOR_CONFIG,
            SystemAddresses.RANDOMNESS_CONFIG,
            SystemAddresses.GOVERNANCE_CONFIG,
            SystemAddresses.EPOCH_CONFIG,
            SystemAddresses.VERSION_CONFIG,
            SystemAddresses.CONSENSUS_CONFIG,
            SystemAddresses.EXECUTION_CONFIG,
            SystemAddresses.ORACLE_TASK_CONFIG,
            SystemAddresses.ON_DEMAND_ORACLE_TASK_CONFIG,
            // Staking & Validator
            SystemAddresses.STAKING,
            SystemAddresses.VALIDATOR_MANAGER,
            SystemAddresses.DKG,
            SystemAddresses.RECONFIGURATION,
            SystemAddresses.BLOCK,
            // Governance
            SystemAddresses.GOVERNANCE,
            // Oracle
            SystemAddresses.NATIVE_ORACLE,
            SystemAddresses.JWK_MANAGER,
            SystemAddresses.ORACLE_REQUEST_QUEUE,
            // Precompiles
            SystemAddresses.NATIVE_MINT_PRECOMPILE,
            SystemAddresses.BLS_POP_VERIFY_PRECOMPILE,
            address(0) // placeholder to make array size 24
        ];

        // Check each pair for uniqueness (excluding last placeholder)
        for (uint256 i = 0; i < addresses.length - 1; i++) {
            for (uint256 j = i + 1; j < addresses.length - 1; j++) {
                assertTrue(addresses[i] != addresses[j], "Addresses should be unique");
            }
        }
    }

    /// @notice Test that addresses follow the 0x1625Fxxxx pattern
    function test_AddressPattern() public pure {
        // All addresses should share the 0x1625F prefix (upper bits)
        uint256 basePattern = 0x1625F;
        uint256 shift = 16; // 4 hex digits = 16 bits for the suffix

        // Consensus Engine (0x1625F0xxx)
        assertEq(uint160(SystemAddresses.SYSTEM_CALLER) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.GENESIS) >> shift, basePattern);

        // Runtime Configurations (0x1625F1xxx)
        assertEq(uint160(SystemAddresses.TIMESTAMP) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.STAKE_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.VALIDATOR_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.RANDOMNESS_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.GOVERNANCE_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.EPOCH_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.VERSION_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.CONSENSUS_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.EXECUTION_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.ORACLE_TASK_CONFIG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.ON_DEMAND_ORACLE_TASK_CONFIG) >> shift, basePattern);

        // Staking & Validator (0x1625F2xxx)
        assertEq(uint160(SystemAddresses.STAKING) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.VALIDATOR_MANAGER) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.DKG) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.RECONFIGURATION) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.BLOCK) >> shift, basePattern);

        // Governance (0x1625F3xxx)
        assertEq(uint160(SystemAddresses.GOVERNANCE) >> shift, basePattern);

        // Oracle (0x1625F4xxx)
        assertEq(uint160(SystemAddresses.NATIVE_ORACLE) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.JWK_MANAGER) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.ORACLE_REQUEST_QUEUE) >> shift, basePattern);

        // Precompiles (0x1625F5xxx)
        assertEq(uint160(SystemAddresses.NATIVE_MINT_PRECOMPILE) >> shift, basePattern);
        assertEq(uint160(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE) >> shift, basePattern);
    }

    /// @notice Test address range categorization
    function test_AddressRanges() public pure {
        // Consensus Engine addresses should be in 0x1625F0xxx range
        uint256 consensusRangeStart = 0x1625F0000;
        uint256 consensusRangeEnd = 0x1625F0FFF;
        assertTrue(
            uint160(SystemAddresses.SYSTEM_CALLER) >= consensusRangeStart
                && uint160(SystemAddresses.SYSTEM_CALLER) <= consensusRangeEnd
        );
        assertTrue(
            uint160(SystemAddresses.GENESIS) >= consensusRangeStart
                && uint160(SystemAddresses.GENESIS) <= consensusRangeEnd
        );

        // Runtime Configuration addresses should be in 0x1625F1xxx range
        uint256 runtimeRangeStart = 0x1625F1000;
        uint256 runtimeRangeEnd = 0x1625F1FFF;
        assertTrue(
            uint160(SystemAddresses.TIMESTAMP) >= runtimeRangeStart
                && uint160(SystemAddresses.TIMESTAMP) <= runtimeRangeEnd
        );
        assertTrue(
            uint160(SystemAddresses.STAKE_CONFIG) >= runtimeRangeStart
                && uint160(SystemAddresses.STAKE_CONFIG) <= runtimeRangeEnd
        );

        // Staking & Validator addresses should be in 0x1625F2xxx range
        uint256 stakingRangeStart = 0x1625F2000;
        uint256 stakingRangeEnd = 0x1625F2FFF;
        assertTrue(
            uint160(SystemAddresses.STAKING) >= stakingRangeStart && uint160(SystemAddresses.STAKING) <= stakingRangeEnd
        );
        assertTrue(
            uint160(SystemAddresses.VALIDATOR_MANAGER) >= stakingRangeStart
                && uint160(SystemAddresses.VALIDATOR_MANAGER) <= stakingRangeEnd
        );

        // Governance addresses should be in 0x1625F3xxx range
        uint256 governanceRangeStart = 0x1625F3000;
        uint256 governanceRangeEnd = 0x1625F3FFF;
        assertTrue(
            uint160(SystemAddresses.GOVERNANCE) >= governanceRangeStart
                && uint160(SystemAddresses.GOVERNANCE) <= governanceRangeEnd
        );

        // Oracle addresses should be in 0x1625F4xxx range
        uint256 oracleRangeStart = 0x1625F4000;
        uint256 oracleRangeEnd = 0x1625F4FFF;
        assertTrue(
            uint160(SystemAddresses.NATIVE_ORACLE) >= oracleRangeStart
                && uint160(SystemAddresses.NATIVE_ORACLE) <= oracleRangeEnd
        );
        assertTrue(
            uint160(SystemAddresses.JWK_MANAGER) >= oracleRangeStart
                && uint160(SystemAddresses.JWK_MANAGER) <= oracleRangeEnd
        );

        // Precompile addresses should be in 0x1625F5xxx range
        uint256 precompileRangeStart = 0x1625F5000;
        uint256 precompileRangeEnd = 0x1625F5FFF;
        assertTrue(
            uint160(SystemAddresses.NATIVE_MINT_PRECOMPILE) >= precompileRangeStart
                && uint160(SystemAddresses.NATIVE_MINT_PRECOMPILE) <= precompileRangeEnd
        );
        assertTrue(
            uint160(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE) >= precompileRangeStart
                && uint160(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE) <= precompileRangeEnd
        );
    }
}
