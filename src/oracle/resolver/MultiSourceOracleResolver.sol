// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { PriceFeedResolver } from "./PriceFeedResolver.sol";

/// @title MultiSourceOracleResolver
/// @notice Compatibility name for the multi-source price feed resolver.
/// @dev New integrations should use PriceFeedResolver directly.
contract MultiSourceOracleResolver is PriceFeedResolver { }
