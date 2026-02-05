// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { JWKManager } from "../../../src/oracle/jwk/JWKManager.sol";
import { IJWKManager } from "../../../src/oracle/jwk/IJWKManager.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle } from "../../../src/oracle/INativeOracle.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { Errors } from "../../../src/foundation/Errors.sol";

/// @title JWKManagerTest
/// @notice Comprehensive unit tests for JWKManager contract
contract JWKManagerTest is Test {
    JWKManager public jwkManager;
    NativeOracle public oracle;

    // Test addresses
    address public systemCaller;
    address public governance;
    address public alice;

    // Test data
    uint32 public constant SOURCE_TYPE_JWK = 1;
    uint256 public constant CALLBACK_GAS_LIMIT = 2_000_000; // JWKManager needs more gas for storage operations

    // Sample issuers
    bytes public constant GOOGLE_ISSUER = bytes("https://accounts.google.com");
    bytes public constant APPLE_ISSUER = bytes("https://appleid.apple.com");

    function setUp() public {
        // Set up addresses
        systemCaller = SystemAddresses.SYSTEM_CALLER;
        governance = SystemAddresses.GOVERNANCE;
        alice = makeAddr("alice");

        // Deploy contracts
        oracle = new NativeOracle();

        // Deploy JWKManager at the system address
        vm.etch(SystemAddresses.JWK_MANAGER, address(new JWKManager()).code);
        jwkManager = JWKManager(SystemAddresses.JWK_MANAGER);

        // Etch NativeOracle at system address so JWKManager can verify caller
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(oracle).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);

        // Register JWKManager as callback for JWK source type
        vm.prank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_JWK, address(jwkManager));
    }

    // ========================================================================
    // HELPER FUNCTIONS
    // ========================================================================

    function _createSampleJWK(
        string memory kid
    ) internal pure returns (IJWKManager.RSA_JWK memory) {
        return IJWKManager.RSA_JWK({ kid: kid, kty: "RSA", alg: "RS256", e: "AQAB", n: "sample_modulus_base64url" });
    }

    function _createPayload(
        bytes memory issuer,
        uint64 version,
        IJWKManager.RSA_JWK[] memory jwks
    ) internal pure returns (bytes memory) {
        return abi.encode(issuer, version, jwks);
    }

    function _recordJWK(
        bytes memory issuer,
        uint64 version,
        IJWKManager.RSA_JWK[] memory jwks,
        uint128 nonce
    ) internal {
        bytes memory payload = _createPayload(issuer, version, jwks);
        uint256 sourceId = uint256(keccak256(issuer));

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, sourceId, nonce, 0, payload, CALLBACK_GAS_LIMIT);
    }

    // ========================================================================
    // ORACLE CALLBACK TESTS
    // ========================================================================

    function test_OnOracleEvent_RecordJWKs() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](2);
        jwks[0] = _createSampleJWK("key1");
        jwks[1] = _createSampleJWK("key2");

        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        // Verify JWKs are stored
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key2"));

        // Verify provider count
        assertEq(jwkManager.getProviderCount(), 1);
    }

    function test_OnOracleEvent_SkipsNativeOracleStorage() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");

        bytes memory payload = _createPayload(GOOGLE_ISSUER, 1, jwks);
        uint256 sourceId = uint256(keccak256(GOOGLE_ISSUER));

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, sourceId, 1, 0, payload, CALLBACK_GAS_LIMIT);

        // Verify JWKs are stored in JWKManager
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));

        // Verify data is NOT stored in NativeOracle (storage skipped)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_JWK, sourceId, 1);
        assertEq(record.recordedAt, 0);
    }

    function test_OnOracleEvent_RevertWhenNotNativeOracle() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");
        bytes memory payload = _createPayload(GOOGLE_ISSUER, 1, jwks);

        vm.expectRevert(Errors.JWKOnlyNativeOracle.selector);
        vm.prank(alice);
        jwkManager.onOracleEvent(SOURCE_TYPE_JWK, 1, 1, payload);
    }

    function test_OnOracleEvent_VersionNotIncreasingCausesCallbackFailure() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");

        // First record succeeds
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        // Verify key1 exists
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));

        // Second record with same version - callback will fail but NativeOracle won't revert
        // (because callback failures are caught). The data will be stored in NativeOracle
        // but JWKManager will NOT update its state.
        uint256 sourceId = uint256(keccak256(GOOGLE_ISSUER));
        bytes memory payload = _createPayload(GOOGLE_ISSUER, 1, jwks); // Same version

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, sourceId, 2, 0, payload, CALLBACK_GAS_LIMIT);

        // JWKManager still has the original version (callback failed, state unchanged)
        IJWKManager.ProviderJWKs memory provider = jwkManager.getProviderJWKs(GOOGLE_ISSUER);
        assertEq(provider.version, 1);

        // NativeOracle stored the data (because callback failure defaults to store)
        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_JWK, sourceId, 2);
        assertTrue(record.recordedAt > 0);
    }

    function test_OnOracleEvent_UpdateExistingProvider() public {
        // First record
        IJWKManager.RSA_JWK[] memory jwks1 = new IJWKManager.RSA_JWK[](1);
        jwks1[0] = _createSampleJWK("key1");
        _recordJWK(GOOGLE_ISSUER, 1, jwks1, 1);

        // Update with new key
        IJWKManager.RSA_JWK[] memory jwks2 = new IJWKManager.RSA_JWK[](2);
        jwks2[0] = _createSampleJWK("key1");
        jwks2[1] = _createSampleJWK("key2");
        _recordJWK(GOOGLE_ISSUER, 2, jwks2, 2);

        // Verify both keys exist
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key2"));

        // Provider count should still be 1
        assertEq(jwkManager.getProviderCount(), 1);
    }

    function test_OnOracleEvent_MultipleProviders() public {
        // Add Google keys
        IJWKManager.RSA_JWK[] memory googleJwks = new IJWKManager.RSA_JWK[](1);
        googleJwks[0] = _createSampleJWK("google_key");
        _recordJWK(GOOGLE_ISSUER, 1, googleJwks, 1);

        // Add Apple keys
        IJWKManager.RSA_JWK[] memory appleJwks = new IJWKManager.RSA_JWK[](1);
        appleJwks[0] = _createSampleJWK("apple_key");
        uint256 appleSourceId = uint256(keccak256(APPLE_ISSUER));
        bytes memory applePayload = _createPayload(APPLE_ISSUER, 1, appleJwks);
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, appleSourceId, 1, 0, applePayload, CALLBACK_GAS_LIMIT);

        // Verify both providers
        assertEq(jwkManager.getProviderCount(), 2);
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "google_key"));
        assertTrue(jwkManager.hasJWK(APPLE_ISSUER, "apple_key"));
    }

    // ========================================================================
    // QUERY TESTS
    // ========================================================================

    function test_GetJWK() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = IJWKManager.RSA_JWK({ kid: "test_kid", kty: "RSA", alg: "RS256", e: "AQAB", n: "test_modulus" });
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        IJWKManager.RSA_JWK memory result = jwkManager.getJWK(GOOGLE_ISSUER, "test_kid");
        assertEq(result.kid, "test_kid");
        assertEq(result.kty, "RSA");
        assertEq(result.alg, "RS256");
        assertEq(result.e, "AQAB");
        assertEq(result.n, "test_modulus");
    }

    function test_GetJWK_NotFound() public {
        IJWKManager.RSA_JWK memory result = jwkManager.getJWK(GOOGLE_ISSUER, "nonexistent");
        assertEq(bytes(result.kid).length, 0);
    }

    function test_HasJWK() public {
        assertFalse(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));

        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
        assertFalse(jwkManager.hasJWK(GOOGLE_ISSUER, "key2"));
    }

    function test_GetProviderJWKs() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](2);
        jwks[0] = _createSampleJWK("key1");
        jwks[1] = _createSampleJWK("key2");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        IJWKManager.ProviderJWKs memory provider = jwkManager.getProviderJWKs(GOOGLE_ISSUER);
        assertEq(provider.issuer, GOOGLE_ISSUER);
        assertEq(provider.version, 1);
        assertEq(provider.jwks.length, 2);
    }

    function test_GetProviderJWKs_NotFound() public {
        IJWKManager.ProviderJWKs memory provider = jwkManager.getProviderJWKs(GOOGLE_ISSUER);
        assertEq(provider.issuer.length, 0);
    }

    function test_GetPatchedJWKs() public {
        // Add some JWKs
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        IJWKManager.AllProvidersJWKs memory allJwks = jwkManager.getPatchedJWKs();
        assertEq(allJwks.entries.length, 1);
    }

    function test_GetObservedJWKs() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        IJWKManager.AllProvidersJWKs memory observed = jwkManager.getObservedJWKs();
        assertEq(observed.entries.length, 1);
    }

    function test_GetProviderIssuerAt() public {
        // Add two providers
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        IJWKManager.RSA_JWK[] memory appleJwks = new IJWKManager.RSA_JWK[](1);
        appleJwks[0] = _createSampleJWK("apple_key");
        uint256 appleSourceId = uint256(keccak256(APPLE_ISSUER));
        bytes memory applePayload = _createPayload(APPLE_ISSUER, 1, appleJwks);
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, appleSourceId, 1, 0, applePayload, CALLBACK_GAS_LIMIT);

        // Get issuers (should be sorted)
        bytes memory issuer0 = jwkManager.getProviderIssuerAt(0);
        bytes memory issuer1 = jwkManager.getProviderIssuerAt(1);

        // Verify they are the expected issuers (order depends on lexicographic sorting)
        assertTrue(keccak256(issuer0) != keccak256(issuer1));
    }

    function test_GetProviderIssuerAt_RevertWhenOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.JWKProviderIndexOutOfBounds.selector, 0, 0));
        jwkManager.getProviderIssuerAt(0);
    }

    function test_CalculateSourceId() public view {
        uint256 sourceId = jwkManager.calculateSourceId(GOOGLE_ISSUER);
        assertEq(sourceId, uint256(keccak256(GOOGLE_ISSUER)));
    }

    // ========================================================================
    // PATCH TESTS
    // ========================================================================

    function test_SetPatches_RemoveAll() public {
        // Add some JWKs
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));

        // Apply RemoveAll patch
        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](1);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.RemoveAll,
            issuer: "",
            kid: "",
            jwk: IJWKManager.RSA_JWK("", "", "", "", "")
        });

        vm.prank(governance);
        jwkManager.setPatches(patches);

        // Verify patched JWKs are empty
        assertFalse(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
        assertEq(jwkManager.getProviderCount(), 0);

        // But observed JWKs still exist
        IJWKManager.AllProvidersJWKs memory observed = jwkManager.getObservedJWKs();
        assertEq(observed.entries.length, 1);
    }

    function test_SetPatches_RemoveIssuer() public {
        // Add Google and Apple JWKs
        IJWKManager.RSA_JWK[] memory googleJwks = new IJWKManager.RSA_JWK[](1);
        googleJwks[0] = _createSampleJWK("google_key");
        _recordJWK(GOOGLE_ISSUER, 1, googleJwks, 1);

        IJWKManager.RSA_JWK[] memory appleJwks = new IJWKManager.RSA_JWK[](1);
        appleJwks[0] = _createSampleJWK("apple_key");
        uint256 appleSourceId = uint256(keccak256(APPLE_ISSUER));
        bytes memory applePayload = _createPayload(APPLE_ISSUER, 1, appleJwks);
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, appleSourceId, 1, 0, applePayload, CALLBACK_GAS_LIMIT);

        // Verify both exist
        assertEq(jwkManager.getProviderCount(), 2);

        // Apply RemoveIssuer patch for Google
        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](1);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.RemoveIssuer,
            issuer: GOOGLE_ISSUER,
            kid: "",
            jwk: IJWKManager.RSA_JWK("", "", "", "", "")
        });

        vm.prank(governance);
        jwkManager.setPatches(patches);

        // Verify Google is removed but Apple remains
        assertFalse(jwkManager.hasJWK(GOOGLE_ISSUER, "google_key"));
        assertTrue(jwkManager.hasJWK(APPLE_ISSUER, "apple_key"));
        assertEq(jwkManager.getProviderCount(), 1);
    }

    function test_SetPatches_RemoveJWK() public {
        // Add Google JWKs with multiple keys
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](2);
        jwks[0] = _createSampleJWK("key1");
        jwks[1] = _createSampleJWK("key2");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key2"));

        // Apply RemoveJWK patch
        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](1);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.RemoveJWK,
            issuer: GOOGLE_ISSUER,
            kid: "key1",
            jwk: IJWKManager.RSA_JWK("", "", "", "", "")
        });

        vm.prank(governance);
        jwkManager.setPatches(patches);

        // Verify key1 is removed but key2 remains
        assertFalse(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key2"));
    }

    function test_SetPatches_UpsertJWK() public {
        // Start with no JWKs
        assertFalse(jwkManager.hasJWK(GOOGLE_ISSUER, "new_key"));

        // Apply UpsertJWK patch
        IJWKManager.RSA_JWK memory newJwk =
            IJWKManager.RSA_JWK({ kid: "new_key", kty: "RSA", alg: "RS256", e: "AQAB", n: "patched_modulus" });

        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](1);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.UpsertJWK, issuer: GOOGLE_ISSUER, kid: "", jwk: newJwk
        });

        vm.prank(governance);
        jwkManager.setPatches(patches);

        // Verify new key exists
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "new_key"));
        IJWKManager.RSA_JWK memory result = jwkManager.getJWK(GOOGLE_ISSUER, "new_key");
        assertEq(result.n, "patched_modulus");
    }

    function test_SetPatches_UpsertOverridesObserved() public {
        // Add observed JWK
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = IJWKManager.RSA_JWK({ kid: "key1", kty: "RSA", alg: "RS256", e: "AQAB", n: "original_modulus" });
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        // Verify original value
        IJWKManager.RSA_JWK memory original = jwkManager.getJWK(GOOGLE_ISSUER, "key1");
        assertEq(original.n, "original_modulus");

        // Apply UpsertJWK patch to override
        IJWKManager.RSA_JWK memory patchedJwk =
            IJWKManager.RSA_JWK({ kid: "key1", kty: "RSA", alg: "RS256", e: "AQAB", n: "patched_modulus" });

        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](1);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.UpsertJWK, issuer: GOOGLE_ISSUER, kid: "", jwk: patchedJwk
        });

        vm.prank(governance);
        jwkManager.setPatches(patches);

        // Verify patched value
        IJWKManager.RSA_JWK memory result = jwkManager.getJWK(GOOGLE_ISSUER, "key1");
        assertEq(result.n, "patched_modulus");

        // But observed still has original
        IJWKManager.AllProvidersJWKs memory observed = jwkManager.getObservedJWKs();
        assertEq(observed.entries[0].jwks[0].n, "original_modulus");
    }

    function test_SetPatches_RevertWhenNotGovernance() public {
        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](0);

        vm.expectRevert();
        vm.prank(alice);
        jwkManager.setPatches(patches);
    }

    function test_SetPatches_ClearPatches() public {
        // Add JWK
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");
        _recordJWK(GOOGLE_ISSUER, 1, jwks, 1);

        // Apply RemoveAll patch
        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](1);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.RemoveAll,
            issuer: "",
            kid: "",
            jwk: IJWKManager.RSA_JWK("", "", "", "", "")
        });

        vm.prank(governance);
        jwkManager.setPatches(patches);
        assertEq(jwkManager.getProviderCount(), 0);

        // Clear patches (empty array)
        IJWKManager.Patch[] memory emptyPatches = new IJWKManager.Patch[](0);

        vm.prank(governance);
        jwkManager.setPatches(emptyPatches);

        // Observed JWKs should now be visible again
        assertEq(jwkManager.getProviderCount(), 1);
        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
    }

    function test_GetPatches() public {
        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](2);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.RemoveIssuer,
            issuer: GOOGLE_ISSUER,
            kid: "",
            jwk: IJWKManager.RSA_JWK("", "", "", "", "")
        });
        patches[1] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.UpsertJWK,
            issuer: APPLE_ISSUER,
            kid: "",
            jwk: _createSampleJWK("apple_key")
        });

        vm.prank(governance);
        jwkManager.setPatches(patches);

        IJWKManager.Patch[] memory result = jwkManager.getPatches();
        assertEq(result.length, 2);
        assertEq(uint8(result[0].patchType), uint8(IJWKManager.PatchType.RemoveIssuer));
        assertEq(uint8(result[1].patchType), uint8(IJWKManager.PatchType.UpsertJWK));
    }

    // ========================================================================
    // EVENT TESTS
    // ========================================================================

    function test_Events_ObservedJWKsUpdated() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](2);
        jwks[0] = _createSampleJWK("key1");
        jwks[1] = _createSampleJWK("key2");

        bytes memory payload = _createPayload(GOOGLE_ISSUER, 1, jwks);
        uint256 sourceId = uint256(keccak256(GOOGLE_ISSUER));

        vm.expectEmit(true, false, false, true);
        emit IJWKManager.ObservedJWKsUpdated(GOOGLE_ISSUER, 1, 2);

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, sourceId, 1, 0, payload, CALLBACK_GAS_LIMIT);
    }

    function test_Events_PatchesUpdated() public {
        IJWKManager.Patch[] memory patches = new IJWKManager.Patch[](1);
        patches[0] = IJWKManager.Patch({
            patchType: IJWKManager.PatchType.RemoveAll,
            issuer: "",
            kid: "",
            jwk: IJWKManager.RSA_JWK("", "", "", "", "")
        });

        vm.expectEmit(true, false, false, true);
        emit IJWKManager.PatchesUpdated(1);

        vm.prank(governance);
        jwkManager.setPatches(patches);
    }

    function test_Events_PatchedJWKsRegenerated() public {
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");

        bytes memory payload = _createPayload(GOOGLE_ISSUER, 1, jwks);
        uint256 sourceId = uint256(keccak256(GOOGLE_ISSUER));

        vm.expectEmit(true, false, false, true);
        emit IJWKManager.PatchedJWKsRegenerated(1);

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, sourceId, 1, 0, payload, CALLBACK_GAS_LIMIT);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_RecordJWKs(
        uint64 version,
        uint128 nonce
    ) public {
        vm.assume(version > 0);
        vm.assume(nonce > 0);

        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");

        _recordJWK(GOOGLE_ISSUER, version, jwks, nonce);

        assertTrue(jwkManager.hasJWK(GOOGLE_ISSUER, "key1"));
    }

    function testFuzz_VersionMustIncrease(
        uint64 version1,
        uint64 version2
    ) public {
        vm.assume(version1 > 0);
        vm.assume(version2 <= version1);

        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = _createSampleJWK("key1");

        // First record succeeds
        _recordJWK(GOOGLE_ISSUER, version1, jwks, 1);

        // Second with non-increasing version causes callback failure
        // JWKManager state should not change
        uint256 sourceId = uint256(keccak256(GOOGLE_ISSUER));
        bytes memory payload = _createPayload(GOOGLE_ISSUER, version2, jwks);

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_JWK, sourceId, 2, 0, payload, CALLBACK_GAS_LIMIT);

        // JWKManager still has the original version (callback failed)
        IJWKManager.ProviderJWKs memory provider = jwkManager.getProviderJWKs(GOOGLE_ISSUER);
        assertEq(provider.version, version1);
    }
}

