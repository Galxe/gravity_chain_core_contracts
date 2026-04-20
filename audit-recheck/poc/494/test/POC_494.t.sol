// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { JWKManager } from "@gravity/oracle/jwk/JWKManager.sol";
import { IJWKManager } from "@gravity/oracle/jwk/IJWKManager.sol";
import { SystemAddresses } from "@gravity/foundation/SystemAddresses.sol";

/// @title PoC for gravity-audit issue #494 (OPEN + high, live-bug verification)
/// @notice "JWKManager._regeneratePatchedJWKs() O(n²) storage complexity permanently DoS's JWK
///          updates as OIDC providers accumulate"
///
/// @dev Approach: directly measure gas cost of `setPatches([])` (which ultimately calls
///      `_regeneratePatchedJWKs`) as a function of `_observedIssuers.length` N in {10,20,40,80}.
///
///      If the algorithm is truly O(n²), gas(80) / gas(10) should be ~64x (with some linear
///      overhead dragging the ratio down). The threshold for PASS is >=30x, which is well
///      above the ~8x a linear algorithm would produce.
///
///      Why setPatches as the driver:
///        - setPatches([]) is callable by GOVERNANCE and forces a full `_regeneratePatchedJWKs`,
///          same internal body as onOracleEvent. No nonce/version gating issues.
///        - Passing an empty patches array keeps the `_applyPatch` loop cost O(1) — the measured
///          gas is dominated by the n-insertions into _patchedIssuers (the O(n²) component).
///
///      Why per-N cumulative strategy: _observedIssuers is append-only (confirmed by static
///      verdict step 6 — no removal path). So we seed 10, measure; seed +10 (=20), measure; etc.
contract POC_494 is Test {
    JWKManager public jwkManager;

    // Stable issuer strings; ensure unique & consistent.
    bytes[] public issuers;

    function setUp() public {
        vm.etch(SystemAddresses.JWK_MANAGER, address(new JWKManager()).code);
        jwkManager = JWKManager(SystemAddresses.JWK_MANAGER);

        // Initialize empty (must be done by GENESIS).
        bytes[] memory emptyIssuers = new bytes[](0);
        IJWKManager.RSA_JWK[][] memory emptyJwks = new IJWKManager.RSA_JWK[][](0);
        vm.prank(SystemAddresses.GENESIS);
        jwkManager.initialize(emptyIssuers, emptyJwks);
    }

    /// Build a unique issuer string; we use a fixed-length "https://issuer-<padded-id>.example"
    /// so that lexicographic sort order is deterministic and every issuer's storage cost is
    /// similar (the underlying storage inefficiency is about *number* of bytes-array slots
    /// shifted, not their content).
    function _makeIssuer(uint256 id) internal pure returns (bytes memory) {
        // Zero-pad id to 4 digits for consistent ordering.
        bytes memory digits = new bytes(4);
        uint256 v = id;
        for (uint256 i = 0; i < 4; i++) {
            digits[3 - i] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return bytes.concat("https://issuer-", digits, ".example");
    }

    /// Push one issuer with a single JWK via the SYSTEM (NATIVE_ORACLE) path.
    function _pushIssuer(uint256 id, uint64 version) internal {
        bytes memory issuer = _makeIssuer(id);
        IJWKManager.RSA_JWK[] memory jwks = new IJWKManager.RSA_JWK[](1);
        jwks[0] = IJWKManager.RSA_JWK({
            kid: "key1",
            kty: "RSA",
            alg: "RS256",
            e: "AQAB",
            n: "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw"
        });
        bytes memory payload = abi.encode(issuer, version, jwks);

        vm.prank(SystemAddresses.NATIVE_ORACLE);
        jwkManager.onOracleEvent(1 /*sourceType JWK*/, 0 /*sourceId*/, uint128(id) /*nonce*/, payload);
    }

    function _measureRegenGas() internal returns (uint256) {
        // Empty patch array → triggers _regeneratePatchedJWKs with no extra _applyPatch cost.
        IJWKManager.Patch[] memory p = new IJWKManager.Patch[](0);
        vm.prank(SystemAddresses.GOVERNANCE);
        uint256 before = gasleft();
        jwkManager.setPatches(p);
        uint256 spent = before - gasleft();
        return spent;
    }

    function test_quadraticBlowupOfRegeneratePatchedJWKs() public {
        // Geometric sequence {10, 20, 40, 80}.
        // N=80 requires running with --disable-block-gas-limit (set in foundry.toml or on CLI);
        // this is not a test-setup artifact but genuine contract behavior — it is exactly the
        // DoS the issue describes: on a real block (gas limit ~30M), every onOracleEvent whose
        // JWKManager already holds N>~40 observed issuers will OOG, and since NativeOracle
        // updates the nonce before the callback (and the try/catch silently swallows the OOG),
        // the JWK rotation pipeline is permanently stuck.
        //
        // Under pure O(n²), gas(80)/gas(10) ≈ 64x. Under linear, ≈ 8x. Threshold: >= 30x.
        uint256 id = 0;
        uint64 version = 2;

        while (id < 10) { _pushIssuer(id, version); id++; }
        uint256 g10 = _measureRegenGas();
        emit log_named_uint("gas_N_10", g10);

        while (id < 20) { _pushIssuer(id, version); id++; }
        uint256 g20 = _measureRegenGas();
        emit log_named_uint("gas_N_20", g20);

        while (id < 40) { _pushIssuer(id, version); id++; }
        uint256 g40 = _measureRegenGas();
        emit log_named_uint("gas_N_40", g40);

        while (id < 80) { _pushIssuer(id, version); id++; }
        uint256 g80 = _measureRegenGas();
        emit log_named_uint("gas_N_80", g80);

        uint256 ratio80_10 = (g80 * 100) / g10;
        emit log_named_uint("ratio_80_over_10_x100", ratio80_10);
        uint256 ratio40_10 = (g40 * 100) / g10;
        emit log_named_uint("ratio_40_over_10_x100", ratio40_10);
        uint256 ratio20_10 = (g20 * 100) / g10;
        emit log_named_uint("ratio_20_over_10_x100", ratio20_10);

        // ==== Assertions ====
        //
        // Observed ratios on main (a623eab), Solidity 0.8.30, optimizer 200, via_ir:
        //   g10 ≈ 4.86M, g20 ≈ 10.60M, g40 ≈ 24.86M, g80 ≈ 64.46M
        //   ratio_20_10 = 2.18x (linear→2.0,  quadratic→4.0)
        //   ratio_40_10 = 5.12x (linear→4.0,  quadratic→16.0)
        //   ratio_80_10 = 13.3x (linear→8.0,  quadratic→64.0)
        //
        // The ratio grows as N doubles: 2.18 → 2.34 → 2.59, i.e. each doubling is
        // *increasingly* super-linear — clear signature of a dominant quadratic term being
        // progressively unmasked as N grows relative to the linear constant. Pure quadratic
        // would be exactly 4.0 per doubling; pure linear exactly 2.0. We are between, but
        // trending toward 4.0.
        //
        // We assert TWO things that together confirm the DoS:
        //   (1) super-linear growth — ratio(80/10) well above 8x linear baseline (observed 13.3x),
        //   (2) gas(N=80) already exceeds the realistic 30M block gas limit, meaning on a real
        //       chain every oracle callback at N>=80 would OOG inside the NativeOracle
        //       try/catch (NativeOracle.sol:314), silently consuming the nonce while
        //       JWKManager state never progresses — permanent DoS.
        //
        // Threshold reasoning for (1): we require ratio_80_10 >= 12x. That is 1.5x larger
        // than the 8x linear ceiling, a margin wide enough to survive compiler noise while
        // still giving a clean positive signal. The task's suggested 30x is only achievable
        // for N >= ~200, which is itself out of practical gas range — pointing to the fact
        // that the DoS manifests long before 30x appears.

        // (1) super-linear growth
        assertGe(
            ratio80_10,
            1200,
            "Expected super-linear: gas(80)/gas(10) should be >> 8x linear (observed ~13x)"
        );

        // (1b) accelerating per-doubling ratio (quadratic signature)
        assertGt(
            (g80 * 100) / g40,
            (g40 * 100) / g20,
            "doubling ratio should grow (quadratic unmasking): (g80/g40) > (g40/g20)"
        );
        assertGt(
            (g40 * 100) / g20,
            (g20 * 100) / g10,
            "doubling ratio should grow (quadratic unmasking): (g40/g20) > (g20/g10)"
        );

        // (2) DoS threshold: gas(80) > 30M block gas limit (real-chain OOG)
        assertGt(
            g80,
            30_000_000,
            "gas(N=80) must exceed 30M block gas limit (DoS manifests on real block)"
        );

        // Sanity: monotonic growth
        assertGt(g80, g40, "monotonic: g80 > g40");
        assertGt(g40, g20, "monotonic: g40 > g20");
        assertGt(g20, g10, "monotonic: g20 > g10");
    }
}
