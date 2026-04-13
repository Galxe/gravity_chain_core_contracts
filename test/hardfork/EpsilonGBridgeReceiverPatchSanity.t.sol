// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { GBridgeReceiver } from "../../src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";

/// @title EpsilonGBridgeReceiverPatchSanity
/// @notice Verifies that `scripts/build_epsilon_bytecodes.sh` patches the right
///         immutable into the right offset.
///
///         The script assumes that — sorted by AST id ascending — the *lower*
///         immutable AST id corresponds to `trustedBridge` (declared first in
///         the source) and the *higher* corresponds to `trustedSourceId`.
///         The artifact's `immutableReferences` reports:
///           ast 59648 → offsets 84, 832
///           ast 59651 → offsets 153, 790
///         If the assumption is right, a freshly constructed receiver should
///         have `trustedBridge` baked at offset 84 and `trustedSourceId` baked
///         at offset 153.
contract EpsilonGBridgeReceiverPatchSanityTest is Test {
    address constant TESTNET_TRUSTED_BRIDGE = 0x79226649b3A20231e6b468a9E1AbBD23d3DFbbC6;
    uint256 constant TESTNET_TRUSTED_SOURCE_ID = 11155111;

    function test_immutableOffsets_matchPatchScriptAssumption() public {
        GBridgeReceiver fresh = new GBridgeReceiver(TESTNET_TRUSTED_BRIDGE, TESTNET_TRUSTED_SOURCE_ID);
        bytes memory code = address(fresh).code;

        // Sanity: getters agree with constructor args
        assertEq(fresh.trustedBridge(), TESTNET_TRUSTED_BRIDGE);
        assertEq(fresh.trustedSourceId(), TESTNET_TRUSTED_SOURCE_ID);

        // Read the 32-byte slot at offset 84 and check it's the bridge address (left-padded)
        bytes32 slotAt84;
        bytes32 slotAt153;
        bytes32 slotAt832;
        bytes32 slotAt790;
        assembly {
            // code points to length-prefixed bytes; data starts at code+0x20
            let dataPtr := add(code, 0x20)
            slotAt84 := mload(add(dataPtr, 84))
            slotAt153 := mload(add(dataPtr, 153))
            slotAt832 := mload(add(dataPtr, 832))
            slotAt790 := mload(add(dataPtr, 790))
        }

        bytes32 expectedBridge = bytes32(uint256(uint160(TESTNET_TRUSTED_BRIDGE)));
        bytes32 expectedSourceId = bytes32(TESTNET_TRUSTED_SOURCE_ID);

        assertEq(slotAt84, expectedBridge, "offset 84 should hold trustedBridge");
        assertEq(slotAt832, expectedBridge, "offset 832 should hold trustedBridge");
        assertEq(slotAt153, expectedSourceId, "offset 153 should hold trustedSourceId");
        assertEq(slotAt790, expectedSourceId, "offset 790 should hold trustedSourceId");
    }
}
