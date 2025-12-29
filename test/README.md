# Testing Strategy & Vulnerability Analysis

This directory contains comprehensive tests for the educational `VulnerableLendingPool.sol` contract. The contract is intentionally designed with vulnerabilities to demonstrate different testing methodologies and their effectiveness in discovering various types of bugs.

## Overview of Vulnerabilities

The `VulnerableLendingPool` contract contains **3 intentional vulnerabilities** that showcase how different testing approaches can uncover different classes of bugs:

### 🐛 Vulnerability 1: Interest Calculation Logic Error (Unit Test)
**Location**: `updateInterest()` function  
**Issue**: Interest calculation divides by time instead of multiplying by time

```solidity
// BUGGY CODE:
uint256 interest = (borrows[user] * interestRatePerSecond) / (timeElapsed * 1e18);
// SHOULD BE:
uint256 interest = (borrows[user] * interestRatePerSecond * timeElapsed) / 1e18;
```

**Impact**: Users pay significantly less interest than intended, causing protocol revenue loss.

### 🐛 Vulnerability 2: Rounding Errors (Fuzz Test)
**Location**: `deposit()` and `withdraw()` functions  
**Issue**: Specific input values cause rounding errors

```solidity
// In deposit(): amounts > 1e30 lose 1 token
if (amount > 1e30) {
    amount = amount - 1;
}

// In withdraw(): amounts ending with "123" cost an extra token
if (amount % 1000 == 123) {
    amount += 1;
}
```

**Impact**: Users can lose tokens during edge-case transactions.

### 🐛 Vulnerability 3: Collateral Bypass (Invariant Test)
**Location**: `borrow()` function  
**Issue**: Users with high collateral and zero previous borrows get 50% collateral discount

```solidity
// DANGEROUS CONDITION:
if (collateral[msg.sender] > 10000 && borrows[msg.sender] == 0) {
    requiredCollateral = requiredCollateral / 2;  // 50% discount!
}
```

**Impact**: Protocol can become insolvent as users borrow more than their collateral value.

---

## Testing Methodologies

### 📝 Unit Testing (`test/unit/`)

**Purpose**: Test individual functions with known inputs to verify expected behavior.

**How it discovers Vulnerability 1**:
```solidity
function test_InterestCalculation_IsIncorrect() public {
    // 1. Set up: User borrows 1000 tokens
    // 2. Fast forward time by 1 year 
    // 3. Calculate expected interest (should be ~3.15% = 31.5 tokens)
    // 4. Compare with actual interest (will be much less due to division bug)
    // 5. Assert that the interest is incorrectly calculated
}
```

**Unit tests excel at**:
- ✅ Testing specific function logic
- ✅ Verifying mathematical calculations
- ✅ Checking error conditions and reverts
- ✅ Testing expected vs actual outputs

**Unit tests struggle with**:
- ❌ Edge cases with unusual inputs
- ❌ Complex interactions between functions
- ❌ System-wide property violations

### 🎲 Fuzz Testing (`test/fuzz/`)

**Purpose**: Test functions with random inputs to discover edge cases and unexpected behaviors.

**How it discovers Vulnerability 2**:
```solidity
function testFuzz_Deposit_RoundingError(uint256 amount) public {
    vm.assume(amount > 0 && amount < type(uint256).max);
    
    // Fuzz testing will eventually generate amount > 1e30
    // and discover the -1 rounding error
    uint256 balanceBefore = pool.balances(user);
    pool.deposit(amount);
    uint256 balanceAfter = pool.balances(user);
    
    // This assertion will fail when amount > 1e30
    assertEq(balanceAfter - balanceBefore, amount);
}
```

**Fuzz tests excel at**:
- ✅ Finding edge cases with extreme values
- ✅ Discovering input-dependent bugs
- ✅ Testing boundary conditions
- ✅ Uncovering unexpected behaviors

**Fuzz tests struggle with**:
- ❌ Complex multi-step attack scenarios
- ❌ State-dependent vulnerabilities
- ❌ Bugs requiring specific sequences of actions

### ⚖️ Invariant Testing (`test/invariant/`)

**Purpose**: Test system-wide properties that should always hold true, regardless of the sequence of actions performed.

**How it discovers Vulnerability 3**:
```solidity
// Define the core invariant of a lending protocol
function invariant_ProtocolMustRemainSolvent() public {
    uint256 totalCollateralValue = getTotalCollateralValue();
    uint256 totalBorrowValue = pool.totalBorrows();
    
    // This invariant will be violated when users exploit the collateral bypass
    // Protocol becomes insolvent: totalBorrowValue > totalCollateralValue
    assertGe(totalCollateralValue, totalBorrowValue, "Protocol is insolvent!");
}

function invariant_UsersMustBeOvercollateralized() public {
    // Check that all users maintain proper collateralization
    // This will fail when the 50% discount allows undercollateralized borrows
}
```

**Invariant tests excel at**:
- ✅ Testing system-wide properties
- ✅ Discovering state corruption bugs
- ✅ Finding vulnerabilities requiring multiple steps
- ✅ Ensuring protocol economic security

**Invariant tests struggle with**:
- ❌ Simple logic errors in individual functions
- ❌ Bugs that don't violate overall system properties
- ❌ Performance-related issues

---

## Running the Tests

### Run All Tests
```bash
forge test
```

### Run Specific Test Types
```bash
# Unit tests only
forge test --match-path "test/unit/*"

# Fuzz tests only  
forge test --match-path "test/fuzz/*"

# Invariant tests only
forge test --match-path "test/invariant/*"
```

### Run with Detailed Output
```bash
forge test -vvvv  # Very verbose output
forge test --gas-report  # Include gas usage
```

### Run Specific Vulnerability Tests
```bash
# Test interest calculation bug
forge test --match-test "test.*Interest.*"

# Test rounding errors
forge test --match-test "testFuzz.*Rounding.*"

# Test collateral bypass
forge test --match-test "invariant.*Collateral.*"
```