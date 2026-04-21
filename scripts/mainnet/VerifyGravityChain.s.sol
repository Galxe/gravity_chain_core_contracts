// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { SystemAddresses } from "src/foundation/SystemAddresses.sol";
import { GBridgeReceiver } from "src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";

/// @title VerifyGravityChain
/// @notice Read-only verifier that runs against a Gravity RPC and checks:
///
///           (1) every system contract at its hard-coded 0x1625F… address has
///               runtime bytecode byte-for-byte identical to what we build
///               locally (metadata suffix stripped before comparison);
///
///           (2) GBridgeReceiver on Gravity (address supplied via env) matches
///               its local build AND has the expected immutables wired:
///                     trustedBridge   == <GBridgeSender on Ethereum>
///                     trustedSourceId == 1 (Ethereum mainnet chainId).
///
/// @dev Run with:
///        forge script scripts/mainnet/VerifyGravityChain.s.sol:VerifyGravityChain \
///             --rpc-url $GRAVITY_RPC_URL
///      (no --broadcast; the script only reads, and uses a local-simulated
///       `new` for the "deploy-with-same-args-and-diff-the-runtime-code"
///       trick on GBridgeReceiver.)
contract VerifyGravityChain is Script {
    struct Entry {
        address addr;
        string artifact; // "File.sol:Contract"
        bool expectCode; // false => must have 0 code (caller-only / precompile)
        bool precompile; // precompiles (0x1625F5xxx) live in grevm, not Solidity — skip bytecode compare
    }

    uint256 internal failCount;
    uint256 internal passCount;

    // ========================================================================
    // ENTRY
    // ========================================================================

    function run() external {
        console.log("=========================================================");
        console.log("       Gravity Chain - System Contract Verifier          ");
        console.log("=========================================================");
        console.log("chainId :", block.chainid);
        console.log("");

        _verifySystemContracts();
        _verifyBridgeReceiver();

        console.log("");
        console.log("=========================================================");
        console.log("  PASS :", passCount);
        console.log("  FAIL :", failCount);
        console.log("=========================================================");
        require(failCount == 0, "VerifyGravityChain: one or more checks FAILED");
    }

    // ========================================================================
    // (1) SYSTEM CONTRACTS AT 0x1625F… ADDRESSES
    // ========================================================================

    function _verifySystemContracts() internal {
        Entry[] memory entries = _systemEntries();
        console.log("-- system contracts (%d entries) --", entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            _verifyOne(entries[i]);
        }
    }

    function _verifyOne(Entry memory e) internal {
        bytes memory onchain = e.addr.code;

        // Special cases: no code expected (caller EOA, for example).
        if (!e.expectCode) {
            if (onchain.length == 0) {
                _pass(e.addr, e.artifact, "no-code OK");
            } else {
                _fail(e.addr, e.artifact, "expected empty code but found bytecode");
            }
            return;
        }

        if (onchain.length == 0) {
            _fail(e.addr, e.artifact, "MISSING on-chain code");
            return;
        }

        // Precompiles are implemented in grevm, not in Solidity. We can only
        // assert presence of *some* code and surface it for a human reviewer.
        if (e.precompile) {
            _pass(e.addr, e.artifact, string.concat("precompile present, len=", vm.toString(onchain.length)));
            return;
        }

        bytes memory localCode = vm.getDeployedCode(e.artifact);
        if (keccak256(localCode) == keccak256(onchain)) {
            _pass(e.addr, e.artifact, "strict match");
            return;
        }
        bytes memory localStripped = _stripMetadata(localCode);
        bytes memory onchainStripped = _stripMetadata(onchain);
        if (keccak256(localStripped) == keccak256(onchainStripped)) {
            _pass(e.addr, e.artifact, "semantic match (metadata differs)");
            return;
        }
        console.log(
            "   LOCAL   keccak256:", vm.toString(keccak256(localCode)), "len:", vm.toString(localCode.length)
        );
        console.log(
            "   ONCHAIN keccak256:", vm.toString(keccak256(onchain)), "len:", vm.toString(onchain.length)
        );
        _fail(e.addr, e.artifact, "bytecode mismatch");
    }

    // ========================================================================
    // (2) GBRIDGE RECEIVER  (cross-chain sanity)
    // ========================================================================

    function _verifyBridgeReceiver() internal {
        address receiverAddr = _envAddressOr("GBRIDGE_RECEIVER_ADDRESS", address(0));
        address expectedBridge = _envAddressOr("GBRIDGE_SENDER_ADDRESS", address(0));
        uint256 expectedSourceId = _envUintOr("TRUSTED_SOURCE_CHAIN_ID", 1);

        console.log("");
        console.log("-- GBridgeReceiver --");

        if (receiverAddr == address(0)) {
            console.log("   GBRIDGE_RECEIVER_ADDRESS not set: skipping (ok if Gravity genesis not live yet)");
            return;
        }
        if (expectedBridge == address(0)) {
            // Try the deploy artifact.
            try vm.readFile("./deployments/mainnet.json") returns (string memory json) {
                expectedBridge = abi.decode(vm.parseJson(json, ".gBridgeSender"), (address));
            } catch {
                _fail(receiverAddr, "GBridgeReceiver", "GBRIDGE_SENDER_ADDRESS unset and deployments/mainnet.json missing");
                return;
            }
        }
        require(expectedBridge != address(0), "expectedBridge unresolved");
        require(receiverAddr.code.length > 0, "GBridgeReceiver has no code");

        // --- state / immutables ---
        GBridgeReceiver receiver = GBridgeReceiver(receiverAddr);
        address gotBridge = receiver.trustedBridge();
        uint256 gotSourceId = receiver.trustedSourceId();

        if (gotBridge != expectedBridge) {
            console.log("   trustedBridge   : got   ", gotBridge);
            console.log("                     wanted", expectedBridge);
            _fail(receiverAddr, "GBridgeReceiver", "trustedBridge mismatch (Gravity side does NOT trust our Ethereum-side GBridgeSender)");
        } else {
            _pass(receiverAddr, "GBridgeReceiver.trustedBridge", "matches Ethereum GBridgeSender");
        }

        if (gotSourceId != expectedSourceId) {
            console.log("   trustedSourceId : got   ", gotSourceId);
            console.log("                     wanted", expectedSourceId);
            _fail(receiverAddr, "GBridgeReceiver", "trustedSourceId mismatch");
        } else {
            _pass(receiverAddr, "GBridgeReceiver.trustedSourceId", "matches expected chainId");
        }

        // --- bytecode: deploy locally with same immutables, compare ---
        GBridgeReceiver local = new GBridgeReceiver(expectedBridge, expectedSourceId);
        bytes memory localCode = address(local).code;
        bytes memory onchain = receiverAddr.code;
        if (keccak256(localCode) == keccak256(onchain)) {
            _pass(receiverAddr, "GBridgeReceiver (bytecode)", "strict match");
        } else if (keccak256(_stripMetadata(localCode)) == keccak256(_stripMetadata(onchain))) {
            _pass(receiverAddr, "GBridgeReceiver (bytecode)", "semantic match (metadata differs)");
        } else {
            console.log(
                "   LOCAL   keccak256:", vm.toString(keccak256(localCode)), "len:", vm.toString(localCode.length)
            );
            console.log(
                "   ONCHAIN keccak256:", vm.toString(keccak256(onchain)), "len:", vm.toString(onchain.length)
            );
            _fail(receiverAddr, "GBridgeReceiver (bytecode)", "bytecode mismatch");
        }
    }

    // ========================================================================
    // SYSTEM ADDRESS → ARTIFACT MAP
    // ========================================================================

    function _systemEntries() internal pure returns (Entry[] memory list) {
        list = new Entry[](25);
        uint256 i;

        // --- 0x1625F0xxx: consensus engine ---
        list[i++] = Entry({
            addr: SystemAddresses.SYSTEM_CALLER,
            artifact: "SYSTEM_CALLER (no contract, caller role)",
            expectCode: false,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.GENESIS,
            artifact: "Genesis.sol:Genesis",
            expectCode: true,
            precompile: false
        });

        // --- 0x1625F1xxx: runtime configs ---
        list[i++] = Entry({
            addr: SystemAddresses.TIMESTAMP,
            artifact: "Timestamp.sol:Timestamp",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.STAKE_CONFIG,
            artifact: "StakingConfig.sol:StakingConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.VALIDATOR_CONFIG,
            artifact: "ValidatorConfig.sol:ValidatorConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.RANDOMNESS_CONFIG,
            artifact: "RandomnessConfig.sol:RandomnessConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.GOVERNANCE_CONFIG,
            artifact: "GovernanceConfig.sol:GovernanceConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.EPOCH_CONFIG,
            artifact: "EpochConfig.sol:EpochConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.VERSION_CONFIG,
            artifact: "VersionConfig.sol:VersionConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.CONSENSUS_CONFIG,
            artifact: "ConsensusConfig.sol:ConsensusConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.EXECUTION_CONFIG,
            artifact: "ExecutionConfig.sol:ExecutionConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.ORACLE_TASK_CONFIG,
            artifact: "OracleTaskConfig.sol:OracleTaskConfig",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.ON_DEMAND_ORACLE_TASK_CONFIG,
            artifact: "OnDemandOracleTaskConfig.sol:OnDemandOracleTaskConfig",
            expectCode: true,
            precompile: false
        });

        // --- 0x1625F2xxx: staking & validator ---
        list[i++] = Entry({
            addr: SystemAddresses.STAKING,
            artifact: "Staking.sol:Staking",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.VALIDATOR_MANAGER,
            artifact: "ValidatorManagement.sol:ValidatorManagement",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.DKG,
            artifact: "DKG.sol:DKG",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.RECONFIGURATION,
            artifact: "Reconfiguration.sol:Reconfiguration",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.BLOCK,
            artifact: "Blocker.sol:Blocker",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.PERFORMANCE_TRACKER,
            artifact: "ValidatorPerformanceTracker.sol:ValidatorPerformanceTracker",
            expectCode: true,
            precompile: false
        });

        // --- 0x1625F3xxx: governance ---
        list[i++] = Entry({
            addr: SystemAddresses.GOVERNANCE,
            artifact: "Governance.sol:Governance",
            expectCode: true,
            precompile: false
        });

        // --- 0x1625F4xxx: oracle ---
        list[i++] = Entry({
            addr: SystemAddresses.NATIVE_ORACLE,
            artifact: "NativeOracle.sol:NativeOracle",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.JWK_MANAGER,
            artifact: "JWKManager.sol:JWKManager",
            expectCode: true,
            precompile: false
        });
        list[i++] = Entry({
            addr: SystemAddresses.ORACLE_REQUEST_QUEUE,
            artifact: "OracleRequestQueue.sol:OracleRequestQueue",
            expectCode: true,
            precompile: false
        });

        // --- 0x1625F5xxx: precompiles (implemented in grevm) ---
        list[i++] = Entry({
            addr: SystemAddresses.NATIVE_MINT_PRECOMPILE,
            artifact: "NATIVE_MINT_PRECOMPILE (grevm native)",
            expectCode: true,
            precompile: true
        });
        list[i++] = Entry({
            addr: SystemAddresses.BLS_POP_VERIFY_PRECOMPILE,
            artifact: "BLS_POP_VERIFY_PRECOMPILE (grevm native)",
            expectCode: true,
            precompile: true
        });
    }

    // ========================================================================
    // BYTECODE HELPERS
    // ========================================================================

    function _stripMetadata(bytes memory code) internal pure returns (bytes memory) {
        if (code.length < 2) return code;
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        uint256 suffix = metaLen + 2;
        if (suffix >= code.length) return code;
        uint256 newLen = code.length - suffix;
        bytes memory out = new bytes(newLen);
        for (uint256 i = 0; i < newLen; i++) {
            out[i] = code[i];
        }
        return out;
    }

    // ========================================================================
    // OUTPUT HELPERS
    // ========================================================================

    function _pass(address a, string memory label, string memory note) internal {
        passCount++;
        console.log("  [PASS]", a, label, note);
    }

    function _fail(address a, string memory label, string memory note) internal {
        failCount++;
        console.log("  [FAIL]", a, label, note);
    }

    function _envAddressOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallback_;
        }
    }

    function _envUintOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallback_;
        }
    }
}
