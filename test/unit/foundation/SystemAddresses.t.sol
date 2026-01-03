// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";

/// @title SystemAddressesTest
/// @notice Unit tests for SystemAddresses library
contract SystemAddressesTest is Test {
    /// @notice Test that all addresses match expected values
    function test_AddressValues() public pure {
        assertEq(SystemAddresses.SYSTEM_CALLER, address(0x0000000000000000000000000001625F2000));
        assertEq(SystemAddresses.GENESIS, address(0x0000000000000000000000000001625F2008));
        assertEq(SystemAddresses.EPOCH_MANAGER, address(0x0000000000000000000000000001625F2010));
        assertEq(SystemAddresses.STAKE_CONFIG, address(0x0000000000000000000000000001625F2011));
        assertEq(SystemAddresses.STAKING, address(0x0000000000000000000000000001625F2012));
        assertEq(SystemAddresses.VALIDATOR_MANAGER, address(0x0000000000000000000000000001625F2013));
        assertEq(SystemAddresses.GOVERNANCE, address(0x0000000000000000000000000001625F2014));
        assertEq(SystemAddresses.VALIDATOR_CONFIG, address(0x0000000000000000000000000001625F2015));
        assertEq(SystemAddresses.BLOCK, address(0x0000000000000000000000000001625F2016));
        assertEq(SystemAddresses.TIMESTAMP, address(0x0000000000000000000000000001625F2017));
        assertEq(SystemAddresses.JWK_MANAGER, address(0x0000000000000000000000000001625F2018));
        assertEq(SystemAddresses.NATIVE_ORACLE, address(0x0000000000000000000000000001625F2023));
        assertEq(SystemAddresses.RANDOMNESS_CONFIG, address(0x0000000000000000000000000001625F2024));
        assertEq(SystemAddresses.DKG, address(0x0000000000000000000000000001625F2025));
        assertEq(SystemAddresses.GOVERNANCE_CONFIG, address(0x0000000000000000000000000001625F2026));
    }

    /// @notice Test that all addresses are non-zero
    function test_AddressesNonZero() public pure {
        assertTrue(SystemAddresses.SYSTEM_CALLER != address(0), "SYSTEM_CALLER should not be zero");
        assertTrue(SystemAddresses.GENESIS != address(0), "GENESIS should not be zero");
        assertTrue(SystemAddresses.EPOCH_MANAGER != address(0), "EPOCH_MANAGER should not be zero");
        assertTrue(SystemAddresses.STAKE_CONFIG != address(0), "STAKE_CONFIG should not be zero");
        assertTrue(SystemAddresses.STAKING != address(0), "STAKING should not be zero");
        assertTrue(SystemAddresses.VALIDATOR_MANAGER != address(0), "VALIDATOR_MANAGER should not be zero");
        assertTrue(SystemAddresses.GOVERNANCE != address(0), "GOVERNANCE should not be zero");
        assertTrue(SystemAddresses.VALIDATOR_CONFIG != address(0), "VALIDATOR_CONFIG should not be zero");
        assertTrue(SystemAddresses.BLOCK != address(0), "BLOCK should not be zero");
        assertTrue(SystemAddresses.TIMESTAMP != address(0), "TIMESTAMP should not be zero");
        assertTrue(SystemAddresses.JWK_MANAGER != address(0), "JWK_MANAGER should not be zero");
        assertTrue(SystemAddresses.NATIVE_ORACLE != address(0), "NATIVE_ORACLE should not be zero");
        assertTrue(SystemAddresses.RANDOMNESS_CONFIG != address(0), "RANDOMNESS_CONFIG should not be zero");
        assertTrue(SystemAddresses.DKG != address(0), "DKG should not be zero");
        assertTrue(SystemAddresses.GOVERNANCE_CONFIG != address(0), "GOVERNANCE_CONFIG should not be zero");
    }

    /// @notice Test that all addresses are unique
    function test_AddressesUnique() public pure {
        address[15] memory addresses = [
            SystemAddresses.SYSTEM_CALLER,
            SystemAddresses.GENESIS,
            SystemAddresses.EPOCH_MANAGER,
            SystemAddresses.STAKE_CONFIG,
            SystemAddresses.STAKING,
            SystemAddresses.VALIDATOR_MANAGER,
            SystemAddresses.GOVERNANCE,
            SystemAddresses.VALIDATOR_CONFIG,
            SystemAddresses.BLOCK,
            SystemAddresses.TIMESTAMP,
            SystemAddresses.JWK_MANAGER,
            SystemAddresses.NATIVE_ORACLE,
            SystemAddresses.RANDOMNESS_CONFIG,
            SystemAddresses.DKG,
            SystemAddresses.GOVERNANCE_CONFIG
        ];

        // Check each pair for uniqueness
        for (uint256 i = 0; i < addresses.length; i++) {
            for (uint256 j = i + 1; j < addresses.length; j++) {
                assertTrue(addresses[i] != addresses[j], "Addresses should be unique");
            }
        }
    }

    /// @notice Test that addresses follow the 0x1625F2xxx pattern
    function test_AddressPattern() public pure {
        // All addresses should have the same prefix (upper 148 bits should be 0x1625F2)
        uint256 pattern = 0x1625F2;
        uint256 shift = 12; // 3 hex digits = 12 bits for the suffix

        // Verify all addresses follow pattern
        assertEq(uint160(SystemAddresses.SYSTEM_CALLER) >> shift, pattern);
        assertEq(uint160(SystemAddresses.GENESIS) >> shift, pattern);
        assertEq(uint160(SystemAddresses.EPOCH_MANAGER) >> shift, pattern);
        assertEq(uint160(SystemAddresses.STAKE_CONFIG) >> shift, pattern);
        assertEq(uint160(SystemAddresses.STAKING) >> shift, pattern);
        assertEq(uint160(SystemAddresses.VALIDATOR_MANAGER) >> shift, pattern);
        assertEq(uint160(SystemAddresses.GOVERNANCE) >> shift, pattern);
        assertEq(uint160(SystemAddresses.VALIDATOR_CONFIG) >> shift, pattern);
        assertEq(uint160(SystemAddresses.BLOCK) >> shift, pattern);
        assertEq(uint160(SystemAddresses.TIMESTAMP) >> shift, pattern);
        assertEq(uint160(SystemAddresses.JWK_MANAGER) >> shift, pattern);
        assertEq(uint160(SystemAddresses.NATIVE_ORACLE) >> shift, pattern);
        assertEq(uint160(SystemAddresses.RANDOMNESS_CONFIG) >> shift, pattern);
        assertEq(uint160(SystemAddresses.DKG) >> shift, pattern);
        assertEq(uint160(SystemAddresses.GOVERNANCE_CONFIG) >> shift, pattern);
    }
}
