// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title Counter
/// @notice A simple upgradable counter contract
contract Counter is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 internal _count;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner
    ) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        _count = 0;
    }

    function increment() public {
        _count += 1;
    }

    function getCount() public view returns (uint256) {
        return _count;
    }

    function version() public pure virtual returns (string memory) {
        return "v1.0.0";
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner { }
}
