// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Governance } from "src/governance/Governance.sol";
import { IGovernance } from "src/governance/IGovernance.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Staking } from "src/staking/Staking.sol";
import { StakePool } from "src/staking/StakePool.sol";
import { IStakePool } from "src/staking/IStakePool.sol";
import { Timestamp } from "src/runtime/Timestamp.sol";
import { StakingConfig } from "src/runtime/StakingConfig.sol";
import { Proposal, ProposalState, ValidatorStatus } from "src/foundation/Types.sol";
import { SystemAddresses } from "src/foundation/SystemAddresses.sol";
import { Errors } from "src/foundation/Errors.sol";

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
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public charlie = address(0xC4A1E);

    // Test values
    uint128 constant MIN_VOTING_THRESHOLD = 100 ether;
    uint256 constant REQUIRED_PROPOSER_STAKE = 50 ether;
    uint64 constant VOTING_DURATION_MICROS = 7 days * 1_000_000; // 7 days
    uint128 constant EARLY_RESOLUTION_THRESHOLD_BPS = 5000; // 50%

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
            MIN_VOTING_THRESHOLD, REQUIRED_PROPOSER_STAKE, VOTING_DURATION_MICROS, EARLY_RESOLUTION_THRESHOLD_BPS
        );

        // Deploy Governance
        vm.etch(SystemAddresses.GOVERNANCE, address(new Governance()).code);
        governance = Governance(SystemAddresses.GOVERNANCE);

        // Initialize Governance
        vm.prank(SystemAddresses.GENESIS);
        governance.initialize();

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
        address owner,
        uint256 amount
    ) internal returns (address) {
        uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION_MICROS;
        vm.prank(owner);
        return staking.createPool{ value: amount }(owner, owner, owner, owner, lockedUntil);
    }

    function _computeExecutionHash(
        address target,
        bytes memory data
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, data));
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

        // Compute execution hash
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        // Create proposal as pool's voter (alice is owner and default voter)
        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, invalidPool));
        governance.createProposal(invalidPool, executionHash, "ipfs://test");
    }

    function test_RevertWhen_CreateProposalNotVoter() public {
        // Create pool with alice as owner
        address pool = _createStakePool(alice, 100 ether);

        bytes32 executionHash = keccak256("test");

        // Bob tries to create proposal with alice's pool
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotDelegatedVoter.selector, alice, bob));
        governance.createProposal(pool, executionHash, "ipfs://test");
    }

    function test_RevertWhen_CreateProposalInsufficientVotingPower() public {
        // Create pool with insufficient stake
        address pool = _createStakePool(alice, 10 ether); // Less than REQUIRED_PROPOSER_STAKE

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientVotingPower.selector, REQUIRED_PROPOSER_STAKE, 10 ether)
        );
        governance.createProposal(pool, executionHash, "ipfs://test");
    }

    function test_RevertWhen_CreateProposalInsufficientLockup() public {
        // Create pool with sufficient stake
        address pool = _createStakePool(alice, 100 ether);

        // Advance time so lockup expires before voting would end
        _advanceTime(LOCKUP_DURATION_MICROS - VOTING_DURATION_MICROS + 1);

        bytes32 executionHash = keccak256("test");

        uint64 now_ = timestamp.nowMicroseconds();
        uint64 requiredLockup = now_ + VOTING_DURATION_MICROS;
        uint64 actualLockup = IStakePool(pool).getLockedUntil();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientLockup.selector, requiredLockup, actualLockup));
        governance.createProposal(pool, executionHash, "ipfs://test");
    }

    // ========================================================================
    // VOTE TESTS
    // ========================================================================

    function test_Vote() public {
        // Create pool and proposal
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Advance time past voting period
        _advanceTime(VOTING_DURATION_MICROS + 1);

        Proposal memory proposal = governance.getProposal(proposalId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPeriodEnded.selector, proposal.expirationTime));
        governance.vote(pool, proposalId, 100 ether, true);
    }

    function test_RevertWhen_VoteNotDelegatedVoter() public {
        address alicePool = _createStakePool(alice, 100 ether);

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, executionHash, "ipfs://test");

        // Bob tries to vote with alice's pool
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotDelegatedVoter.selector, alice, bob));
        governance.vote(alicePool, proposalId, 100 ether, true);
    }

    function test_RevertWhen_VoteExceedsRemainingPower() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Vote with full power
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Try to vote again
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VotingPowerOverflow.selector, uint128(1 ether), uint128(0)));
        governance.vote(pool, proposalId, 1 ether, true);
    }

    // ========================================================================
    // RESOLVE TESTS
    // ========================================================================

    function test_ResolveAfterVotingPeriod() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(alicePool, executionHash, "ipfs://test");

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

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);

        // Try to resolve again
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalAlreadyResolved.selector, proposalId));
        governance.resolve(proposalId);
    }

    function test_RevertWhen_ResolveVotingNotEnded() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Vote
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);

        // Execute
        governance.execute(proposalId, address(mockTarget), data);

        // Verify execution
        assertEq(mockTarget.value(), 42);
        assertTrue(governance.isExecuted(proposalId));
        assertEq(uint8(governance.getProposalState(proposalId)), uint8(ProposalState.EXECUTED));
    }

    function test_RevertWhen_ExecuteProposalNotFound() public {
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);

        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotFound.selector, uint64(999)));
        governance.execute(999, address(mockTarget), data);
    }

    function test_RevertWhen_ExecuteProposalNotSucceeded() public {
        address pool = _createStakePool(alice, 50 ether); // Less than MIN_VOTING_THRESHOLD

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Vote but not enough for quorum
        vm.prank(alice);
        governance.vote(pool, proposalId, 50 ether, true);

        // Advance time and resolve
        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);

        // Try to execute failed proposal
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalNotSucceeded.selector, proposalId));
        governance.execute(proposalId, address(mockTarget), data);
    }

    function test_RevertWhen_ExecuteAlreadyExecuted() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Vote, resolve, execute
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);
        governance.execute(proposalId, address(mockTarget), data);

        // Try to execute again
        vm.expectRevert(abi.encodeWithSelector(Errors.ProposalAlreadyExecuted.selector, proposalId));
        governance.execute(proposalId, address(mockTarget), data);
    }

    function test_RevertWhen_ExecuteHashMismatch() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Vote and resolve
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);

        // Try to execute with wrong data
        bytes memory wrongData = abi.encodeWithSignature("setValue(uint256)", 999);
        bytes32 wrongHash = _computeExecutionHash(address(mockTarget), wrongData);

        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionHashMismatch.selector, executionHash, wrongHash));
        governance.execute(proposalId, address(mockTarget), wrongData);
    }

    function test_RevertWhen_ExecutionFails() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes memory data = abi.encodeWithSignature("revertingFunction()");
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        // Vote and resolve
        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);

        // Execute should fail
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector, proposalId));
        governance.execute(proposalId, address(mockTarget), data);
    }

    // ========================================================================
    // DELEGATED VOTING TESTS
    // ========================================================================

    function test_DelegatedVoting() public {
        // Alice creates pool and delegates voting to Bob
        address pool = _createStakePool(alice, 100 ether);

        vm.prank(alice);
        IStakePool(pool).setVoter(bob);

        bytes32 executionHash = keccak256("test");

        // Bob creates proposal using alice's pool
        vm.prank(bob);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IGovernance.ProposalCreated(1, alice, pool, executionHash, "ipfs://test");
        governance.createProposal(pool, executionHash, "ipfs://test");
    }

    function test_EmitVoteCast() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IGovernance.VoteCast(proposalId, alice, pool, 100 ether, true);
        governance.vote(pool, proposalId, 100 ether, true);
    }

    function test_EmitProposalResolved() public {
        address pool = _createStakePool(alice, 100 ether);

        bytes32 executionHash = keccak256("test");

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

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
        bytes32 executionHash = _computeExecutionHash(address(mockTarget), data);

        vm.prank(alice);
        uint64 proposalId = governance.createProposal(pool, executionHash, "ipfs://test");

        vm.prank(alice);
        governance.vote(pool, proposalId, 100 ether, true);

        _advanceTime(VOTING_DURATION_MICROS + 1);
        governance.resolve(proposalId);

        vm.expectEmit(true, true, false, true);
        emit IGovernance.ProposalExecuted(proposalId, address(this), address(mockTarget), data);
        governance.execute(proposalId, address(mockTarget), data);
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

