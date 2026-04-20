// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title MockStaking
/// @notice Minimal mock of the IStaking interface for the system contracts that
///         ValidatorManagement actually touches during reconfiguration:
///         - getPoolVotingPower(pool, atTime) → uint256 (used by _getValidatorVotingPower)
///         - renewPoolLockup(pool) → ()      (used by _renewActiveValidatorLockups, in try/catch)
///         - isPool(pool) → bool             (only used in registerValidator path; not exercised here)
///
/// @dev We don't deploy real Staking + StakePools because building 4 valid pools with proper
///      lockups would dwarf the actual exploit surface we want to demonstrate. The eviction
///      path only reads voting power for liveness/threshold checks; a constant per-pool power
///      that exceeds minimumBond is sufficient to keep validators "ACTIVE" through Phase 1
///      (underbond eviction) so that Phase 2 (perf eviction with zero data) is what actually
///      kicks every validator out.
contract MockStaking {
    /// @notice Voting power served for every pool (set high enough to clear minimumBond)
    uint256 public defaultVotingPower;

    /// @notice Configurable per-pool override
    mapping(address => uint256) public votingPowerOverride;
    mapping(address => bool) public hasOverride;

    constructor(uint256 _defaultVotingPower) {
        defaultVotingPower = _defaultVotingPower;
    }

    function setVotingPower(address pool, uint256 power) external {
        votingPowerOverride[pool] = power;
        hasOverride[pool] = true;
    }

    function getPoolVotingPower(address pool, uint64 /*atTime*/ ) external view returns (uint256) {
        if (hasOverride[pool]) return votingPowerOverride[pool];
        return defaultVotingPower;
    }

    function getPoolVotingPowerNow(address pool) external view returns (uint256) {
        if (hasOverride[pool]) return votingPowerOverride[pool];
        return defaultVotingPower;
    }

    /// @notice ValidatorManagement._renewActiveValidatorLockups wraps this in try/catch,
    ///         so it's safe to leave as a no-op.
    function renewPoolLockup(address /*pool*/ ) external pure {
    // intentionally empty
    }

    function isPool(address /*pool*/ ) external pure returns (bool) {
        return true;
    }

    function getPoolOperator(address pool) external pure returns (address) {
        return pool;
    }

    function getPoolOwner(address pool) external pure returns (address) {
        return pool;
    }
}
