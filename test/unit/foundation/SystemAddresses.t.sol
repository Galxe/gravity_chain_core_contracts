// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SystemAddresses} from "../../../src/foundation/SystemAddresses.sol";

/// @title SystemAddressesTest
/// @notice Unit tests for SystemAddresses library
contract SystemAddressesTest is Test {
    /// @notice Test that all addresses match expected values
    function test_AddressValues() public pure {
        assertEq(SystemAddresses.SYSTEM_CALLER, address(0x0000000000000000000000000001625F2000));
        assertEq(SystemAddresses.GENESIS, address(0x0000000000000000000000000001625F2008));
        assertEq(SystemAddresses.EPOCH_MANAGER, address(0x0000000000000000000000000001625F2010));
        assertEq(SystemAddresses.STAKE_CONFIG, address(0x0000000000000000000000000001625F2011));
        assertEq(SystemAddresses.VALIDATOR_MANAGER, address(0x0000000000000000000000000001625F2013));
        assertEq(SystemAddresses.BLOCK, address(0x0000000000000000000000000001625F2016));
        assertEq(SystemAddresses.TIMESTAMP, address(0x0000000000000000000000000001625F2017));
        assertEq(SystemAddresses.JWK_MANAGER, address(0x0000000000000000000000000001625F2018));
        assertEq(SystemAddresses.TIMELOCK, address(0x0000000000000000000000000001625F201F));
        assertEq(SystemAddresses.HASH_ORACLE, address(0x0000000000000000000000000001625F2023));
    }

    /// @notice Test that all addresses are non-zero
    function test_AddressesNonZero() public pure {
        assertTrue(SystemAddresses.SYSTEM_CALLER != address(0), "SYSTEM_CALLER should not be zero");
        assertTrue(SystemAddresses.GENESIS != address(0), "GENESIS should not be zero");
        assertTrue(SystemAddresses.EPOCH_MANAGER != address(0), "EPOCH_MANAGER should not be zero");
        assertTrue(SystemAddresses.STAKE_CONFIG != address(0), "STAKE_CONFIG should not be zero");
        assertTrue(SystemAddresses.VALIDATOR_MANAGER != address(0), "VALIDATOR_MANAGER should not be zero");
        assertTrue(SystemAddresses.BLOCK != address(0), "BLOCK should not be zero");
        assertTrue(SystemAddresses.TIMESTAMP != address(0), "TIMESTAMP should not be zero");
        assertTrue(SystemAddresses.JWK_MANAGER != address(0), "JWK_MANAGER should not be zero");
        assertTrue(SystemAddresses.TIMELOCK != address(0), "TIMELOCK should not be zero");
        assertTrue(SystemAddresses.HASH_ORACLE != address(0), "HASH_ORACLE should not be zero");
    }

    /// @notice Test that all addresses are unique
    function test_AddressesUnique() public pure {
        address[10] memory addresses = [
            SystemAddresses.SYSTEM_CALLER,
            SystemAddresses.GENESIS,
            SystemAddresses.EPOCH_MANAGER,
            SystemAddresses.STAKE_CONFIG,
            SystemAddresses.VALIDATOR_MANAGER,
            SystemAddresses.BLOCK,
            SystemAddresses.TIMESTAMP,
            SystemAddresses.JWK_MANAGER,
            SystemAddresses.TIMELOCK,
            SystemAddresses.HASH_ORACLE
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

        // Verify SYSTEM_CALLER follows pattern (ends in 000)
        assertEq(uint160(SystemAddresses.SYSTEM_CALLER) >> shift, pattern);

        // Verify GENESIS follows pattern (ends in 008)
        assertEq(uint160(SystemAddresses.GENESIS) >> shift, pattern);

        // Verify EPOCH_MANAGER follows pattern (ends in 010)
        assertEq(uint160(SystemAddresses.EPOCH_MANAGER) >> shift, pattern);

        // Verify STAKE_CONFIG follows pattern (ends in 011)
        assertEq(uint160(SystemAddresses.STAKE_CONFIG) >> shift, pattern);

        // Verify VALIDATOR_MANAGER follows pattern (ends in 013)
        assertEq(uint160(SystemAddresses.VALIDATOR_MANAGER) >> shift, pattern);

        // Verify BLOCK follows pattern (ends in 016)
        assertEq(uint160(SystemAddresses.BLOCK) >> shift, pattern);

        // Verify TIMESTAMP follows pattern (ends in 017)
        assertEq(uint160(SystemAddresses.TIMESTAMP) >> shift, pattern);

        // Verify JWK_MANAGER follows pattern (ends in 018)
        assertEq(uint160(SystemAddresses.JWK_MANAGER) >> shift, pattern);

        // Verify TIMELOCK follows pattern (ends in 01F)
        assertEq(uint160(SystemAddresses.TIMELOCK) >> shift, pattern);

        // Verify HASH_ORACLE follows pattern (ends in 023)
        assertEq(uint160(SystemAddresses.HASH_ORACLE) >> shift, pattern);
    }
}

