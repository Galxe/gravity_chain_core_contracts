// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import "../../src/VulnerableLendingPool.sol";

contract UnitTestLendingPool is Test {
    VulnerableLendingPool pool;
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        pool = new VulnerableLendingPool();

        // Give Alice and Bob some initial funds
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // First add liquidity to the pool so borrowing is possible
        vm.startPrank(bob);
        pool.deposit(50000); // Bob deposits 50,000 tokens as liquidity
        vm.stopPrank();
    }

    function test_InterestCalculation_ExposesVulnerability() public {
        console2.log("=== VULNERABILITY 1: Interest Calculation Error Test ===");
        console2.log("Testing actual borrow scenario with time advancement");

        // Setup: Alice deposits collateral and borrows
        vm.startPrank(alice);
        pool.addCollateral(15000); // Add 15000 tokens as collateral
        pool.borrow(10000); // Borrow 10000 tokens
        vm.stopPrank();

        // Initial borrow amount should be 10000
        assertEq(pool.borrows(alice), 10000);
        console2.log("Initial borrow amount: 10000");

        // Get interest rate per second
        uint256 interestRatePerSecond = pool.interestRatePerSecond();
        console2.log("Interest rate per second:", interestRatePerSecond);

        // Fast forward 1 year (365 days)
        uint256 timeElapsed = 365 days;
        console2.log("Time advancing by:", timeElapsed / 1 days, "days");
        vm.warp(block.timestamp + timeElapsed);

        // Calculate what the correct interest should be
        uint256 correctInterest = (10000 * interestRatePerSecond * timeElapsed) / 1e18;
        uint256 correctBalance = 10000 + correctInterest;

        // Get current borrow balance from the contract
        uint256 borrowBalance = pool.getCurrentBorrowBalance(alice);
        uint256 actualInterest = borrowBalance - 10000;

        // VULNERABILITY: Interest calculation incorrectly divides by time instead of multiplying
        // With correct calculation (~3.15% annual rate), balance should be ~10315
        // With buggy calculation, interest will be much less (close to original amount)
        console2.log("=== Interest Calculation Comparison ===");
        console2.log("Expected correct formula: (borrowAmount * interestRatePerSecond * timeElapsed) / 1e18");
        console2.log("Buggy formula used: (borrowAmount * interestRatePerSecond) / (timeElapsed * 1e18)");
        console2.log("Expected correct balance after 1 year:", correctBalance);
        console2.log("Actual buggy balance after 1 year:", borrowBalance);
        console2.log("Expected interest accrual:", correctInterest);
        console2.log("Actual interest accrued:", actualInterest);
        console2.log("Interest difference:", correctInterest - actualInterest);
        console2.log("Interest loss percentage:", ((correctInterest - actualInterest) * 100) / correctInterest, "%");

        if (actualInterest < correctInterest / 100) {
            console2.log("!!! CRITICAL VULNERABILITY DETECTED: Interest accrual is less than 1% of expected !!!");
            console2.log("This effectively means borrowers pay almost no interest over time");
            console2.log("Protocol would lose over 99% of expected revenue");
        }

        // Assert that the bug exists - balance should be much lower than expected
        // This test passes BECAUSE the bug exists (showing the vulnerability)
        assertTrue(borrowBalance < 10100, "VULNERABILITY: Interest calculation is producing correct results");

        // Verify that we're getting the expected buggy behavior
        assertTrue(borrowBalance >= 10000 && borrowBalance < 10100, "Interest calculation is not behaving as expected");
    }

    function test_ManualInterestCalculation_ExposesVulnerability() public pure {
        console2.log("=== VULNERABILITY 1: Manual Interest Calculation Test ===");
        console2.log("Comparing correct vs buggy interest formulas directly");

        // Setup values
        uint256 borrowAmount = 10000;
        uint256 interestRatePerSecond = 100000000000; // From contract (0.0000001 per second)
        uint256 timeElapsed = 30 days;

        console2.log("Test parameters:");
        console2.log("  Borrow amount:", borrowAmount);
        console2.log("  Interest rate per second:", interestRatePerSecond);
        console2.log("  Time elapsed:", timeElapsed / 1 days, "days");

        // The correct calculation should be:
        // interest = (borrowAmount * interestRatePerSecond * timeElapsed) / 1e18
        uint256 correctInterest = (borrowAmount * interestRatePerSecond * timeElapsed) / 1e18;

        // But the vulnerable implementation does:
        // interest = (borrowAmount * interestRatePerSecond) / (timeElapsed * 1e18)
        uint256 buggyInterest = (borrowAmount * interestRatePerSecond) / (timeElapsed * 1e18);

        console2.log("=== Formula Comparison ===");
        console2.log("Correct formula: (borrowAmount * interestRatePerSecond * timeElapsed) / 1e18");
        console2.log("Buggy formula: (borrowAmount * interestRatePerSecond) / (timeElapsed * 1e18)");
        console2.log("Correct interest for 30 days:", correctInterest);
        console2.log("Buggy interest calculation:", buggyInterest);
        console2.log("Interest difference:", correctInterest - buggyInterest);

        uint256 lossPercentage = ((correctInterest - buggyInterest) * 100) / correctInterest;
        console2.log("Protocol revenue loss:", lossPercentage, "%");

        if (buggyInterest < correctInterest / 100) {
            console2.log("!!! CRITICAL VULNERABILITY DETECTED: Interest accrual is less than 1% of expected !!!");
            console2.log("This effectively means borrowers pay almost no interest");
        }

        // Check the same calculation for 1 year to show the long-term impact
        uint256 oneYear = 365 days;
        uint256 correctInterestOneYear = (borrowAmount * interestRatePerSecond * oneYear) / 1e18;
        uint256 buggyInterestOneYear = (borrowAmount * interestRatePerSecond) / (oneYear * 1e18);

        console2.log("=== Long-term Impact (1 year) ===");
        console2.log("Correct interest for 1 year:", correctInterestOneYear);
        console2.log("Buggy interest for 1 year:", buggyInterestOneYear);
        console2.log("Yearly interest loss:", correctInterestOneYear - buggyInterestOneYear);
        console2.log(
            "Yearly revenue loss percentage:",
            ((correctInterestOneYear - buggyInterestOneYear) * 100) / correctInterestOneYear,
            "%"
        );

        // This test passes BECAUSE the bug exists (showing the vulnerability)
        assertTrue(buggyInterest < correctInterest, "VULNERABILITY: Interest calculation matches correct formula");

        // Additional assertion to show the significance of the bug
        assertTrue(buggyInterest < (correctInterest / 100), "Bug doesn't have expected magnitude");
    }
}
