// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IJWKManager } from "./IJWKManager.sol";
import { IOracleCallback } from "../INativeOracle.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";
import { Errors } from "../../foundation/Errors.sol";

/// @title JWKManager
/// @author Gravity Team
/// @notice Manages JSON Web Keys (JWKs) from OIDC providers for keyless account authentication
/// @dev Implements IOracleCallback to receive JWK updates from NativeOracle.
///      JWKs are stored directly in this contract (skips NativeOracle storage).
///      Supports governance-controlled patches to override observed JWKs.
contract JWKManager is IJWKManager, IOracleCallback {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Source type for JWK data in NativeOracle
    uint32 public constant SOURCE_TYPE_JWK = 1;

    // ========================================================================
    // STATE - Using explicit mappings to avoid dynamic array copy issues
    // ========================================================================

    /// @notice Observed provider issuers (in insertion order for iteration)
    bytes[] private _observedIssuers;

    /// @notice Observed JWKs indexed by issuer hash
    mapping(bytes32 => ProviderJWKsStorage) private _observedProviders;

    /// @notice Governance patches to apply to observed JWKs
    Patch[] private _patches;

    /// @notice Patched provider issuers (in sorted order for iteration)
    bytes[] private _patchedIssuers;

    /// @notice Patched JWKs indexed by issuer hash
    mapping(bytes32 => ProviderJWKsStorage) private _patchedProviders;

    /// @notice Version tracking per issuer for replay protection
    mapping(bytes32 => uint64) private _issuerVersions;

    /// @notice Internal storage struct for provider JWKs (avoids dynamic array issues)
    struct ProviderJWKsStorage {
        bytes issuer;
        uint64 version;
        RSA_JWK[] jwks;
        bool exists;
    }

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the contract (can only be called once by GENESIS)
    /// @param issuers Array of initial provider issuers
    /// @param jwks Array of JWK arrays corresponding to each issuer
    function initialize(
        bytes[] calldata issuers,
        RSA_JWK[][] calldata jwks
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        uint256 length = issuers.length;
        if (length != jwks.length) {
            revert Errors.ArrayLengthMismatch(length, jwks.length);
        }

        for (uint256 i; i < length;) {
            bytes memory issuer = issuers[i];
            bytes32 issuerHash = keccak256(issuer);
            
            // Initial version is 1 for genesis validators
            uint64 version = 1;

            // Update version tracking
            _issuerVersions[issuerHash] = version;

            // Upsert into observed JWKs
            _upsertObservedProvider(issuerHash, issuer, version, jwks[i]);

            emit ObservedJWKsUpdated(issuer, version, jwks[i].length);

            unchecked {
                ++i;
            }
        }

        // Regenerate patched JWKs (populates public state from observed)
        _regeneratePatchedJWKs();

        _initialized = true;
    }

    // ========================================================================
    // ORACLE CALLBACK
    // ========================================================================

    /// @notice Called by NativeOracle when JWK data is recorded
    /// @dev Parses the payload, updates observed JWKs, and regenerates patched JWKs.
    ///      Returns false to skip storage in NativeOracle (JWKManager handles its own storage).
    /// @param sourceType The source type (must be SOURCE_TYPE_JWK = 1)
    /// @param sourceId The source identifier (keccak256 of issuer URL)
    /// @param nonce The oracle nonce
    /// @param payload ABI-encoded JWK payload: (bytes issuer, uint64 version, RSA_JWK[] jwks)
    /// @return shouldStore Always returns false - JWKManager handles its own storage
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external override returns (bool shouldStore) {
        // Only NativeOracle can call this
        if (msg.sender != SystemAddresses.NATIVE_ORACLE) {
            revert Errors.JWKOnlyNativeOracle();
        }

        // Silence unused variable warnings
        (sourceType, sourceId, nonce);

        // Decode payload
        (bytes memory issuer, uint64 version, RSA_JWK[] memory jwks) = abi.decode(payload, (bytes, uint64, RSA_JWK[]));

        // Validate version is increasing
        bytes32 issuerHash = keccak256(issuer);
        uint64 currentVersion = _issuerVersions[issuerHash];
        if (version <= currentVersion) {
            revert Errors.JWKVersionNotIncreasing(issuer, currentVersion, version);
        }

        // Update version tracking
        _issuerVersions[issuerHash] = version;

        // Upsert into observed JWKs
        _upsertObservedProvider(issuerHash, issuer, version, jwks);

        emit ObservedJWKsUpdated(issuer, version, jwks.length);

        // Regenerate patched JWKs
        _regeneratePatchedJWKs();

        // Skip storage in NativeOracle - we handle our own storage
        return false;
    }

    // ========================================================================
    // GOVERNANCE FUNCTIONS
    // ========================================================================

    /// @inheritdoc IJWKManager
    function setPatches(
        Patch[] calldata patches
    ) external override {
        requireAllowed(SystemAddresses.GOVERNANCE);

        // Clear existing patches
        delete _patches;

        // Copy new patches
        for (uint256 i; i < patches.length;) {
            _patches.push(patches[i]);
            unchecked {
                ++i;
            }
        }

        emit PatchesUpdated(patches.length);

        // Regenerate patched JWKs
        _regeneratePatchedJWKs();
    }

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @inheritdoc IJWKManager
    function getJWK(
        bytes calldata issuer,
        string calldata kid
    ) external view override returns (RSA_JWK memory jwk) {
        bytes32 issuerHash = keccak256(issuer);
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];
        if (!provider.exists) return jwk;

        for (uint256 i; i < provider.jwks.length;) {
            if (_stringsEqual(provider.jwks[i].kid, kid)) {
                return provider.jwks[i];
            }
            unchecked {
                ++i;
            }
        }
        return jwk;
    }

    /// @inheritdoc IJWKManager
    function hasJWK(
        bytes calldata issuer,
        string calldata kid
    ) external view override returns (bool exists) {
        bytes32 issuerHash = keccak256(issuer);
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];
        if (!provider.exists) return false;

        for (uint256 i; i < provider.jwks.length;) {
            if (_stringsEqual(provider.jwks[i].kid, kid)) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @inheritdoc IJWKManager
    function getProviderJWKs(
        bytes calldata issuer
    ) external view override returns (ProviderJWKs memory providerJwks) {
        bytes32 issuerHash = keccak256(issuer);
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];
        if (!provider.exists) return providerJwks;

        return ProviderJWKs({ issuer: provider.issuer, version: provider.version, jwks: provider.jwks });
    }

    /// @inheritdoc IJWKManager
    function getPatchedJWKs() external view override returns (AllProvidersJWKs memory allJwks) {
        uint256 len = _patchedIssuers.length;
        ProviderJWKs[] memory entries = new ProviderJWKs[](len);

        for (uint256 i; i < len;) {
            bytes32 issuerHash = keccak256(_patchedIssuers[i]);
            ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];
            entries[i] = ProviderJWKs({ issuer: provider.issuer, version: provider.version, jwks: provider.jwks });
            unchecked {
                ++i;
            }
        }

        return AllProvidersJWKs({ entries: entries });
    }

    /// @inheritdoc IJWKManager
    function getObservedJWKs() external view override returns (AllProvidersJWKs memory allJwks) {
        uint256 len = _observedIssuers.length;
        ProviderJWKs[] memory entries = new ProviderJWKs[](len);

        for (uint256 i; i < len;) {
            bytes32 issuerHash = keccak256(_observedIssuers[i]);
            ProviderJWKsStorage storage provider = _observedProviders[issuerHash];
            entries[i] = ProviderJWKs({ issuer: provider.issuer, version: provider.version, jwks: provider.jwks });
            unchecked {
                ++i;
            }
        }

        return AllProvidersJWKs({ entries: entries });
    }

    /// @inheritdoc IJWKManager
    function getPatches() external view override returns (Patch[] memory patches) {
        return _patches;
    }

    /// @inheritdoc IJWKManager
    function getProviderCount() external view override returns (uint256 count) {
        return _patchedIssuers.length;
    }

    /// @inheritdoc IJWKManager
    function getProviderIssuerAt(
        uint256 index
    ) external view override returns (bytes memory issuer) {
        if (index >= _patchedIssuers.length) {
            revert Errors.JWKProviderIndexOutOfBounds(index, _patchedIssuers.length);
        }
        return _patchedIssuers[index];
    }

    /// @inheritdoc IJWKManager
    function calculateSourceId(
        bytes calldata issuer
    ) external pure override returns (uint256 sourceId) {
        return uint256(keccak256(issuer));
    }

    // ========================================================================
    // INTERNAL FUNCTIONS - Observed JWKs
    // ========================================================================

    /// @notice Upsert a provider into observed storage
    function _upsertObservedProvider(
        bytes32 issuerHash,
        bytes memory issuer,
        uint64 version,
        RSA_JWK[] memory jwks
    ) internal {
        ProviderJWKsStorage storage provider = _observedProviders[issuerHash];

        if (!provider.exists) {
            // New provider - add to issuers list
            _observedIssuers.push(issuer);
            provider.exists = true;
        }

        provider.issuer = issuer;
        provider.version = version;

        // Clear and copy JWKs
        delete provider.jwks;
        for (uint256 i; i < jwks.length;) {
            provider.jwks.push(jwks[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ========================================================================
    // INTERNAL FUNCTIONS - Patched JWKs
    // ========================================================================

    /// @notice Regenerate patched JWKs by applying patches to observed JWKs
    function _regeneratePatchedJWKs() internal {
        // Clear patched state
        _clearPatchedState();

        // Copy observed to patched
        for (uint256 i; i < _observedIssuers.length;) {
            bytes memory issuer = _observedIssuers[i];
            bytes32 issuerHash = keccak256(issuer);
            ProviderJWKsStorage storage observed = _observedProviders[issuerHash];

            _upsertPatchedProvider(issuerHash, observed.issuer, observed.version, observed.jwks);
            unchecked {
                ++i;
            }
        }

        // Apply each patch
        for (uint256 i; i < _patches.length;) {
            _applyPatch(_patches[i]);
            unchecked {
                ++i;
            }
        }

        emit PatchedJWKsRegenerated(_patchedIssuers.length);
    }

    /// @notice Clear all patched state
    function _clearPatchedState() internal {
        // Clear provider data
        for (uint256 i; i < _patchedIssuers.length;) {
            bytes32 issuerHash = keccak256(_patchedIssuers[i]);
            delete _patchedProviders[issuerHash];
            unchecked {
                ++i;
            }
        }
        // Clear issuers list
        delete _patchedIssuers;
    }

    /// @notice Upsert a provider into patched storage
    function _upsertPatchedProvider(
        bytes32 issuerHash,
        bytes memory issuer,
        uint64 version,
        RSA_JWK[] memory jwks
    ) internal {
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];

        if (!provider.exists) {
            // New provider - add to sorted issuers list
            _insertSortedIssuer(_patchedIssuers, issuer);
            provider.exists = true;
        }

        provider.issuer = issuer;
        provider.version = version;

        // Clear and copy JWKs
        delete provider.jwks;
        for (uint256 i; i < jwks.length;) {
            provider.jwks.push(jwks[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Upsert from storage to storage
    function _upsertPatchedProviderFromStorage(
        bytes32 issuerHash,
        ProviderJWKsStorage storage source
    ) internal {
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];

        if (!provider.exists) {
            _insertSortedIssuer(_patchedIssuers, source.issuer);
            provider.exists = true;
        }

        provider.issuer = source.issuer;
        provider.version = source.version;

        delete provider.jwks;
        for (uint256 i; i < source.jwks.length;) {
            provider.jwks.push(source.jwks[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Insert an issuer into a sorted array
    function _insertSortedIssuer(
        bytes[] storage issuers,
        bytes memory issuer
    ) internal {
        uint256 len = issuers.length;

        // Find insertion point
        uint256 insertIdx = len;
        for (uint256 i; i < len;) {
            if (_compareBytes(issuer, issuers[i]) < 0) {
                insertIdx = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Add empty slot at end
        issuers.push();

        // Shift right
        for (uint256 i = len; i > insertIdx;) {
            issuers[i] = issuers[i - 1];
            unchecked {
                --i;
            }
        }

        // Insert
        issuers[insertIdx] = issuer;
    }

    /// @notice Remove an issuer from the patched issuers list
    function _removePatchedIssuer(
        bytes memory issuer
    ) internal {
        bytes32 issuerHash = keccak256(issuer);
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];

        if (!provider.exists) return;

        // Find and remove from issuers list
        uint256 len = _patchedIssuers.length;
        for (uint256 i; i < len;) {
            if (keccak256(_patchedIssuers[i]) == issuerHash) {
                // Shift left
                for (uint256 j = i; j < len - 1;) {
                    _patchedIssuers[j] = _patchedIssuers[j + 1];
                    unchecked {
                        ++j;
                    }
                }
                _patchedIssuers.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Clear provider data
        delete _patchedProviders[issuerHash];
    }

    /// @notice Apply a single patch
    function _applyPatch(
        Patch memory patch
    ) internal {
        if (patch.patchType == PatchType.RemoveAll) {
            _clearPatchedState();
        } else if (patch.patchType == PatchType.RemoveIssuer) {
            _removePatchedIssuer(patch.issuer);
        } else if (patch.patchType == PatchType.RemoveJWK) {
            _removeJWKFromPatched(patch.issuer, patch.kid);
        } else if (patch.patchType == PatchType.UpsertJWK) {
            _upsertJWKToPatched(patch.issuer, patch.jwk);
        } else {
            revert Errors.JWKInvalidPatchType(uint8(patch.patchType));
        }
    }

    /// @notice Remove a specific JWK from patched
    function _removeJWKFromPatched(
        bytes memory issuer,
        string memory kid
    ) internal {
        bytes32 issuerHash = keccak256(issuer);
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];

        if (!provider.exists) return;

        // Find and remove the JWK
        uint256 len = provider.jwks.length;
        for (uint256 i; i < len;) {
            if (_stringsEqual(provider.jwks[i].kid, kid)) {
                // Shift left
                for (uint256 j = i; j < len - 1;) {
                    provider.jwks[j] = provider.jwks[j + 1];
                    unchecked {
                        ++j;
                    }
                }
                provider.jwks.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Upsert a JWK to patched (creates provider if needed)
    function _upsertJWKToPatched(
        bytes memory issuer,
        RSA_JWK memory jwk
    ) internal {
        bytes32 issuerHash = keccak256(issuer);
        ProviderJWKsStorage storage provider = _patchedProviders[issuerHash];

        if (!provider.exists) {
            // Create new provider
            _insertSortedIssuer(_patchedIssuers, issuer);
            provider.exists = true;
            provider.issuer = issuer;
            provider.version = 0; // Patches don't track version
            provider.jwks.push(jwk);
            return;
        }

        // Find existing JWK by kid
        uint256 len = provider.jwks.length;
        for (uint256 i; i < len;) {
            if (_stringsEqual(provider.jwks[i].kid, jwk.kid)) {
                // Update existing
                provider.jwks[i] = jwk;
                return;
            }
            unchecked {
                ++i;
            }
        }

        // Insert new JWK in sorted order
        uint256 insertIdx = len;
        for (uint256 i; i < len;) {
            if (_compareStrings(jwk.kid, provider.jwks[i].kid) < 0) {
                insertIdx = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Add empty slot
        provider.jwks.push();

        // Shift right
        for (uint256 i = len; i > insertIdx;) {
            provider.jwks[i] = provider.jwks[i - 1];
            unchecked {
                --i;
            }
        }

        // Insert
        provider.jwks[insertIdx] = jwk;
    }

    // ========================================================================
    // INTERNAL FUNCTIONS - Comparison helpers
    // ========================================================================

    /// @notice Compare two byte arrays lexicographically
    /// @return -1 if a < b, 0 if a == b, 1 if a > b
    function _compareBytes(
        bytes memory a,
        bytes memory b
    ) internal pure returns (int256) {
        uint256 minLen = a.length < b.length ? a.length : b.length;
        for (uint256 i; i < minLen;) {
            if (a[i] < b[i]) return -1;
            if (a[i] > b[i]) return 1;
            unchecked {
                ++i;
            }
        }
        if (a.length < b.length) return -1;
        if (a.length > b.length) return 1;
        return 0;
    }

    /// @notice Compare two strings lexicographically
    /// @return -1 if a < b, 0 if a == b, 1 if a > b
    function _compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (int256) {
        return _compareBytes(bytes(a), bytes(b));
    }

    /// @notice Check if two strings are equal
    function _stringsEqual(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
