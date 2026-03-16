// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { GammaHardforkBase } from "./GammaHardforkBase.t.sol";
import { Governance } from "../../src/governance/Governance.sol";
import { GovernanceConfig } from "../../src/runtime/GovernanceConfig.sol";
import { ValidatorConfig } from "../../src/runtime/ValidatorConfig.sol";
import { IStakePool } from "../../src/staking/IStakePool.sol";
import { SystemAddresses } from "../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../src/foundation/Errors.sol";

/// @title GovernanceUpgradeTest
/// @notice Tests for Governance and GovernanceConfig after Gamma hardfork.
///         Key concerns:
///         - renounceOwnership() → revert OperationNotSupported
///         - getRemainingVotingPower() uint128 overflow clamp
///         - GovernanceConfig minVotingThreshold > 0 validation
///         - GovernanceConfig requiredProposerStake > 0 validation
///         - ValidatorConfig MAX_UNBONDING_DELAY validation
///         - ValidatorManagement registerValidator with allowValidatorSetChange check
contract GovernanceUpgradeTest is GammaHardforkBase {
    address public pool1;

    function setUp() public override {
        super.setUp();

        // Deploy Governance at its system address
        // Governance has constructor(address initialOwner) — we'll use alice as owner
        vm.etch(SystemAddresses.GOVERNANCE, address(new Governance(alice)).code);

        // Need to set the owner storage since vm.etch only copies code, not storage
        // Ownable2Step stores owner at slot 0
        vm.store(SystemAddresses.GOVERNANCE, bytes32(uint256(0)), bytes32(uint256(uint160(alice))));

        // Create a pool for governance tests
        pool1 = _createRegisterAndJoin(alice, MIN_BOND * 10, "alice");
        _processEpoch();

        _applyGammaHardfork();
    }

    // ========================================================================
    // GOVERNANCE: renounceOwnership BLOCKED
    // ========================================================================

    /// @notice Test that renounceOwnership is blocked
    function test_governance_renounceOwnershipReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OperationNotSupported.selector);
        Governance(SystemAddresses.GOVERNANCE).renounceOwnership();
    }

    // ========================================================================
    // GOVERNANCE CONFIG: VALIDATIONS
    // ========================================================================

    /// @notice Test GovernanceConfig rejects minVotingThreshold = 0
    function test_governanceConfig_zeroMinVotingThreshold() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert();
        governanceConfig.setForNextEpoch(0, MIN_PROPOSAL_STAKE, 7 days * 1_000_000);
    }

    /// @notice Test GovernanceConfig rejects requiredProposerStake = 0
    function test_governanceConfig_zeroRequiredProposerStake() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert();
        governanceConfig.setForNextEpoch(50, 0, 7 days * 1_000_000);
    }

    // ========================================================================
    // VALIDATOR CONFIG: MAX_UNBONDING_DELAY
    // ========================================================================

    /// @notice Test ValidatorConfig rejects excessive unbonding delay
    function test_validatorConfig_excessiveUnbondingDelay() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert();
        validatorConfig.setForNextEpoch(
            MIN_BOND, MAX_BOND, type(uint64).max,
            true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
        );
    }

    // ========================================================================
    // VALIDATOR MANAGEMENT: REGISTER WITH allowValidatorSetChange
    // ========================================================================

    /// @notice Test registerValidator blocked when allowValidatorSetChange is false
    function test_validatorManagement_registerBlockedWhenDisabled() public {
        // Disable validator set changes via pending config
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorConfig.setForNextEpoch(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY,
            false, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
        );
        // Apply via reconfiguration
        vm.prank(SystemAddresses.RECONFIGURATION);
        validatorConfig.applyPendingConfig();

        // Try to register new validator
        address pool2 = _createStakePool(bob, MIN_BOND);
        bytes memory uniquePubkey = abi.encodePacked(pool2, bytes28(keccak256(abi.encodePacked(pool2))));

        vm.prank(bob);
        vm.expectRevert(Errors.ValidatorSetChangesDisabled.selector);
        validatorManager.registerValidator(
            pool2, "bob", uniquePubkey, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    /// @notice Test setFeeRecipient rejects zero address
    function test_validatorManagement_setFeeRecipientZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        validatorManager.setFeeRecipient(pool1, address(0));
    }
}
