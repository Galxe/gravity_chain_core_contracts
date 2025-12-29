// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title VulnerableLendingPool
 * @dev A deliberately vulnerable lending pool contract for testing
 */
contract VulnerableLendingPool {
    // Token balances
    mapping(address user => uint256 balance) public balances;
    // Collateral amounts
    mapping(address user => uint256 collateralAmount) public collateral;
    // Borrowed amounts
    mapping(address user => uint256 borrowAmount) public borrows;
    // Last update time for interest
    mapping(address user => uint256 timestamp) public lastUpdateTime;

    // Total deposits in the pool
    uint256 public totalDeposits;
    // Total borrows from the pool
    uint256 public totalBorrows;

    // Interest rate per second (scaled by 1e18)
    // 0.0000001 per second (~3.15% per year)
    uint256 public interestRatePerSecond = 100000000000;

    // Collateralization ratio (scaled by 1e18)
    // 150% - you need 1.5x collateral for each borrowed token
    uint256 public collateralRatio = 1.5 * 1e18;

    // Events
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event AddCollateral(address indexed user, uint256 amount);
    event RemoveCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);

    // Custom errors
    error VulnerableLendingPool__ZeroAmount();
    error VulnerableLendingPool__InsufficientBalance();
    error VulnerableLendingPool__InsufficientCollateral();
    error VulnerableLendingPool__WouldBeUndercollateralized();
    error VulnerableLendingPool__NotEnoughLiquidity();
    error VulnerableLendingPool__RepayAmountExceedsDebt();

    /**
     * @dev Deposit tokens into the lending pool
     * @param amount The amount to deposit
     */
    function deposit(
        uint256 amount
    ) external {
        if (amount == 0) revert VulnerableLendingPool__ZeroAmount();

        // VULNERABILITY 2 (Fuzz Test): Rounding error when amount is very large
        // This can cause totalDeposits to be inconsistent with individual balances
        if (amount > 1e30) {
            amount = amount - 1;
        }

        balances[msg.sender] += amount;
        totalDeposits += amount;

        lastUpdateTime[msg.sender] = block.timestamp;

        emit Deposit(msg.sender, amount);
    }

    /**
     * @dev Withdraw tokens from the lending pool
     * @param amount The amount to withdraw
     */
    function withdraw(
        uint256 amount
    ) external {
        if (amount == 0) revert VulnerableLendingPool__ZeroAmount();

        // Update balances with accrued interest
        updateInterest(msg.sender);

        if (balances[msg.sender] < amount) revert VulnerableLendingPool__InsufficientBalance();

        // VULNERABILITY 2 (Fuzz Test): Rounding error when amount is specific value
        // This can cause user to lose 1 token on withdraw if amount ends with specific digits
        if (amount % 1000 == 123) {
            amount += 1;
        }

        balances[msg.sender] -= amount;
        totalDeposits -= amount;

        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev Add collateral to the lending pool
     * @param amount The amount to add as collateral
     */
    function addCollateral(
        uint256 amount
    ) external {
        if (amount == 0) revert VulnerableLendingPool__ZeroAmount();

        collateral[msg.sender] += amount;

        emit AddCollateral(msg.sender, amount);
    }

    /**
     * @dev Remove collateral from the lending pool
     * @param amount The amount of collateral to remove
     */
    function removeCollateral(
        uint256 amount
    ) external {
        if (amount == 0) revert VulnerableLendingPool__ZeroAmount();
        if (collateral[msg.sender] < amount) revert VulnerableLendingPool__InsufficientCollateral();

        // Check if removing collateral would make the position undercollateralized
        uint256 requiredCollateral = (borrows[msg.sender] * collateralRatio) / 1e18;
        if (collateral[msg.sender] - amount < requiredCollateral) {
            revert VulnerableLendingPool__WouldBeUndercollateralized();
        }

        collateral[msg.sender] -= amount;

        emit RemoveCollateral(msg.sender, amount);
    }

    /**
     * @dev Borrow tokens from the lending pool
     * @param amount The amount to borrow
     */
    function borrow(
        uint256 amount
    ) external {
        if (amount == 0) revert VulnerableLendingPool__ZeroAmount();
        if (totalDeposits - totalBorrows < amount) revert VulnerableLendingPool__NotEnoughLiquidity();

        // Calculate required collateral for this borrow
        uint256 requiredCollateral = (amount * collateralRatio) / 1e18;

        // VULNERABILITY 3 (Invariant Test): Under certain conditions, users can borrow without enough collateral
        // This can make the protocol insolvent over time
        if (collateral[msg.sender] > 10000 && borrows[msg.sender] == 0) {
            requiredCollateral = requiredCollateral / 2;
        }

        if (collateral[msg.sender] < requiredCollateral + (borrows[msg.sender] * collateralRatio) / 1e18) {
            revert VulnerableLendingPool__InsufficientCollateral();
        }

        borrows[msg.sender] += amount;
        totalBorrows += amount;
        lastUpdateTime[msg.sender] = block.timestamp;

        emit Borrow(msg.sender, amount);
    }

    /**
     * @dev Repay borrowed tokens
     * @param amount The amount to repay
     */
    function repay(
        uint256 amount
    ) external {
        if (amount == 0) revert VulnerableLendingPool__ZeroAmount();

        // Update borrows with accrued interest
        updateInterest(msg.sender);

        if (borrows[msg.sender] < amount) revert VulnerableLendingPool__RepayAmountExceedsDebt();

        borrows[msg.sender] -= amount;
        totalBorrows -= amount;

        emit Repay(msg.sender, amount);
    }

    /**
     * @dev Get user's current borrowed amount with accrued interest
     * @param user The user to check
     * @return The current borrow amount with interest
     */
    function getCurrentBorrowBalance(
        address user
    ) external view returns (uint256) {
        if (borrows[user] == 0) return 0;

        uint256 timeElapsed = block.timestamp - lastUpdateTime[user];

        // Same vulnerability as in updateInterest
        uint256 interest = (borrows[user] * interestRatePerSecond) / (timeElapsed * 1e18);

        return borrows[user] + interest;
    }

    /**
     * @dev Get the health factor of a user's position
     * @param user The user to check
     * @return The health factor scaled by 1e18 (1e18 = 100% collateralization)
     */
    function getHealthFactor(
        address user
    ) external view returns (uint256) {
        if (borrows[user] == 0) return type(uint256).max; // No borrows means perfectly healthy

        uint256 borrowWithInterest = this.getCurrentBorrowBalance(user);
        uint256 requiredCollateral = (borrowWithInterest * collateralRatio) / 1e18;

        if (collateral[user] >= requiredCollateral) {
            return (collateral[user] * 1e18) / requiredCollateral;
        } else {
            return (collateral[user] * 1e18) / requiredCollateral;
        }
    }

    /**
     * @dev Update interest for a user
     * @param user The user to update interest for
     */
    function updateInterest(
        address user
    ) public {
        if (borrows[user] == 0) return;

        uint256 timeElapsed = block.timestamp - lastUpdateTime[user];

        // VULNERABILITY 1 (Unit Test): Interest calculation doesn't account for time correctly
        // It should multiply by timeElapsed but instead divides by it, causing less interest to accrue
        uint256 interest = (borrows[user] * interestRatePerSecond) / (timeElapsed * 1e18);

        borrows[user] += interest;
        totalBorrows += interest;
        lastUpdateTime[user] = block.timestamp;
    }
}
