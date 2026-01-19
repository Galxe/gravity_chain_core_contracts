// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IJWKManager
/// @author Gravity Team
/// @notice Interface for the JWK Manager contract
/// @dev Stores JSON Web Keys (JWKs) from OIDC providers for keyless account authentication.
///      JWKs are observed by validators via consensus and can be patched by governance.
///      This contract receives oracle callbacks and manages its own storage (skips NativeOracle storage).
interface IJWKManager {
    // ========================================================================
    // DATA STRUCTURES
    // ========================================================================

    /// @notice RSA JSON Web Key structure
    /// @dev Represents an RSA public key used for JWT signature verification
    struct RSA_JWK {
        /// @notice Key ID - unique identifier within an issuer's key set
        string kid;
        /// @notice Key Type (always "RSA" for RSA keys)
        string kty;
        /// @notice Algorithm (e.g., "RS256", "RS384", "RS512")
        string alg;
        /// @notice RSA public exponent (Base64url-encoded)
        string e;
        /// @notice RSA modulus (Base64url-encoded)
        string n;
    }

    /// @notice JWK set for a single provider/issuer
    /// @dev JWKs are sorted by kid for deterministic ordering
    struct ProviderJWKs {
        /// @notice The issuer URL (e.g., "https://accounts.google.com")
        bytes issuer;
        /// @notice Version number for dedup/ordering (bumped on each update)
        uint64 version;
        /// @notice Array of RSA JWKs, sorted by kid
        RSA_JWK[] jwks;
    }

    /// @notice Collection of all provider JWK sets
    /// @dev Entries are sorted by issuer for deterministic ordering
    struct AllProvidersJWKs {
        /// @notice Array of ProviderJWKs, sorted by issuer
        ProviderJWKs[] entries;
    }

    // ========================================================================
    // PATCH TYPES
    // ========================================================================

    /// @notice Patch type enumeration
    /// @dev Used to identify the type of patch operation
    enum PatchType {
        /// @notice Remove all JWKs (clear everything)
        RemoveAll,
        /// @notice Remove a specific issuer and all its JWKs
        RemoveIssuer,
        /// @notice Remove a specific JWK by issuer and kid
        RemoveJWK,
        /// @notice Add or update a specific JWK for an issuer
        UpsertJWK
    }

    /// @notice A patch operation to modify JWKs
    /// @dev Patches are applied in order to observed JWKs to produce patched JWKs
    struct Patch {
        /// @notice The type of patch operation
        PatchType patchType;
        /// @notice Issuer URL (used for RemoveIssuer, RemoveJWK, UpsertJWK)
        bytes issuer;
        /// @notice Key ID (used for RemoveJWK)
        string kid;
        /// @notice JWK to upsert (used for UpsertJWK)
        RSA_JWK jwk;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when observed JWKs are updated from oracle
    /// @param issuer The issuer whose JWKs were updated
    /// @param version The new version number
    /// @param jwkCount Number of JWKs in the update
    event ObservedJWKsUpdated(bytes indexed issuer, uint64 version, uint256 jwkCount);

    /// @notice Emitted when governance patches are updated
    /// @param patchCount Number of patches in the new configuration
    event PatchesUpdated(uint256 patchCount);

    /// @notice Emitted when patched JWKs are regenerated
    /// @param providerCount Number of providers in the patched set
    event PatchedJWKsRegenerated(uint256 providerCount);

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @notice Get a specific JWK by issuer and key ID from patched JWKs
    /// @dev Returns empty JWK if not found (check kid.length == 0)
    /// @param issuer The issuer URL
    /// @param kid The key ID
    /// @return jwk The JWK if found, empty struct otherwise
    function getJWK(
        bytes calldata issuer,
        string calldata kid
    ) external view returns (RSA_JWK memory jwk);

    /// @notice Check if a specific JWK exists in patched JWKs
    /// @param issuer The issuer URL
    /// @param kid The key ID
    /// @return exists True if the JWK exists
    function hasJWK(
        bytes calldata issuer,
        string calldata kid
    ) external view returns (bool exists);

    /// @notice Get all JWKs for a specific provider from patched JWKs
    /// @dev Returns empty struct if provider not found (check issuer.length == 0)
    /// @param issuer The issuer URL
    /// @return providerJwks The provider's JWK set
    function getProviderJWKs(
        bytes calldata issuer
    ) external view returns (ProviderJWKs memory providerJwks);

    /// @notice Get all patched JWKs
    /// @dev This is the final result after applying patches to observed JWKs
    /// @return allJwks The complete patched JWK set
    function getPatchedJWKs() external view returns (AllProvidersJWKs memory allJwks);

    /// @notice Get all observed JWKs (before patches)
    /// @dev This is the raw consensus-observed data
    /// @return allJwks The complete observed JWK set
    function getObservedJWKs() external view returns (AllProvidersJWKs memory allJwks);

    /// @notice Get the current governance patches
    /// @return patches Array of patches
    function getPatches() external view returns (Patch[] memory patches);

    /// @notice Get the number of providers in patched JWKs
    /// @return count Number of providers
    function getProviderCount() external view returns (uint256 count);

    /// @notice Get provider issuer by index from patched JWKs
    /// @param index The provider index
    /// @return issuer The issuer URL
    function getProviderIssuerAt(
        uint256 index
    ) external view returns (bytes memory issuer);

    // ========================================================================
    // GOVERNANCE FUNCTIONS
    // ========================================================================

    /// @notice Set governance patches
    /// @dev Only callable by GOVERNANCE. Patches are applied to observed JWKs to produce patched JWKs.
    /// @param patches Array of patch operations to apply
    function setPatches(
        Patch[] calldata patches
    ) external;

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    /// @notice Calculate the sourceId for a given issuer
    /// @dev sourceId = uint256(keccak256(issuer))
    /// @param issuer The issuer URL
    /// @return sourceId The calculated source ID
    function calculateSourceId(
        bytes calldata issuer
    ) external pure returns (uint256 sourceId);
}

