// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DeltaHardforkBase } from "./DeltaHardforkBase.t.sol";
import { Governance } from "../../src/governance/Governance.sol";
import { IGovernance } from "../../src/governance/IGovernance.sol";
import { GovernanceConfig } from "../../src/runtime/GovernanceConfig.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title DeltaGovernanceUpgradeTest
/// @notice Tests for Governance after Delta hardfork bytecode replacement.
///         Key concerns from PR #58:
///         - MAX_PROPOSAL_TARGETS limit enforcement (DoS prevention)
///         - ProposalNotResolved check in execute (must resolve before execute)
///         - renounceOwnership still blocked (from Gamma)
contract DeltaGovernanceUpgradeTest is DeltaHardforkBase {
    address public pool1;
    Governance public governance;

    function setUp() public override {
        super.setUp();

        // Deploy Governance at its system address
        // Governance has constructor(address initialOwner) — we'll use alice as owner
        vm.etch(SystemAddresses.GOVERNANCE, address(new Governance(alice)).code);

        // Need to set the owner storage since vm.etch only copies code, not storage
        // Ownable2Step stores owner at slot 0
        vm.store(SystemAddresses.GOVERNANCE, bytes32(uint256(0)), bytes32(uint256(uint160(alice))));

        // nextProposalId is at slot 1 offset 20 (packed with _pendingOwner at offset 0)
        // _pendingOwner = address(0), nextProposalId = 1
        // Layout: [unused 4 bytes][nextProposalId: 8 bytes][_pendingOwner: 20 bytes]
        vm.store(SystemAddresses.GOVERNANCE, bytes32(uint256(1)), bytes32(uint256(1) << 160));

        governance = Governance(SystemAddresses.GOVERNANCE);

        // Create a pool for governance tests with enough stake for proposals
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 10, "alice");
        _createRegisterAndJoin(bob, MIN_BOND * 3, "bob");
        _processEpoch();

        _applyDeltaHardfork();
    }

    // ========================================================================
    // MAX_PROPOSAL_TARGETS LIMIT (PR #58)
    // ========================================================================

    /// @notice Verify MAX_PROPOSAL_TARGETS constant is set to 100
    function test_maxProposalTargets_constant() public view {
        assertEq(governance.MAX_PROPOSAL_TARGETS(), 100, "MAX_PROPOSAL_TARGETS should be 100");
    }

    /// @notice Test that proposals with too many targets are rejected
    function test_maxProposalTargets_tooManyReverts() public {
        uint256 tooMany = 101;

        address[] memory targets = new address[](tooMany);
        bytes[] memory datas = new bytes[](tooMany);

        for (uint256 i = 0; i < tooMany; i++) {
            targets[i] = address(uint160(i + 1));
            datas[i] = hex"";
        }

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyProposalTargets.selector, tooMany, 100));
        governance.createProposal(pool1, targets, datas, "too many targets");
    }

    /// @notice Test that proposals at the limit (100 targets) are accepted
    function test_maxProposalTargets_atLimitAccepted() public {
        uint256 atLimit = 100;

        address[] memory targets = new address[](atLimit);
        bytes[] memory datas = new bytes[](atLimit);

        for (uint256 i = 0; i < atLimit; i++) {
            targets[i] = address(uint160(i + 1));
            datas[i] = hex"";
        }

        // Should not revert (proposal creation succeeds)
        vm.prank(alice);
        governance.createProposal(pool1, targets, datas, "at limit");
    }

    // ========================================================================
    // PROPOSAL NOT RESOLVED CHECK (PR #58)
    // ========================================================================

    /// @notice Test that executing an unresolved proposal reverts
    function test_proposalNotResolved_executeReverts() public {
        // Create a simple proposal
        address[] memory targets = new address[](1);
        targets[0] = SystemAddresses.STAKE_CONFIG;
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature(
            "setForNextEpoch(uint256,uint64,uint64)", 5 ether, LOCKUP_DURATION, UNBONDING_DELAY
        );

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool1, targets, datas, "test proposal");

        // Add alice as executor
        vm.prank(alice);
        governance.addExecutor(alice);

        // Advance time past voting period
        _advanceTime(7 days * 1_000_000 + 1);

        // Try to execute without resolving — should revert with ProposalNotResolved
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotResolved.selector, proposalId));
        governance.execute(proposalId, targets, datas);
    }

    // ========================================================================
    // EXISTING GOVERNANCE FEATURES STILL WORK
    // ========================================================================

    /// @notice Test that renounceOwnership is still blocked
    function test_governance_renounceOwnershipReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OperationNotSupported.selector);
        governance.renounceOwnership();
    }

    /// @notice Test GovernanceConfig rejects minVotingThreshold = 0
    function test_governanceConfig_zeroMinVotingThreshold() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert();
        governanceConfig.setForNextEpoch(0, MIN_PROPOSAL_STAKE, 7 days * 1_000_000);
    }

    /// @notice Test GovernanceConfig rejects requiredProposerStake = 0
    function test_governanceConfig_zeroRequiredProposerStake() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert();
        governanceConfig.setForNextEpoch(50, 0, 7 days * 1_000_000);
    }
}
