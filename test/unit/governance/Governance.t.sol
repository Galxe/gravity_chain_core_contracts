// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { Governance } from "src/governance/Governance.sol";
import { IGovernance } from "src/governance/IGovernance.sol";
import { GovernanceConfig } from "src/runtime/GovernanceConfig.sol";
import { Staking } from "src/staking/Staking.sol";
import { StakePool } from "src/staking/StakePool.sol";
import { IStakePool } from "src/staking/IStakePool.sol";
import { Timestamp } from "src/runtime/Timestamp.sol";
import { StakingConfig } from "src/runtime/StakingConfig.sol";
import { Proposal, ProposalState, ValidatorStatus } from "src/foundation/Types.sol";
import { SystemAddresses } from "src/foundation/SystemAddresses.sol";
import { Errors } from "src/foundation/Errors.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

/// @notice Mock ValidatorManagement for testing - all pools are non-validators
contract MockValidatorManagement {
    function isValidator(
        address
    ) external pure returns (bool) {
        return false;
    }

    function getValidatorStatus(
        address
    ) external pure returns (ValidatorStatus) {
        return ValidatorStatus.INACTIVE;
    }
}

/// @title GovernanceTest
/// @notice Unit tests for Governance contract
contract GovernanceTest is Test {
    Governance public governance;
    GovernanceConfig public govConfig;
    Staking public staking;
    Timestamp public timestamp;
    StakingConfig public stakingConfig;

    // Test accounts
    address public owner = address(0x0BEEF);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public charlie = address(0xC4A1E);
    address public executor1 = address(0xE1);
    address public executor2 = address(0xE2);

    // Test values
    uint128 constant MIN_VOTING_THRESHOLD = 100 ether;
    uint256 constant REQUIRED_PROPOSER_STAKE = 50 ether;
    uint64 constant VOTING_DURATION_MICROS = 7 days * 1_000_000; // 7 days
    uint64 constant EXECUTION_DELAY_MICROS = 1 days * 1_000_000; // 1 day

    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant LOCKUP_DURATION_MICROS = 30 days * 1_000_000; // 30 days
    uint64 constant UNBONDING_DELAY_MICROS = 7 days * 1_000_000; // 7 days

    // Test target contract for execution
    MockTarget public mockTarget;

    function setUp() public {
        // Deploy Timestamp
        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        // Set initial time
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(address(0x1), 1_000_000_000_000); // ~Jan 2001 in microseconds

        // Deploy StakingConfig
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        // Initialize StakingConfig
        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION_MICROS, UNBONDING_DELAY_MICROS, REQUIRED_PROPOSER_STAKE);

        // Deploy Staking
        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        // Deploy mock ValidatorManagement - returns false for isValidator()
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new MockValidatorManagement()).code);

        // Deploy GovernanceConfig
        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);
        govConfig = GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);

        // Initialize GovernanceConfig
        vm.prank(SystemAddresses.GENESIS);
        govConfig.initialize(
            MIN_VOTING_THRESHOLD,
            REQUIRED_PROPOSER_STAKE,
            VOTING_DURATION_MICROS,
            1 days * 1_000_000,
            7 days * 1_000_000 // executionWindowMicros
        );

        // Deploy Governance with owner
        // Deploy to a temporary address first, then copy bytecode and storage to system address
        Governance tempGov = new Governance(owner);
        vm.etch(SystemAddresses.GOVERNANCE, address(tempGov).code);
        governance = Governance(SystemAddresses.GOVERNANCE);

        // Copy storage slots from temp deployment
        // Slot 0: _owner (address at offset 0)
        // Slot 1: _pendingOwner (address at offset 0) + nextProposalId (uint64 at offset 20)
        bytes32 slot0Value = vm.load(address(tempGov), bytes32(uint256(0)));
        bytes32 slot1Value = vm.load(address(tempGov), bytes32(uint256(1)));
        vm.store(SystemAddresses.GOVERNANCE, bytes32(uint256(0)), slot0Value);
        vm.store(SystemAddresses.GOVERNANCE, bytes32(uint256(1)), slot1Value);

        // Add default executor for tests (address(this) will be the executor for most tests)
        vm.prank(owner);
        governance.addExecutor(address(this));

        // Deploy mock target
        mockTarget = new MockTarget();

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(charlie, 1000 ether);
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _createStakePool(
        address poolOwner,
        uint256 amount
    ) internal returns (address) {
        uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION_MICROS;
        vm.prank(poolOwner);
        return staking.createPool{ value: amount }(poolOwner, poolOwner, poolOwner, poolOwner, lockedUntil);
    }

    function _computeExecutionHash(
        address target,
        bytes memory data
    ) internal pure returns (bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory datas = new bytes[](1);
        datas[0] = data;
        return keccak256(abi.encode(targets, datas));
    }

    function _computeBatchExecutionHash(
        address[] memory targets,
        bytes[] memory datas
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(targets, datas));
    }

    function _toArrays(
        address target,
        bytes memory data
    ) internal pure returns (address[] memory targets, bytes[] memory datas) {
        targets = new address[](1);
        targets[0] = target;
        datas = new bytes[](1);
        datas[0] = data;
    }

    function _advanceTime(
        uint64 micros
    ) internal {
        uint64 current = timestamp.nowMicroseconds();
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(address(0x1), current + micros);
    }

    // ========================================================================
    // CREATE PROPOSAL TESTS
    // ========================================================================

    function test_CreateProposal() public {
        // Create pool with sufficient stake
        address pool = _createStakePool(alice, 100 ether);

        // Prepare batch arrays (single call)
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        // Create proposal as pool's voter (alice is owner and default voter)
        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Verify proposal was created
        assertEq(proposalId, 1);
        assertEq(governance.getNextProposalId(), 2);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.id, proposalId);
        assertEq(proposal.proposer, alice);
        assertEq(proposal.executionHash, executionHash);
        assertEq(proposal.yesVotes, 0);
        assertEq(proposal.noVotes, 0);
        assertEq(proposal.isResolved, false);
    }

    function test_RevertWhen_CreateProposalInvalidPool() public {
        address invalidPool = address(0x1234);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, invalidPool));
        governance.createProposal(invalidPool, targets, datas, "ipfs://test");
    }

    function test_RevertWhen_CreateProposalNotVoter() public {
        // Create pool with alice as owner
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        // Bob tries to create proposal with alice's pool
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotDelegatedVoter.selector, alice, bob));
        governance.createProposal(pool, targets, datas, "ipfs://test");
    }

    function test_RevertWhen_CreateProposalInsufficientVotingPower() public {
        // Create pool with insufficient stake
        address pool = _createStakePool(alice, 10 ether); // Less than REQUIRED_PROPOSER_STAKE

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientVotingPower.selector, REQUIRED_PROPOSER_STAKE, 10 ether)
        );
        governance.createProposal(pool, targets, datas, "ipfs://test");
    }

    function test_RevertWhen_CreateProposalInsufficientLockup() public {
        // Create pool with sufficient stake
        address pool = _createStakePool(alice, 100 ether);

        // Advance time past lockup expiry so voting power is 0 at creation time
        // (GCC-010: voting power is now evaluated at creation time, not expiration time)
        _advanceTime(LOCKUP_DURATION_MICROS + 1);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        // Lockup has expired, so voting power at creation time = 0
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientVotingPower.selector, REQUIRED_PROPOSER_STAKE, 0));
        governance.createProposal(pool, targets, datas, "ipfs://test");
    }

    // ========================================================================
    // VOTE TESTS
    // ========================================================================

    function test_Vote() public {
        // Create pool and proposal
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote yes with full power
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 100 ether);
        assertEq(proposal.noVotes, 0);
    }

    function test_VotePartialPower() public {
        // Create pool and proposal
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote yes with partial power
        vm.prank(alice);
        governance.vote(pool, proposalId, 60 ether, true);

        // Check remaining power
        uint128 remaining = governance.getRemainingVotingPower(pool, proposalId);
        assertEq(remaining, 40 ether);

        // Vote no with remaining power
        vm.prank(alice);
        governance.vote(pool, proposalId, 40 ether, false);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 60 ether);
        assertEq(proposal.noVotes, 40 ether);
    }

    function test_VoteMultiplePools() public {
        // Create pools for alice and bob
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 50 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Alice votes yes
        vm.prank(alice);
        governance.vote(alicePool, proposalId, 100 ether, true);

        // Bob votes no
        vm.prank(bob);
        governance.vote(bobPool, proposalId, 50 ether, false);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 100 ether);
        assertEq(proposal.noVotes, 50 ether);
    }

    function test_RevertWhen_VoteProposalNotFound() public {
        address pool = _createStakePool(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, uint64(999)));
        governance.vote(pool, 999, 100 ether, true);
    }

    function test_RevertWhen_VoteAfterVotingPeriodEnded() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        Proposal memory proposal = governance.getProposal(proposalId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodEnded.selector, proposal.expirationTime));
        governance.vote(pool, proposalId, 100 ether, true);
    }

    function test_RevertWhen_VoteNotDelegatedVoter() public {
        address alicePool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Bob tries to vote with alice's pool
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotDelegatedVoter.selector, alice, bob));
        governance.vote(alicePool, proposalId, 100 ether, true);
    }

    function test_VoteSilentlyCapsPowerWhenExceedsRemaining() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote with full power
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Try to vote again - should silently do nothing (cap at 0 remaining power)
        vm.prank(alice);
        governance.vote(pool, proposalId, 1 ether, true);

        // Verify yesVotes unchanged (still 100 ether, not 101 ether)
        Proposal memory p = governance.getProposal(proposalId);
        assertEq(p.yesVotes, 100 ether, "yesVotes should remain at 100 ether");
    }

    // ========================================================================
    // RESOLVE TESTS
    // ========================================================================

    function test_ResolveAfterVotingPeriod() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        // Resolve
        governance.resolve(proposalId);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertTrue(proposal.isResolved);
        assertGt(proposal.resolutionTime, 0);
    }

    function test_ResolveSucceeded() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote yes with enough power to meet threshold
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        // Resolve
        governance.resolve(proposalId);

        assertEq(uint8(governance.getProposalState(proposalId)), uint8(ProposalState.SUCCEEDED));
    }

    function test_ResolveFailed_NoQuorum() public {
        address pool = _createStakePool(alice, 50 ether); // Less than MIN_VOTING_THRESHOLD

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote yes but not enough for quorum
        vm.prank(alice);
        governance.vote(pool, proposalId, 50 ether, true);

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        // Resolve
        governance.resolve(proposalId);

        assertEq(uint8(governance.getProposalState(proposalId)), uint8(ProposalState.FAILED));
    }

    function test_ResolveFailed_MoreNoVotes() public {
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 150 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Alice votes yes
        vm.prank(alice);
        governance.vote(alicePool, proposalId, 100 ether, true);

        // Bob votes no with more power
        vm.prank(bob);
        governance.vote(bobPool, proposalId, 150 ether, false);

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        // Resolve
        governance.resolve(proposalId);

        assertEq(uint8(governance.getProposalState(proposalId)), uint8(ProposalState.FAILED));
    }

    function test_RevertWhen_ResolveProposalNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, uint64(999)));
        governance.resolve(999);
    }

    function test_RevertWhen_ResolveAlreadyResolved() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);

        // Try to resolve again
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalAlreadyResolved.selector, proposalId));
        governance.resolve(proposalId);
    }

    function test_RevertWhen_ResolveVotingNotEnded() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        Proposal memory proposal = governance.getProposal(proposalId);

        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodNotEnded.selector, proposal.expirationTime));
        governance.resolve(proposalId);
    }

    // ========================================================================
    // EXECUTE TESTS
    // ========================================================================

    function test_Execute() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Execute
        governance.execute(proposalId, targets, datas);

        // Verify execution
        assertEq(mockTarget.value(), 42);
        assertTrue(governance.isExecuted(proposalId));
        assertEq(uint8(governance.getProposalState(proposalId)), uint8(ProposalState.EXECUTED));
    }

    function test_RevertWhen_ExecuteProposalNotFound() public {
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, uint64(999)));
        governance.execute(999, targets, datas);
    }

    function test_RevertWhen_ExecuteProposalNotSucceeded() public {
        address pool = _createStakePool(alice, 50 ether); // Less than MIN_VOTING_THRESHOLD

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote but not enough for quorum
        vm.prank(alice);
        governance.vote(pool, proposalId, 50 ether, true);

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Try to execute failed proposal
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotSucceeded.selector, proposalId));
        governance.execute(proposalId, targets, datas);
    }

    function test_RevertWhen_ExecuteAlreadyExecuted() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote, resolve, execute
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);
        governance.execute(proposalId, targets, datas);

        // Try to execute again
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalAlreadyExecuted.selector, proposalId));
        governance.execute(proposalId, targets, datas);
    }

    function test_RevertWhen_ExecuteHashMismatch() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote and resolve
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Try to execute with wrong data
        bytes memory wrongData = abi.encodeWithSignature("setValue(uint256)", 999);
        (address[] memory wrongTargets, bytes[] memory wrongDatas) = _toArrays(address(mockTarget), wrongData);
        bytes32 wrongHash = _computeExecutionHash(address(mockTarget), wrongData);

        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionHashMismatch.selector, executionHash, wrongHash));
        governance.execute(proposalId, wrongTargets, wrongDatas);
    }

    function test_RevertWhen_ExecutionFails() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("revertingFunction()");
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote and resolve
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Execute should fail
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector, proposalId));
        governance.execute(proposalId, targets, datas);
    }

    // ========================================================================
    // DELEGATED VOTING TESTS
    // ========================================================================

    function test_DelegatedVoting() public {
        // Alice creates pool and delegates voting to Bob
        address pool = _createStakePool(alice, 100 ether);

        vm.prank(alice);
        IStakePool(pool).setVoter(bob);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        // Bob creates proposal using alice's pool
        vm.prank(bob);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Bob votes using alice's pool
        vm.prank(bob);
        governance.vote(pool, proposalId, 100 ether, true);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.proposer, bob);
        assertEq(proposal.yesVotes, 100 ether);
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_EmitProposalCreated() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IGovernance.ProposalCreated(1, alice, pool, executionHash, "ipfs://test");
        governance.createProposal(pool, targets, datas, "ipfs://test");
    }

    function test_EmitVoteCast() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IGovernance.VoteCast(proposalId, alice, pool, 100 ether, true);
        governance.vote(pool, proposalId, 100 ether, true);
    }

    function test_EmitProposalResolved() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);

        vm.expectEmit(true, false, false, true);
        emit IGovernance.ProposalResolved(proposalId, ProposalState.SUCCEEDED);
        governance.resolve(proposalId);
    }

    function test_EmitProposalExecuted() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        vm.expectEmit(true, true, false, true);
        emit IGovernance.ProposalExecuted(proposalId, address(this), targets, datas);
        governance.execute(proposalId, targets, datas);
    }

    // ========================================================================
    // EXECUTOR MANAGEMENT TESTS
    // ========================================================================

    function test_AddExecutor() public {
        // Owner adds an executor
        vm.prank(owner);
        governance.addExecutor(executor1);

        // Verify executor was added
        assertTrue(governance.isExecutor(executor1));
        assertEq(governance.getExecutorCount(), 2); // address(this) + executor1
    }

    function test_AddExecutor_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IGovernance.ExecutorAdded(executor1);
        governance.addExecutor(executor1);
    }

    function test_AddExecutor_NoEventIfAlreadyExecutor() public {
        // Add executor first time
        vm.prank(owner);
        governance.addExecutor(executor1);

        // Adding again should not emit event (EnumerableSet.add returns false)
        vm.prank(owner);
        vm.recordLogs();
        governance.addExecutor(executor1);

        // Should have no ExecutorAdded event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != keccak256("ExecutorAdded(address)"));
        }
    }

    function test_RemoveExecutor() public {
        // Add executor first
        vm.prank(owner);
        governance.addExecutor(executor1);

        assertTrue(governance.isExecutor(executor1));

        // Remove executor
        vm.prank(owner);
        governance.removeExecutor(executor1);

        assertFalse(governance.isExecutor(executor1));
    }

    function test_RemoveExecutor_EmitsEvent() public {
        // Add executor first
        vm.prank(owner);
        governance.addExecutor(executor1);

        // Remove and check event
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IGovernance.ExecutorRemoved(executor1);
        governance.removeExecutor(executor1);
    }

    function test_RemoveExecutor_NoEventIfNotExecutor() public {
        // Try to remove non-existent executor
        vm.prank(owner);
        vm.recordLogs();
        governance.removeExecutor(executor1);

        // Should have no ExecutorRemoved event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != keccak256("ExecutorRemoved(address)"));
        }
    }

    function test_RevertWhen_AddExecutorNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        governance.addExecutor(executor1);
    }

    function test_RevertWhen_RemoveExecutorNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        governance.removeExecutor(executor1);
    }

    function test_GetExecutors() public {
        // Add two executors
        vm.startPrank(owner);
        governance.addExecutor(executor1);
        governance.addExecutor(executor2);
        vm.stopPrank();

        address[] memory executors = governance.getExecutors();
        assertEq(executors.length, 3); // address(this) + executor1 + executor2

        // Check all executors are in the array (order may vary)
        bool foundThis;
        bool foundExecutor1;
        bool foundExecutor2;
        for (uint256 i = 0; i < executors.length; i++) {
            if (executors[i] == address(this)) foundThis = true;
            if (executors[i] == executor1) foundExecutor1 = true;
            if (executors[i] == executor2) foundExecutor2 = true;
        }
        assertTrue(foundThis);
        assertTrue(foundExecutor1);
        assertTrue(foundExecutor2);
    }

    function test_GetExecutorCount() public {
        assertEq(governance.getExecutorCount(), 1); // address(this)

        vm.prank(owner);
        governance.addExecutor(executor1);
        assertEq(governance.getExecutorCount(), 2);

        vm.prank(owner);
        governance.addExecutor(executor2);
        assertEq(governance.getExecutorCount(), 3);

        vm.prank(owner);
        governance.removeExecutor(executor1);
        assertEq(governance.getExecutorCount(), 2);
    }

    function test_IsExecutor() public {
        assertFalse(governance.isExecutor(executor1));

        vm.prank(owner);
        governance.addExecutor(executor1);

        assertTrue(governance.isExecutor(executor1));
        assertFalse(governance.isExecutor(executor2));
    }

    function test_RevertWhen_ExecuteNotExecutor() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Bob (not an executor) tries to execute
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotExecutor.selector, bob));
        governance.execute(proposalId, targets, datas);
    }

    function test_ExecuteAsAddedExecutor() public {
        // Add executor1 as an executor
        vm.prank(owner);
        governance.addExecutor(executor1);

        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // executor1 executes the proposal
        vm.prank(executor1);
        governance.execute(proposalId, targets, datas);

        // Verify execution
        assertEq(mockTarget.value(), 42);
        assertTrue(governance.isExecuted(proposalId));
    }

    function test_RevertWhen_ExecuteAfterExecutorRemoved() public {
        // Add and then remove executor1
        vm.startPrank(owner);
        governance.addExecutor(executor1);
        governance.removeExecutor(executor1);
        vm.stopPrank();

        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // executor1 (now removed) tries to execute
        vm.prank(executor1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotExecutor.selector, executor1));
        governance.execute(proposalId, targets, datas);
    }

    // ========================================================================
    // BATCH VOTING TESTS
    // ========================================================================

    function test_BatchVote() public {
        // Create pools for alice and bob
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 50 ether);

        // Bob delegates voting to alice so she can vote with both pools
        vm.prank(bob);
        IStakePool(bobPool).setVoter(alice);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Alice batch votes with both pools using full power
        address[] memory pools = new address[](2);
        pools[0] = alicePool;
        pools[1] = bobPool;

        vm.prank(alice);
        governance.batchVote(pools, proposalId, true);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 150 ether); // 100 + 50
        assertEq(proposal.noVotes, 0);

        // Verify all voting power was used
        assertEq(governance.getRemainingVotingPower(alicePool, proposalId), 0);
        assertEq(governance.getRemainingVotingPower(bobPool, proposalId), 0);
    }

    function test_BatchVote_EmitsEventsForEachPool() public {
        // Create pools for alice and bob
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 50 ether);

        // Bob delegates voting to alice
        vm.prank(bob);
        IStakePool(bobPool).setVoter(alice);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        address[] memory pools = new address[](2);
        pools[0] = alicePool;
        pools[1] = bobPool;

        // Expect events for each pool
        vm.expectEmit(true, true, true, true);
        emit IGovernance.VoteCast(proposalId, alice, alicePool, 100 ether, true);
        vm.expectEmit(true, true, true, true);
        emit IGovernance.VoteCast(proposalId, alice, bobPool, 50 ether, true);

        vm.prank(alice);
        governance.batchVote(pools, proposalId, true);
    }

    function test_BatchVote_SkipsPoolsWithZeroRemainingPower() public {
        // Create pool
        address alicePool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Vote with all power first
        vm.prank(alice);
        governance.vote(alicePool, proposalId, 100 ether, true);

        // Batch vote with same pool again - should skip silently
        address[] memory pools = new address[](1);
        pools[0] = alicePool;

        vm.prank(alice);
        governance.batchVote(pools, proposalId, true); // Should not revert

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 100 ether); // No additional votes
    }

    function test_BatchPartialVote() public {
        // Create pools for alice and bob
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 50 ether);

        // Bob delegates voting to alice
        vm.prank(bob);
        IStakePool(bobPool).setVoter(alice);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Alice batch partial votes with 30 ether from each pool
        address[] memory pools = new address[](2);
        pools[0] = alicePool;
        pools[1] = bobPool;

        vm.prank(alice);
        governance.batchPartialVote(pools, proposalId, 30 ether, false);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 0);
        assertEq(proposal.noVotes, 60 ether); // 30 + 30

        // Verify remaining voting power
        assertEq(governance.getRemainingVotingPower(alicePool, proposalId), 70 ether);
        assertEq(governance.getRemainingVotingPower(bobPool, proposalId), 20 ether);
    }

    function test_BatchPartialVote_CapsAtRemainingPower() public {
        // Create a large pool and a small pool
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 20 ether);

        // Bob delegates voting to alice
        vm.prank(bob);
        IStakePool(bobPool).setVoter(alice);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Try to batch partial vote with more than bob's pool has available
        address[] memory pools = new address[](1);
        pools[0] = bobPool;

        vm.prank(alice);
        governance.batchPartialVote(pools, proposalId, 100 ether, true); // Request 100, only 20 available

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 20 ether); // Capped at 20

        assertEq(governance.getRemainingVotingPower(bobPool, proposalId), 0);
    }

    function test_BatchVote_RevertWhen_ProposalNotFound() public {
        address alicePool = _createStakePool(alice, 100 ether);

        address[] memory pools = new address[](1);
        pools[0] = alicePool;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, uint64(999)));
        governance.batchVote(pools, 999, true);
    }

    function test_BatchVote_RevertWhen_VotingPeriodEnded() public {
        address alicePool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        address[] memory pools = new address[](1);
        pools[0] = alicePool;

        Proposal memory proposal = governance.getProposal(proposalId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodEnded.selector, proposal.expirationTime));
        governance.batchVote(pools, proposalId, true);
    }

    function test_BatchVote_RevertWhen_NotDelegatedVoter() public {
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 50 ether); // Bob is voter of his own pool

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Alice tries to batch vote with bob's pool (not delegated to her)
        address[] memory pools = new address[](2);
        pools[0] = alicePool;
        pools[1] = bobPool;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotDelegatedVoter.selector, bob, alice));
        governance.batchVote(pools, proposalId, true);
    }

    function test_BatchVote_RevertWhen_InvalidPool() public {
        address alicePool = _createStakePool(alice, 100 ether);
        address invalidPool = address(0x1234);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        address[] memory pools = new address[](2);
        pools[0] = alicePool;
        pools[1] = invalidPool;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, invalidPool));
        governance.batchVote(pools, proposalId, true);
    }

    function test_BatchVote_EmptyArray() public {
        address alicePool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        address[] memory pools = new address[](0);

        // Should not revert, just do nothing
        vm.prank(alice);
        governance.batchVote(pools, proposalId, true);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 0);
        assertEq(proposal.noVotes, 0);
    }

    function test_BatchPartialVote_MultipleRounds() public {
        // Create pools
        address alicePool = _createStakePool(alice, 100 ether);
        address bobPool = _createStakePool(bob, 50 ether);

        // Bob delegates voting to alice
        vm.prank(bob);
        IStakePool(bobPool).setVoter(alice);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        address[] memory pools = new address[](2);
        pools[0] = alicePool;
        pools[1] = bobPool;

        // First round: vote yes with 20 ether each
        vm.prank(alice);
        governance.batchPartialVote(pools, proposalId, 20 ether, true);

        // Second round: vote no with 15 ether each
        vm.prank(alice);
        governance.batchPartialVote(pools, proposalId, 15 ether, false);

        Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.yesVotes, 40 ether); // 20 + 20
        assertEq(proposal.noVotes, 30 ether); // 15 + 15

        // Verify remaining voting power
        assertEq(governance.getRemainingVotingPower(alicePool, proposalId), 65 ether); // 100 - 35
        assertEq(governance.getRemainingVotingPower(bobPool, proposalId), 15 ether); // 50 - 35
    }

    // ========================================================================
    // ATOMICITY GUARD TESTS (Flash Loan Protection)
    // ========================================================================

    function test_LastVoteTimeRecorded() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Initially no votes, lastVoteTime should be 0
        assertEq(governance.getLastVoteTime(proposalId), 0);

        uint64 beforeVote = timestamp.nowMicroseconds();

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 50 ether, true);

        // lastVoteTime should be recorded
        uint64 lastVote = governance.getLastVoteTime(proposalId);
        assertEq(lastVote, beforeVote);
    }

    function test_LastVoteTimeUpdatesOnEachVote() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // First vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 30 ether, true);

        uint64 firstVoteTime = governance.getLastVoteTime(proposalId);

        // Advance time
        _advanceTime(1_000_000); // 1 second

        // Second vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 30 ether, false);

        uint64 secondVoteTime = governance.getLastVoteTime(proposalId);
        assertGt(secondVoteTime, firstVoteTime);
    }

    function test_AtomicityGuard_CannotResolveInSameTimestamp() public {
        // This test verifies the atomicity guard works correctly:
        // - Resolution must happen strictly after the last vote time
        // - This prevents flash loan attacks where someone votes and resolves in the same tx

        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Verify last vote time is set
        uint64 lastVoteTs = governance.getLastVoteTime(proposalId);
        assertGt(lastVoteTs, 0);

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        // Resolution should succeed because we're past the last vote time
        assertTrue(governance.canResolve(proposalId));
        governance.resolve(proposalId);

        assertTrue(governance.getProposal(proposalId).isResolved);
    }

    function test_CanResolve_ReturnsTrueAfterVotingEnds() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // canResolve should be false initially (voting not ended)
        assertFalse(governance.canResolve(proposalId));

        // Advance time just past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        // Now voting period ended - canResolve should be true (even with no votes)
        assertTrue(governance.canResolve(proposalId));
    }

    function test_AtomicityGuard_LastMinuteVote() public {
        // Create a pool with sufficient lockup
        uint64 longLockup = LOCKUP_DURATION_MICROS + VOTING_DURATION_MICROS;
        uint64 lockedUntil = timestamp.nowMicroseconds() + longLockup;
        vm.prank(alice);
        address pool = staking.createPool{ value: 100 ether }(alice, alice, alice, alice, lockedUntil);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Advance time to just before voting period ends (1 microsecond before)
        _advanceTime(VOTING_DURATION_MICROS - 1);

        // Cast a vote at the last moment
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        uint64 lastVoteTimestamp = governance.getLastVoteTime(proposalId);

        // Now advance time by exactly 1 microsecond (voting period now ended)
        _advanceTime(1);

        uint64 currentTime = timestamp.nowMicroseconds();

        // Verify: current time equals expiration, but also equals last vote time
        Proposal memory p = governance.getProposal(proposalId);
        assertEq(currentTime, p.expirationTime);
        assertEq(currentTime, lastVoteTimestamp + 1); // We're 1 microsecond after the vote

        // Since we're strictly after the last vote time, resolution should work
        assertTrue(governance.canResolve(proposalId));
        governance.resolve(proposalId);

        assertTrue(governance.getProposal(proposalId).isResolved);
    }

    function test_AtomicityGuard_SimulatedFlashLoan() public {
        // This test simulates a flash loan attack scenario where:
        // 1. Attacker creates a stake pool with borrowed tokens
        // 2. Votes on a proposal right before expiration
        // 3. Tries to resolve immediately after expiration
        // The atomicity guard prevents resolution in the same timestamp as the last vote

        // Create a pool with sufficient lockup
        uint64 longLockup = LOCKUP_DURATION_MICROS + VOTING_DURATION_MICROS;
        uint64 lockedUntil = timestamp.nowMicroseconds() + longLockup;
        vm.prank(alice);
        address alicePool = staking.createPool{ value: 100 ether }(alice, alice, alice, alice, lockedUntil);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Advance time to just before voting ends
        _advanceTime(VOTING_DURATION_MICROS - 1);

        // Vote right before expiration
        vm.prank(alice);
        governance.vote(alicePool, proposalId, 100 ether, true);

        // Advance 1 microsecond - now at expiration
        _advanceTime(1);

        // We're at expiration, but strictly after the last vote
        // Resolution should succeed
        assertTrue(governance.canResolve(proposalId));
        governance.resolve(proposalId);

        assertTrue(governance.getProposal(proposalId).isResolved);
    }

    function test_AtomicityGuard_VoteThenResolve_SameBlock() public {
        // Test that you cannot vote and resolve in the exact same timestamp
        // This requires the voting period to end exactly when someone votes

        // Create a pool with very long lockup to ensure voting power persists
        uint64 veryLongLockup = LOCKUP_DURATION_MICROS * 10;
        uint64 lockedUntil = timestamp.nowMicroseconds() + veryLongLockup;

        vm.prank(alice);
        address alicePool = staking.createPool{ value: 100 ether }(alice, alice, alice, alice, lockedUntil);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, targets, datas, "ipfs://test");

        // Advance to 1 microsecond before voting ends
        _advanceTime(VOTING_DURATION_MICROS - 1);

        // Vote
        vm.prank(alice);
        governance.vote(alicePool, proposalId, 100 ether, true);

        // At this point:
        // - Voting period has NOT ended yet (expirationTime is 1 microsecond in the future)
        // - Last vote time is NOW
        assertFalse(governance.canResolve(proposalId), "Should not be resolvable before expiration");

        // Don't advance time - try to resolve immediately
        // (This should fail because voting period hasn't ended)
        Proposal memory p = governance.getProposal(proposalId);
        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodNotEnded.selector, p.expirationTime));
        governance.resolve(proposalId);

        // Now advance time by 1 microsecond
        // This puts us exactly at the expiration time
        _advanceTime(1);

        // Now the voting period has ended
        // And we're exactly 1 microsecond after the last vote
        // This should be resolvable (strictly greater than last vote time)
        assertTrue(governance.canResolve(proposalId));
        governance.resolve(proposalId);
    }

    function test_AtomicityGuard_ProposalWithNoVotes() public {
        // Test that proposals with no votes can be resolved normally
        // (lastVoteTime == 0 should not block resolution)

        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Verify no votes cast
        assertEq(governance.getLastVoteTime(proposalId), 0);

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        // Should be able to resolve even with no votes
        assertTrue(governance.canResolve(proposalId));
        governance.resolve(proposalId);

        // Proposal should be resolved (and failed due to no quorum)
        assertTrue(governance.getProposal(proposalId).isResolved);
        assertEq(uint8(governance.getProposalState(proposalId)), uint8(ProposalState.FAILED));
    }

    function test_GetLastVoteTime() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        // Before any vote, should be 0
        assertEq(governance.getLastVoteTime(proposalId), 0);

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 50 ether, true);

        // Should match current time
        assertEq(governance.getLastVoteTime(proposalId), timestamp.nowMicroseconds());
    }

    // ========================================================================
    // BATCH PROPOSAL EXECUTION TESTS
    // ========================================================================

    function test_BatchExecute_MultipleCalls() public {
        // Create pool and deploy another mock target
        address pool = _createStakePool(alice, 100 ether);
        MockTarget mockTarget2 = new MockTarget();

        // Create batch with two calls
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget2);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSignature("setValue(uint256)", 42);
        datas[1] = abi.encodeWithSignature("setValue(uint256)", 100);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://batch-test");

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Execute
        governance.execute(proposalId, targets, datas);

        // Verify both targets were updated
        assertEq(mockTarget.value(), 42);
        assertEq(mockTarget2.value(), 100);
        assertTrue(governance.isExecuted(proposalId));
    }

    function test_BatchExecute_AtomicRollback() public {
        // Create pool
        address pool = _createStakePool(alice, 100 ether);

        // Create batch where second call will fail
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSignature("setValue(uint256)", 42);
        datas[1] = abi.encodeWithSignature("revertingFunction()");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://failing-batch");

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Execute should fail and revert all changes atomically
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector, proposalId));
        governance.execute(proposalId, targets, datas);

        // Verify first call was rolled back (value should still be 0)
        assertEq(mockTarget.value(), 0);
        assertFalse(governance.isExecuted(proposalId));
    }

    function test_ComputeExecutionHash() public view {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(0x123);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSignature("setValue(uint256)", 42);
        datas[1] = abi.encodeWithSignature("foo()");

        // Compute hash using the helper function
        bytes32 hash = governance.computeExecutionHash(targets, datas);

        // Should match manual computation
        bytes32 expected = keccak256(abi.encode(targets, datas));
        assertEq(hash, expected);
    }

    function test_RevertWhen_CreateProposalEmptyBatch() public {
        address pool = _createStakePool(alice, 100 ether);

        address[] memory targets = new address[](0);
        bytes[] memory datas = new bytes[](0);

        vm.prank(alice);
        vm.expectRevert(Errors.EmptyProposalBatch.selector);
        governance.createProposal(pool, targets, datas, "ipfs://empty");
    }

    function test_RevertWhen_CreateProposalArrayLengthMismatch() public {
        address pool = _createStakePool(alice, 100 ether);

        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature("setValue(uint256)", 42);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalArrayLengthMismatch.selector, 2, 1));
        governance.createProposal(pool, targets, datas, "ipfs://mismatch");
    }

    function test_RevertWhen_ExecuteEmptyBatch() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Try to execute with empty arrays
        address[] memory emptyTargets = new address[](0);
        bytes[] memory emptyDatas = new bytes[](0);

        vm.expectRevert(Errors.EmptyProposalBatch.selector);
        governance.execute(proposalId, emptyTargets, emptyDatas);
    }

    function test_RevertWhen_ExecuteArrayLengthMismatch() public {
        address pool = _createStakePool(alice, 100 ether);

        (address[] memory targets, bytes[] memory datas) = _toArrays(address(mockTarget), "");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, targets, datas, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        _advanceTime(EXECUTION_DELAY_MICROS);

        // Try to execute with mismatched arrays
        address[] memory mismatchTargets = new address[](2);
        mismatchTargets[0] = address(mockTarget);
        mismatchTargets[1] = address(mockTarget);

        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalArrayLengthMismatch.selector, 2, 1));
        governance.execute(proposalId, mismatchTargets, datas);
    }
}

/// @notice Mock target contract for testing governance execution
contract MockTarget {
    uint256 public value;

    function setValue(
        uint256 _value
    ) external {
        value = _value;
    }

    function revertingFunction() external pure {
        revert("MockTarget: always reverts");
    }
}

