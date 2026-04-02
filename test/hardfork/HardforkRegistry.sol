// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";

/// @title HardforkRegistry
/// @notice Declarative definitions for system contract hardfork upgrades.
///         Each hardfork is a list of ContractUpgrade entries (which system contracts to replace)
///         and PostAction entries (storage patches to apply after bytecode replacement).
///
///         Usage: Add a new function for each hardfork (e.g., `delta()`) returning its definition.
///         The HardforkTestBase reads these definitions to apply upgrades generically.
library HardforkRegistry {
    /// @notice A system contract whose bytecode should be replaced during hardfork
    struct ContractUpgrade {
        address addr; // e.g., SystemAddresses.STAKE_CONFIG
        string name; // e.g., "StakingConfig" — used for fixture file lookup & deploy
    }

    /// @notice A storage write to apply after bytecode replacement (e.g., init ReentrancyGuard)
    struct PostAction {
        address target; // contract address (or address(0) for dynamic targets like pools)
        bytes32 slot; // storage slot to write
        bytes32 value; // value to write
        bool isDynamic; // if true, apply to all StakePool instances instead of `target`
    }

    /// @notice Complete hardfork definition
    struct HardforkDef {
        string name; // "gamma", "delta", ...
        string fromTag; // git tag for the "from" version fixtures
        ContractUpgrade[] upgrades; // contracts to replace
        PostAction[] postActions; // storage patches after replacement
    }

    // ========================================================================
    // GAMMA HARDFORK DEFINITION
    // ========================================================================

    /// @notice ReentrancyGuard ERC-7201 namespaced storage slot
    bytes32 constant REENTRANCY_GUARD_SLOT =
        bytes32(0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00);

    /// @notice Build the Gamma hardfork definition
    function gamma() internal pure returns (HardforkDef memory def) {
        def.name = "gamma";
        def.fromTag = "gravity-testnet-v1.0.0";

        // --- System contract upgrades ---
        def.upgrades = new ContractUpgrade[](10);
        def.upgrades[0] = ContractUpgrade(SystemAddresses.STAKE_CONFIG, "StakingConfig");
        def.upgrades[1] = ContractUpgrade(SystemAddresses.VALIDATOR_CONFIG, "ValidatorConfig");
        def.upgrades[2] = ContractUpgrade(SystemAddresses.VALIDATOR_MANAGER, "ValidatorManagement");
        def.upgrades[3] = ContractUpgrade(SystemAddresses.RECONFIGURATION, "Reconfiguration");
        def.upgrades[4] = ContractUpgrade(SystemAddresses.NATIVE_ORACLE, "NativeOracle");
        def.upgrades[5] = ContractUpgrade(SystemAddresses.STAKING, "Staking");
        def.upgrades[6] = ContractUpgrade(SystemAddresses.BLOCK, "Blocker");
        def.upgrades[7] = ContractUpgrade(SystemAddresses.PERFORMANCE_TRACKER, "ValidatorPerformanceTracker");
        def.upgrades[8] = ContractUpgrade(SystemAddresses.GOVERNANCE_CONFIG, "GovernanceConfig");
        def.upgrades[9] = ContractUpgrade(SystemAddresses.GOVERNANCE, "Governance");

        // --- Post-actions: initialize ReentrancyGuard in every StakePool ---
        def.postActions = new PostAction[](1);
        def.postActions[0] = PostAction({
            target: address(0),
            slot: REENTRANCY_GUARD_SLOT,
            value: bytes32(uint256(1)), // NOT_ENTERED
            isDynamic: true // apply to all StakePool instances
        });
    }

    // ========================================================================
    // DELTA HARDFORK DEFINITION
    // ========================================================================

    /// @notice Build the Delta hardfork definition
    /// @dev Delta upgrades from gravity-testnet-v1.2.0 to main (PR #49, #55, #58):
    ///      - StakingConfig: minimumProposalStake deprecated (kept as storage gap, no layout shift)
    ///      - ValidatorManagement: consensus key rotation, try/catch renewPoolLockup,
    ///        whale VP fix, eviction fairness fix
    ///      - Governance: MAX_PROPOSAL_TARGETS limit, ProposalNotResolved check
    ///      - NativeOracle: callback invocation refactored, CallbackSkipped event
    function delta() internal pure returns (HardforkDef memory def) {
        def.name = "delta";
        def.fromTag = "gravity-testnet-v1.2.0";

        // --- System contract upgrades ---
        def.upgrades = new ContractUpgrade[](4);
        def.upgrades[0] = ContractUpgrade(SystemAddresses.STAKE_CONFIG, "StakingConfig");
        def.upgrades[1] = ContractUpgrade(SystemAddresses.VALIDATOR_MANAGER, "ValidatorManagement");
        def.upgrades[2] = ContractUpgrade(SystemAddresses.GOVERNANCE, "Governance");
        def.upgrades[3] = ContractUpgrade(SystemAddresses.NATIVE_ORACLE, "NativeOracle");

        // No PostActions needed — StakingConfig uses storage gap pattern to preserve v1.2.0 layout
    }
}
