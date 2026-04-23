// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Governance } from "@gravity/governance/Governance.sol";
import { SystemAddresses } from "@gravity/foundation/SystemAddresses.sol";

/// @title PoC for gravity-audit issue #567 (EXISTS, critical, live-bug verification)
/// @notice "Governance._owner is zero at genesis — addExecutor is permanently un-callable,
///          bricking all proposal execution".
///
/// @dev Also covers #559 (same root cause — Governance predeploy with `_owner==0`).
///
/// Exploit chain (condensed from issue body):
///   1. genesis-tool deploys Governance by writing only runtime bytecode at
///      SystemAddresses.GOVERNANCE — the constructor never runs → slot 0 (`_owner`)
///      stays zero.
///   2. Governance.addExecutor is `external onlyOwner`. With `_owner == 0`, every
///      caller (whose msg.sender is != 0x0) fails OZ `_checkOwner` and reverts with
///      `OwnableUnauthorizedAccount(msg.sender)`.
///   3. Therefore no executor can ever be added → `execute()` (gated by
///      `onlyExecutor`) reverts for every caller → all SUCCEEDED proposals are
///      permanently un-executable.
///   4. Recovery is impossible: `transferOwnership` is also `onlyOwner`;
///      `acceptOwnership` needs `_pendingOwner==msg.sender` but slot 1 is also zero;
///      `renounceOwnership` is overridden to revert.
///
/// @dev  PoC polarity: this test is named `test_attackSucceedsIfVulnerable` and is
///       expected to PASS on vulnerable code (current main `a623eab`), demonstrating
///       the bricked state. It reproduces the genesis-tool behavior by using
///       `vm.etch` to place Governance runtime bytecode at `SystemAddresses.GOVERNANCE`
///       WITHOUT copying slot 0/1 (unlike the unit-test harness in
///       `test/unit/governance/Governance.t.sol` which explicitly seeds them via
///       vm.store to make the test suite work).
contract POC_567 is Test {
    Governance public governance;

    address public constant GOVERNANCE_ADDR = SystemAddresses.GOVERNANCE;

    // A realistic would-be owner the deployer *intended* for Governance. In the
    // BSC-style predeploy, this address never makes it to slot 0 because the
    // constructor doesn't run.
    address public intendedOwner = makeAddr("intendedOwner");

    // An ordinary caller who might try to add an executor post-genesis.
    address public anyCaller = makeAddr("anyCaller");

    function setUp() public {
        // Step 1: mimic genesis-tool `deploy_bsc_style` — only runtime bytecode
        //         is written at GOVERNANCE_ADDR. We build a temp deployment so
        //         we can grab its runtime code, but we copy ONLY `.code`, not
        //         slots 0/1 (unlike the project's own unit-test harness).
        Governance tempGov = new Governance(intendedOwner);
        vm.etch(GOVERNANCE_ADDR, address(tempGov).code);
        governance = Governance(GOVERNANCE_ADDR);
    }

    /// @notice Test is expected to PASS on vulnerable code (current main).
    ///         On a fix that seeds `_owner` at genesis, this test would FAIL at
    ///         the first assertion (owner would be non-zero) or the revert
    ///         would not happen.
    function test_attackSucceedsIfVulnerable() public {
        // --- Assert 1: the Governance predeploy's owner is the zero address.
        // This is the smoking gun — no constructor ran, slot 0 is default.
        assertEq(
            governance.owner(),
            address(0),
            "vulnerability confirmed: Governance._owner == 0 at genesis (predeploy bypassed constructor)"
        );

        // Sanity: the temp-deployed twin (which DID run its constructor) has
        // a proper owner set, proving the bytecode itself is fine — the flaw
        // is purely the absence of storage seeding at the predeploy site.
        // (We don't keep a handle to tempGov after setUp; re-deploy one here.)
        Governance sanityGov = new Governance(intendedOwner);
        assertEq(
            sanityGov.owner(),
            intendedOwner,
            "sanity: normal CREATE sets _owner correctly"
        );

        // --- Assert 2: a post-genesis caller's `addExecutor` call reverts with
        // Ownable's unauthorized error. Use low-level `call` (not the typed
        // interface) so we can tolerate any revert reason and avoid coupling to
        // OZ's exact error signature encoding.
        address wouldBeExecutor = makeAddr("wouldBeExecutor");

        // anyCaller tries first.
        vm.prank(anyCaller);
        (bool okAny, ) = address(governance).call(
            abi.encodeWithSignature("addExecutor(address)", wouldBeExecutor)
        );
        assertFalse(
            okAny,
            "vulnerability confirmed: addExecutor must revert for any non-owner caller"
        );

        // Even the *intendedOwner* fails — because slot 0 is 0, not
        // intendedOwner. This is the key finding: the recovery path the
        // deployer would expect doesn't exist post-genesis.
        vm.prank(intendedOwner);
        (bool okIntended, ) = address(governance).call(
            abi.encodeWithSignature("addExecutor(address)", wouldBeExecutor)
        );
        assertFalse(
            okIntended,
            "vulnerability confirmed: even the *intended* owner cannot addExecutor because slot 0 was never seeded"
        );

        // --- Assert 3: the recovery paths are ALSO blocked.
        // transferOwnership is onlyOwner — blocked by same _owner==0.
        vm.prank(intendedOwner);
        (bool okXfer, ) = address(governance).call(
            abi.encodeWithSignature("transferOwnership(address)", intendedOwner)
        );
        assertFalse(okXfer, "transferOwnership is onlyOwner, also blocked");

        // acceptOwnership requires msg.sender == _pendingOwner; pendingOwner
        // slot is also zero at predeploy — and msg.sender cannot be address(0)
        // in a real tx.
        vm.prank(intendedOwner);
        (bool okAccept, ) = address(governance).call(
            abi.encodeWithSignature("acceptOwnership()")
        );
        assertFalse(okAccept, "acceptOwnership blocked: pendingOwner is also zero");

        // renounceOwnership is explicitly overridden to revert on Governance.
        vm.prank(intendedOwner);
        (bool okRenounce, ) = address(governance).call(
            abi.encodeWithSignature("renounceOwnership()")
        );
        assertFalse(okRenounce, "renounceOwnership is explicitly disabled");

        // --- Assert 4: because addExecutor can never succeed, the executor
        // set is empty — and any `execute()` call would revert with
        // NotExecutor(msg.sender). We don't construct a full SUCCEEDED proposal
        // here (that requires a staking+voting fixture); the executor-gate
        // observation is sufficient since onlyExecutor is the first check in
        // the execute() path.
        vm.prank(intendedOwner);
        (bool okExec, ) = address(governance).call(
            abi.encodeWithSignature(
                "execute(uint64,address[],bytes[])",
                uint64(1),
                new address[](0),
                new bytes[](0)
            )
        );
        assertFalse(
            okExec,
            "execute() revert-chain: no executors -> onlyExecutor fails -> proposal exec is bricked"
        );
    }
}
