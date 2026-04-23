// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ValidatorManagement } from "../../../src/staking/ValidatorManagement.sol";
import { IValidatorManagement, GenesisValidator } from "../../../src/staking/IValidatorManagement.sol";
import { Staking } from "../../../src/staking/Staking.sol";
import { StakingConfig } from "../../../src/runtime/StakingConfig.sol";
import { ValidatorConfig } from "../../../src/runtime/ValidatorConfig.sol";
import { Timestamp } from "../../../src/runtime/Timestamp.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";
import { MockBlsPopVerify } from "../../utils/MockBlsPopVerify.sol";

contract MockReconfigurationForWhitelist {
    bool private _transitionInProgress;
    uint64 public currentEpoch;

    function isTransitionInProgress() external view returns (bool) {
        return _transitionInProgress;
    }

    function setTransitionInProgress(
        bool inProgress
    ) external {
        _transitionInProgress = inProgress;
    }

    function incrementEpoch() external {
        currentEpoch++;
    }
}

/// @title ValidatorWhitelistTest
/// @notice Focused coverage for the permissioned-launch whitelist inside
///         ValidatorManagement: register/join gating, governance-only setters,
///         permissionless flip, genesis auto-populate.
contract ValidatorWhitelistTest is Test {
    ValidatorManagement public validatorManager;
    Staking public staking;
    StakingConfig public stakingConfig;
    ValidatorConfig public validatorConfig;
    Timestamp public timestamp;
    MockReconfigurationForWhitelist public mockReconfiguration;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant MIN_STAKE = 1 ether;
    uint256 constant MIN_BOND = 10 ether;
    uint256 constant MAX_BOND = 1000 ether;
    uint64 constant LOCKUP_DURATION = 14 days * 1_000_000;
    uint64 constant UNBONDING_DELAY = 7 days * 1_000_000;
    uint64 constant INITIAL_TIMESTAMP = 1_000_000_000_000_000;
    uint64 constant VOTING_POWER_INCREASE_LIMIT = 20;
    uint256 constant MAX_VALIDATOR_SET_SIZE = 100;

    bytes constant CONSENSUS_POP = hex"abcdef1234567890";
    bytes constant NETWORK_ADDRESSES = hex"0102030405060708";
    bytes constant FULLNODE_ADDRESSES = hex"0807060504030201";

    function setUp() public {
        vm.etch(SystemAddresses.STAKE_CONFIG, address(new StakingConfig()).code);
        stakingConfig = StakingConfig(SystemAddresses.STAKE_CONFIG);

        vm.etch(SystemAddresses.VALIDATOR_CONFIG, address(new ValidatorConfig()).code);
        validatorConfig = ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.STAKING, address(new Staking()).code);
        staking = Staking(SystemAddresses.STAKING);

        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new ValidatorManagement()).code);
        validatorManager = ValidatorManagement(SystemAddresses.VALIDATOR_MANAGER);

        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfigurationForWhitelist()).code);
        mockReconfiguration = MockReconfigurationForWhitelist(SystemAddresses.RECONFIGURATION);

        vm.etch(SystemAddresses.BLS_POP_VERIFY_PRECOMPILE, address(new MockBlsPopVerify()).code);

        vm.prank(SystemAddresses.GENESIS);
        stakingConfig.initialize(MIN_STAKE, LOCKUP_DURATION, UNBONDING_DELAY);

        vm.prank(SystemAddresses.GENESIS);
        validatorConfig.initialize(
            MIN_BOND, MAX_BOND, UNBONDING_DELAY, true, VOTING_POWER_INCREASE_LIMIT, MAX_VALIDATOR_SET_SIZE, false, 0
        );

        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(alice, INITIAL_TIMESTAMP);

        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(carol, 10000 ether);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _createStakePool(
        address owner,
        uint256 stakeAmount
    ) internal returns (address pool) {
        uint64 lockedUntil = timestamp.nowMicroseconds() + LOCKUP_DURATION;
        vm.prank(owner);
        pool = staking.createPool{ value: stakeAmount }(owner, owner, owner, owner, lockedUntil);
    }

    function _uniquePubkey(
        address pool
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(pool, bytes28(keccak256(abi.encodePacked(pool))));
    }

    function _register(
        address owner,
        address pool,
        string memory moniker
    ) internal {
        bytes memory pk = _uniquePubkey(pool);
        // Audit #580: commit-reveal precondition.
        bytes32 commitment = keccak256(abi.encode(pk, pool, block.chainid));
        vm.prank(owner);
        validatorManager.commitConsensusPubkey(commitment);
        vm.roll(block.number + 1);

        vm.prank(owner);
        validatorManager.registerValidator(pool, moniker, pk, CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES);
    }

    function _allow(
        address pool
    ) internal {
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(pool, true);
    }

    // ========================================================================
    // DEFAULT STATE
    // ========================================================================

    function test_defaultState_permissionlessDisabled() public view {
        assertFalse(validatorManager.isPermissionlessJoinEnabled(), "permissionless must default to false");
    }

    function test_defaultState_unknownPoolNotAllowed() public view {
        assertFalse(validatorManager.isValidatorPoolAllowed(alice), "arbitrary address must not be allowed by default");
    }

    // ========================================================================
    // REGISTER GATING
    // ========================================================================

    function test_register_revertsWhen_poolNotWhitelisted() public {
        address pool = _createStakePool(alice, MIN_BOND);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotWhitelisted.selector, pool));
        validatorManager.registerValidator(
            pool, "alice", _uniquePubkey(pool), CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    function test_register_succeeds_whenWhitelisted() public {
        address pool = _createStakePool(alice, MIN_BOND);
        _allow(pool);

        _register(alice, pool, "alice");
        assertTrue(validatorManager.isValidator(pool), "registration should succeed for whitelisted pool");
    }

    function test_register_succeeds_whenPermissionlessEnabled() public {
        address pool = _createStakePool(alice, MIN_BOND);

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setPermissionlessJoinEnabled(true);

        _register(alice, pool, "alice");
        assertTrue(validatorManager.isValidator(pool), "permissionless flip should bypass whitelist");
    }

    function test_register_revertsAfterRemovedFromWhitelist() public {
        address pool = _createStakePool(alice, MIN_BOND);
        _allow(pool);

        // De-list before registering
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(pool, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotWhitelisted.selector, pool));
        validatorManager.registerValidator(
            pool, "alice", _uniquePubkey(pool), CONSENSUS_POP, NETWORK_ADDRESSES, FULLNODE_ADDRESSES
        );
    }

    // ========================================================================
    // JOIN GATING
    // ========================================================================

    function test_join_revertsWhen_poolDelistedAfterRegistration() public {
        address pool = _createStakePool(alice, MIN_BOND);
        _allow(pool);
        _register(alice, pool, "alice");

        // Governance de-lists the pool after registration; re-join must be blocked.
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(pool, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotWhitelisted.selector, pool));
        validatorManager.joinValidatorSet(pool);
    }

    function test_join_succeeds_whenStillWhitelisted() public {
        address pool = _createStakePool(alice, MIN_BOND);
        _allow(pool);
        _register(alice, pool, "alice");

        vm.prank(alice);
        validatorManager.joinValidatorSet(pool);
    }

    function test_join_succeeds_whenPermissionlessEnabled() public {
        address pool = _createStakePool(alice, MIN_BOND);
        _allow(pool);
        _register(alice, pool, "alice");

        // Remove from whitelist, then flip to permissionless; join should still pass.
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(pool, false);
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setPermissionlessJoinEnabled(true);

        vm.prank(alice);
        validatorManager.joinValidatorSet(pool);
    }

    // ========================================================================
    // GOVERNANCE ACCESS CONTROL
    // ========================================================================

    function test_setValidatorPoolAllowed_revertsWhen_notGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        validatorManager.setValidatorPoolAllowed(alice, true);
    }

    function test_setValidatorPoolAllowed_revertsWhen_zeroAddress() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        validatorManager.setValidatorPoolAllowed(address(0), true);
    }

    function test_setValidatorPoolAllowed_togglesState() public {
        assertFalse(validatorManager.isValidatorPoolAllowed(alice));

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(alice, true);
        assertTrue(validatorManager.isValidatorPoolAllowed(alice), "should be allowed after enable");

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(alice, false);
        assertFalse(validatorManager.isValidatorPoolAllowed(alice), "should be disallowed after disable");
    }

    function test_setValidatorPoolAllowed_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ValidatorPoolAllowed(alice, true);
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(alice, true);

        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ValidatorPoolAllowed(alice, false);
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setValidatorPoolAllowed(alice, false);
    }

    function test_setPermissionlessJoinEnabled_revertsWhen_notGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        validatorManager.setPermissionlessJoinEnabled(true);
    }

    function test_setPermissionlessJoinEnabled_togglesState() public {
        assertFalse(validatorManager.isPermissionlessJoinEnabled());

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setPermissionlessJoinEnabled(true);
        assertTrue(validatorManager.isPermissionlessJoinEnabled());

        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setPermissionlessJoinEnabled(false);
        assertFalse(validatorManager.isPermissionlessJoinEnabled());
    }

    function test_setPermissionlessJoinEnabled_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IValidatorManagement.PermissionlessJoinEnabledUpdated(true);
        vm.prank(SystemAddresses.GOVERNANCE);
        validatorManager.setPermissionlessJoinEnabled(true);
    }

    // ========================================================================
    // GENESIS AUTO-POPULATE
    // ========================================================================

    function test_genesisValidators_autoWhitelisted() public {
        // Genesis-style init: seed the whitelist from the validator list itself.
        GenesisValidator[] memory vs = new GenesisValidator[](2);
        vs[0] = GenesisValidator({
            stakePool: alice,
            moniker: "g-alice",
            consensusPubkey: _uniquePubkey(alice),
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });
        vs[1] = GenesisValidator({
            stakePool: bob,
            moniker: "g-bob",
            consensusPubkey: _uniquePubkey(bob),
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: bob,
            votingPower: 100 ether
        });

        vm.prank(SystemAddresses.GENESIS);
        validatorManager.initialize(vs);

        assertTrue(validatorManager.isValidatorPoolAllowed(alice), "genesis pool alice must be auto-allowed");
        assertTrue(validatorManager.isValidatorPoolAllowed(bob), "genesis pool bob must be auto-allowed");
        assertFalse(validatorManager.isValidatorPoolAllowed(carol), "non-genesis address must remain disallowed");
        assertFalse(
            validatorManager.isPermissionlessJoinEnabled(), "permissionless must still be off after genesis init"
        );
    }

    function test_genesisAutoWhitelist_emitsEvent() public {
        GenesisValidator[] memory vs = new GenesisValidator[](1);
        vs[0] = GenesisValidator({
            stakePool: alice,
            moniker: "g-alice",
            consensusPubkey: _uniquePubkey(alice),
            consensusPop: CONSENSUS_POP,
            networkAddresses: NETWORK_ADDRESSES,
            fullnodeAddresses: FULLNODE_ADDRESSES,
            feeRecipient: alice,
            votingPower: 100 ether
        });

        vm.expectEmit(true, false, false, true);
        emit IValidatorManagement.ValidatorPoolAllowed(alice, true);
        vm.prank(SystemAddresses.GENESIS);
        validatorManager.initialize(vs);
    }
}
