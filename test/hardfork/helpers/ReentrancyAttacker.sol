// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IStakePool } from "../../../src/staking/IStakePool.sol";

/// @title ReentrancyAttacker
/// @notice Test helper that attempts reentrancy on StakePool functions via receive() callback.
///         Used to verify that ReentrancyGuard (initialized in Gamma hardfork) blocks reentrant calls.
contract ReentrancyAttacker {
    enum AttackTarget {
        WITHDRAW_AVAILABLE,
        WITHDRAW_REWARDS,
        UNSTAKE_AND_WITHDRAW
    }

    address public pool;
    AttackTarget public target;
    bool public attackTriggered;
    bool public reentrancySucceeded;

    function setAttack(
        address _pool,
        AttackTarget _target
    ) external {
        pool = _pool;
        target = _target;
        attackTriggered = false;
        reentrancySucceeded = false;
    }

    receive() external payable {
        if (attackTriggered) return; // prevent infinite loop
        attackTriggered = true;

        // Attempt to re-enter the pool
        if (target == AttackTarget.WITHDRAW_AVAILABLE) {
            try IStakePool(pool).withdrawAvailable(address(this)) {
                reentrancySucceeded = true;
            } catch {
                // Expected: ReentrancyGuard blocks the call
            }
        } else if (target == AttackTarget.WITHDRAW_REWARDS) {
            try IStakePool(pool).withdrawRewards(address(this)) {
                reentrancySucceeded = true;
            } catch {
                // Expected: ReentrancyGuard blocks the call
            }
        } else if (target == AttackTarget.UNSTAKE_AND_WITHDRAW) {
            try IStakePool(pool).unstakeAndWithdraw(0, address(this)) {
                reentrancySucceeded = true;
            } catch {
                // Expected: ReentrancyGuard blocks the call
            }
        }
    }
}
