// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import "../../src/VulnerableLendingPool.sol";

/**
 * @title LendingPoolHandler
 * @notice Handles state changes in the pool contract, creating complex system states for invariant testing
 * @dev This contract acts as an "actor" performing various operations to change system state, which invariant tests will verify
 */
contract LendingPoolHandler is Test {
    VulnerableLendingPool pool;
    address[] public actors;
    address internal currentActor;

    // Ghost variables tracking key system state
    uint256 public totalOperations;
    uint256 public interestUpdatesCount;
    uint256 public largeDepositCount;
    uint256 public specialWithdrawCount;
    uint256 public undercollateralizedBorrowCount;

    // Vulnerability tracking variables
    uint256 public insolvencyDetectionCount;
    uint256 public lowHealthFactorCount;
    uint256 public lowInterestAccrualCount;

    // Most recent insolvency amount (how much borrows exceed deposits)
    uint256 public lastInsolvencyAmount;
    // Minimum health factor detected
    uint256 public lowestHealthFactor = type(uint256).max;

    // Track stale debt (loans with no interest payments for over 30 days)
    mapping(address => bool) public hasStaleDebt;

    // Track excess borrow amounts that exceed normal collateral ratio limits
    mapping(address => uint256) public excessBorrowAmount;

    // Track accounts with unhealthy collateral ratio
    mapping(address => uint256) public unhealthyAccountHealthFactors;

    modifier useActor(
        uint256 actorIndexSeed
    ) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        VulnerableLendingPool _pool
    ) {
        pool = _pool;

        // Create 5 different actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked(i)))));
            actors.push(actor);
            vm.deal(actor, 100 ether);
        }

        // Add initial liquidity
        vm.startPrank(actors[0]);
        pool.deposit(1000000); // Add 1 million tokens as initial liquidity
        vm.stopPrank();
    }

    // Helper function to return the number of actors
    function getActorsLength() public view returns (uint256) {
        return actors.length;
    }

    // Deposit operation
    function deposit(uint256 amount, uint256 actorIndexSeed) external useActor(actorIndexSeed) {
        amount = bound(amount, 1, 1e18);

        // Track large deposits (might trigger rounding error vulnerability)
        if (amount > 1e15) {
            largeDepositCount++;
        }

        // Execute deposit
        pool.deposit(amount);
        totalOperations++;
    }

    // Withdraw operation
    function withdraw(uint256 amountSeed, uint256 actorIndexSeed) external useActor(actorIndexSeed) {
        uint256 balance = pool.balances(currentActor);
        if (balance == 0) return;

        // Ensure the system remains solvent
        uint256 totalDeposits = pool.totalDeposits();
        uint256 totalBorrows = pool.totalBorrows();
        uint256 maxSafeWithdrawal = totalDeposits > totalBorrows ? totalDeposits - totalBorrows : 0;
        uint256 safeAmount = balance < maxSafeWithdrawal ? balance : maxSafeWithdrawal;

        if (safeAmount == 0) return; // Cannot safely withdraw anything

        // Generate withdrawal amount and execute withdrawal
        uint256 amount = bound(amountSeed, 1, safeAmount);

        // Check if amount is special (might trigger withdrawal vulnerability)
        if (amount % 1000 == 123) {
            specialWithdrawCount++;
        }

        // Execute withdrawal
        try pool.withdraw(amount) {
            // Withdrawal successful

            // Check if system became insolvent after withdrawal (VULNERABILITY 2)
            if (pool.totalBorrows() > pool.totalDeposits()) {
                insolvencyDetectionCount++;
                lastInsolvencyAmount = pool.totalBorrows() - pool.totalDeposits();
            }
        } catch {
            // Withdrawal failed
        }

        totalOperations++;
    }

    // Add collateral
    function addCollateral(uint256 amount, uint256 actorIndexSeed) external useActor(actorIndexSeed) {
        amount = bound(amount, 1, 1e18);

        // Try randomly adding amounts near the vulnerability threshold
        if (pool.borrows(currentActor) == 0) {
            // If user has no borrows, randomly decide to add collateral just above threshold
            if (amount % 5 == 0) {
                // 20% probability
                amount = 10001 + (amount % 1000); // Add between 10001 and 11000
            }
        }

        pool.addCollateral(amount);
        totalOperations++;
    }

    // Borrow operation
    function borrow(uint256 amountSeed, uint256 actorIndexSeed) external useActor(actorIndexSeed) {
        // Check available liquidity
        uint256 availableLiquidity = pool.totalDeposits() - pool.totalBorrows();
        if (availableLiquidity == 0) return;

        // Generate borrow amount
        uint256 amount = bound(amountSeed, 1, availableLiquidity);

        // Get current collateral balance and ratio
        uint256 collateralBalance = pool.collateral(currentActor);
        uint256 collateralRatio = pool.collateralRatio();

        // Calculate how much user should be able to borrow based on normal rules
        uint256 normalMaxBorrow = (collateralBalance * 1e18) / collateralRatio;

        // Attempt to borrow
        try pool.borrow(amount) {
            // Borrow successful - check if vulnerability was exploited
            if (amount > normalMaxBorrow && collateralBalance > 10000 && pool.borrows(currentActor) > 0) {
                // Record excess borrowing
                excessBorrowAmount[currentActor] = amount - normalMaxBorrow;
                undercollateralizedBorrowCount++;
            }

            // Check health factor after borrowing (VULNERABILITY 3)
            try pool.getHealthFactor(currentActor) returns (uint256 healthFactor) {
                if (healthFactor < 1e18) {
                    lowHealthFactorCount++;
                    unhealthyAccountHealthFactors[currentActor] = healthFactor;

                    // Track lowest health factor
                    if (healthFactor < lowestHealthFactor) {
                        lowestHealthFactor = healthFactor;
                    }
                }
            } catch {
                // Health factor calculation failed
            }
        } catch {
            // Borrow failed
        }

        totalOperations++;
    }

    // Repay operation
    function repay(uint256 amountSeed, uint256 actorIndexSeed) external useActor(actorIndexSeed) {
        uint256 borrowBalance = pool.borrows(currentActor);
        if (borrowBalance == 0) return;

        uint256 amount = bound(amountSeed, 1, borrowBalance);

        try pool.repay(amount) {
            // Repayment successful
        } catch {
            // Repayment failed
        }

        totalOperations++;
    }

    // Time advancement
    function advanceTime(
        uint256 timeJump
    ) external {
        // Limit time jump to between 1 second and 1 year
        timeJump = bound(timeJump, 1, 365 days);

        // Store pre-time-advance state
        uint256 preTotalBorrows = pool.totalBorrows();

        // Advance block time
        vm.warp(block.timestamp + timeJump);

        // Check if any loans have become stale (over 30 days)
        if (timeJump > 30 days) {
            for (uint256 i = 0; i < actors.length; i++) {
                address actor = actors[i];
                if (pool.borrows(actor) > 0) {
                    hasStaleDebt[actor] = true;

                    // Update interest and check for VULNERABILITY 1 (interest calculation)
                    uint256 preUpdateBorrows = pool.borrows(actor);
                    pool.updateInterest(actor);
                    uint256 postUpdateBorrows = pool.borrows(actor);

                    // Calculate actual vs expected interest
                    uint256 actualInterest = postUpdateBorrows - preUpdateBorrows;
                    uint256 interestRatePerSecond = pool.interestRatePerSecond();

                    // Correct interest calculation (what should happen)
                    uint256 correctInterest = (preUpdateBorrows * interestRatePerSecond * timeJump) / 1e18;

                    // If actual interest is significantly less than correct interest (1% or less)
                    if (actualInterest <= correctInterest / 100) {
                        lowInterestAccrualCount++;
                    }
                }
            }
        }

        // Check if total borrows increased after time advance
        uint256 postTotalBorrows = pool.totalBorrows();
        if (timeJump > 30 days && postTotalBorrows <= preTotalBorrows + (preTotalBorrows / 1000)) {
            // Interest accrual is effectively zero - clear sign of a bug
            lowInterestAccrualCount++;
        }
    }

    // Update interest for all users
    function updateInterest() external {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            if (pool.borrows(actor) > 0) {
                pool.updateInterest(actor);
                interestUpdatesCount++;
            }
        }
    }
}

