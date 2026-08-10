// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ValidatorConsensusInfo } from "src/foundation/Types.sol";

/// @notice Marker contract used as a realistic, non-EOA validator-pool identity in the local demo.
contract LocalBattleStakePool {
    address public immutable initialVoter;

    constructor(
        address initialVoter_
    ) {
        initialVoter = initialVoter_;
    }
}

/// @notice Minimal local implementation of the IStaking surface consumed by LLMBattle.
/// @dev Demo-only infrastructure. Production deployments should use Gravity's real Staking contract.
contract LocalBattleStaking {
    address public immutable owner;

    mapping(address pool => bool registered) public isPool;
    mapping(address pool => address voter) private _poolVoters;

    event PoolCreated(address indexed pool, address indexed voter);
    event PoolVoterUpdated(address indexed pool, address indexed oldVoter, address indexed newVoter);

    error NotOwner(address caller);
    error ZeroAddress();
    error UnknownPool(address pool);

    constructor(
        address owner_
    ) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    function createPool(
        address voter
    ) external onlyOwner returns (address pool) {
        if (voter == address(0)) revert ZeroAddress();

        pool = address(new LocalBattleStakePool(voter));
        isPool[pool] = true;
        _poolVoters[pool] = voter;
        emit PoolCreated(pool, voter);
    }

    function setPoolVoter(
        address pool,
        address newVoter
    ) external onlyOwner {
        if (!isPool[pool]) revert UnknownPool(pool);
        if (newVoter == address(0)) revert ZeroAddress();

        address oldVoter = _poolVoters[pool];
        _poolVoters[pool] = newVoter;
        emit PoolVoterUpdated(pool, oldVoter, newVoter);
    }

    function getPoolVoter(
        address pool
    ) external view returns (address) {
        if (!isPool[pool]) revert UnknownPool(pool);
        return _poolVoters[pool];
    }
}

/// @notice Minimal local implementation of the IValidatorManagement surface consumed by LLMBattle.
/// @dev Keeps validator membership separate from voter delegation, matching Gravity's production boundary.
contract LocalBattleValidatorManagement {
    address public immutable owner;

    uint64 private _currentEpoch;
    ValidatorConsensusInfo[] private _activeValidators;
    mapping(address pool => bool active) public isActiveValidator;

    event ValidatorAdded(address indexed pool, uint64 indexed validatorIndex, uint256 votingPower);
    event CurrentEpochUpdated(uint64 indexed oldEpoch, uint64 indexed newEpoch);

    error NotOwner(address caller);
    error ZeroAddress();
    error ZeroVotingPower();
    error ValidatorAlreadyActive(address pool);
    error TooManyValidators();

    constructor(
        address owner_,
        uint64 initialEpoch
    ) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        _currentEpoch = initialEpoch;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    function addValidator(
        address pool,
        uint256 votingPower
    ) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        if (votingPower == 0) revert ZeroVotingPower();
        if (isActiveValidator[pool]) revert ValidatorAlreadyActive(pool);
        if (_activeValidators.length > type(uint64).max) revert TooManyValidators();

        uint64 validatorIndex = uint64(_activeValidators.length);
        _activeValidators.push(
            ValidatorConsensusInfo({
                validator: pool,
                consensusPubkey: "",
                consensusPop: "",
                votingPower: votingPower,
                validatorIndex: validatorIndex,
                networkAddresses: "",
                fullnodeAddresses: ""
            })
        );
        isActiveValidator[pool] = true;
        emit ValidatorAdded(pool, validatorIndex, votingPower);
    }

    function setCurrentEpoch(
        uint64 newEpoch
    ) external onlyOwner {
        uint64 oldEpoch = _currentEpoch;
        _currentEpoch = newEpoch;
        emit CurrentEpochUpdated(oldEpoch, newEpoch);
    }

    function getCurrentEpoch() external view returns (uint64) {
        return _currentEpoch;
    }

    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        return _activeValidators;
    }
}