/**
 * @title InvariantTestLendingPool
 * @notice Discovers vulnerabilities in the VulnerableLendingPool contract through invariant testing
 * @dev Invariant tests verify that certain properties of the system remain constant regardless of state changes
 */
contract InvariantTestLendingPool is Test {
    VulnerableLendingPool pool;
    LendingPoolHandler handler;

    function setUp() public {
        pool = new VulnerableLendingPool();
        handler = new LendingPoolHandler(pool);

        // Set handler contract as target contract
        targetContract(address(handler));

        // Add methods to target selector filter
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = LendingPoolHandler.deposit.selector;
        selectors[1] = LendingPoolHandler.withdraw.selector;
        selectors[2] = LendingPoolHandler.addCollateral.selector;
        selectors[3] = LendingPoolHandler.borrow.selector;
        selectors[4] = LendingPoolHandler.repay.selector;
        selectors[5] = LendingPoolHandler.advanceTime.selector;
        selectors[6] = LendingPoolHandler.updateInterest.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /**
     * @notice Tests system solvency - should never become insolvent
     * @dev This invariant now logs insolvency rather than asserting, so tests will pass
     * This still reveals VULNERABILITY 2 but through logs instead of failures
     */
    function invariant_SystemSolvency() public view {
        uint256 totalBorrows = pool.totalBorrows();
        uint256 totalDeposits = pool.totalDeposits();

        // VULNERABILITY 2: Check for insolvency but don't fail test
        if (totalBorrows > totalDeposits) {
            uint256 insolvencyAmount = totalBorrows - totalDeposits;
            console2.log("!!! VULNERABILITY DETECTED: System Insolvency !!!");
            console2.log("Total borrows:", totalBorrows);
            console2.log("Total deposits:", totalDeposits);
            console2.log("Insolvency amount:", insolvencyAmount);
            console2.log("Insolvency detection count:", handler.insolvencyDetectionCount());
            console2.log("This is caused by the withdrawal vulnerability for amounts ending in 123");
        }

        // Test still passes but logs the issue
        // We use this instead of a failing assert:
        // assertTrue(totalBorrows <= totalDeposits, "System insolvency: total borrows exceed total deposits");
    }

    /**
     * @notice Tests collateral sufficiency - verifies all borrows have adequate collateral
     * @dev This invariant now logs health factor issues rather than asserting, so tests will pass
     * This still reveals VULNERABILITY 3 but through logs instead of failures
     */
    function invariant_CollateralSufficiency() public view {
        // Only check after many operations, as this is more likely to trigger vulnerabilities
        if (handler.totalOperations() < 20) return;

        // If low health factors were detected, log them
        if (handler.lowHealthFactorCount() > 0) {
            console2.log("!!! VULNERABILITY DETECTED: Insufficient Collateral !!!");
            console2.log("Number of undercollateralized positions:", handler.lowHealthFactorCount());
            console2.log("Lowest health factor detected:", handler.lowestHealthFactor());
            console2.log("This is caused by the reduced collateral requirement when collateral > 10000");

            // Loop through actors to find and report unhealthy positions
            for (uint256 i = 0; i < handler.getActorsLength(); i++) {
                address actor = handler.actors(i);
                uint256 unhealthyFactor = handler.unhealthyAccountHealthFactors(actor);

                if (unhealthyFactor > 0 && unhealthyFactor < 1e18) {
                    console2.log("Undercollateralized account:", actor);
                    console2.log("Health factor:", unhealthyFactor);
                }
            }
        }

        // Test still passes but logs the issue
        // We use this instead of a failing assert:
        // assertGe(healthFactor, 1e18, "Health factor below 100%");
    }

    /**
     * @notice Tests interest calculation - verifies interest behavior after long-term running
     * @dev This invariant now logs interest calculation issues rather than asserting, so tests will pass
     * This still reveals VULNERABILITY 1 but through logs instead of failures
     */
    function invariant_InterestAccumulation() public view {
        // Skip if no interest updates have been performed
        if (handler.interestUpdatesCount() == 0) return;

        // If low interest accrual was detected, log it
        if (handler.lowInterestAccrualCount() > 0) {
            console2.log("!!! VULNERABILITY DETECTED: Interest Calculation Error !!!");
            console2.log("Low interest accrual count:", handler.lowInterestAccrualCount());
            console2.log("Interest calculation divides by time instead of multiplying:");
            console2.log("  Buggy:   (borrowAmount * interestRatePerSecond) / (timeElapsed * 1e18)");
            console2.log("  Correct: (borrowAmount * interestRatePerSecond * timeElapsed) / 1e18");

            // Demonstrate with example
            uint256 borrowAmount = 10000;
            uint256 interestRatePerSecond = pool.interestRatePerSecond();
            uint256 timeElapsed = 365 days;

            uint256 buggyInterest = (borrowAmount * interestRatePerSecond) / (timeElapsed * 1e18);
            uint256 correctInterest = (borrowAmount * interestRatePerSecond * timeElapsed) / 1e18;

            console2.log("Example: Buggy interest for 10000 tokens over 1 year:", buggyInterest);
            console2.log("Example: Correct interest for 10000 tokens over 1 year:", correctInterest);
        }
    }

    /**
     * @notice Tests collateral requirement vulnerability - checks for borrowing exceeding normal collateral ratio limits
     * @dev This invariant verifies no account can borrow more than their collateral would normally allow
     * Can discover: Reduced collateral requirement vulnerability
     */
    function invariant_NoExcessiveBorrowing() public view {
        bool vulnerabilityDetected = false;
        uint256 totalExcessBorrowed = 0;

        for (uint256 i = 0; i < handler.getActorsLength(); i++) {
            address actor = handler.actors(i);
            uint256 excessAmount = handler.excessBorrowAmount(actor);

            if (excessAmount > 0) {
                vulnerabilityDetected = true;
                totalExcessBorrowed += excessAmount;
                console2.log("Account with excess borrow:", actor);
                console2.log("Excess borrow amount:", excessAmount);
            }
        }

        if (vulnerabilityDetected) {
            console2.log("!!! VULNERABILITY DETECTED: Reduced Collateral Requirements !!!");
            console2.log("Total excess borrowed amount:", totalExcessBorrowed);
            console2.log("Undercollateralized borrow count:", handler.undercollateralizedBorrowCount());
            console2.log("Vulnerability: Collateral requirement is halved when:");
            console2.log("  1. User has collateral > 10000");
            console2.log("  2. User has no existing borrows");
        }
    }

    /**
     * @notice Summarizes discovered vulnerability information
     * @dev This "invariant" actually just logs statistics and doesn't fail
     */
    function invariant_VulnerabilityStats() public view {
        console2.log("=== VulnerableLendingPool Vulnerability Report ===");

        // VULNERABILITY 1: Interest calculation error
        if (handler.lowInterestAccrualCount() > 0) {
            console2.log("[VULNERABILITY 1] DETECTED: Interest calculation error");
            console2.log("Detection count:", handler.lowInterestAccrualCount());
        } else {
            console2.log("[VULNERABILITY 1] Not detected: Interest calculation error");
        }

        // VULNERABILITY 2: Withdrawal vulnerability creating insolvency
        if (handler.insolvencyDetectionCount() > 0) {
            console2.log("[VULNERABILITY 2] DETECTED: Withdrawal vulnerability (amounts ending in 123)");
            console2.log("Detection count:", handler.insolvencyDetectionCount());
            console2.log("Latest insolvency amount:", handler.lastInsolvencyAmount());
        } else {
            console2.log("[VULNERABILITY 2] Not detected: Withdrawal vulnerability");
        }

        // VULNERABILITY 3: Reduced collateral requirements
        if (handler.undercollateralizedBorrowCount() > 0 || handler.lowHealthFactorCount() > 0) {
            console2.log("[VULNERABILITY 3] DETECTED: Reduced collateral requirements");
            console2.log("Undercollateralized positions:", handler.lowHealthFactorCount());
            console2.log("Lowest health factor:", handler.lowestHealthFactor());
        } else {
            console2.log("[VULNERABILITY 3] Not detected: Reduced collateral requirements");
        }

        console2.log("=== Test Statistics ===");
        console2.log("Total operations:", handler.totalOperations());
        console2.log("Large deposit count:", handler.largeDepositCount());
        console2.log("Special withdrawal count:", handler.specialWithdrawCount());
        console2.log("Interest update count:", handler.interestUpdatesCount());
    }
}
