// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { NativeOracle } from "../../../src/oracle/NativeOracle.sol";
import { INativeOracle } from "../../../src/oracle/INativeOracle.sol";
import { PolymarketSettlementResolver } from "../../../src/oracle/resolver/PolymarketSettlementResolver.sol";
import { SystemAddresses } from "../../../src/foundation/SystemAddresses.sol";
import { NotAllowed } from "../../../src/foundation/SystemAccessControl.sol";

contract PolymarketSettlementResolverTest is Test {
    NativeOracle public oracle;
    PolymarketSettlementResolver public resolver;

    address public systemCaller = SystemAddresses.SYSTEM_CALLER;
    address public governance = SystemAddresses.GOVERNANCE;
    address public alice = makeAddr("alice");

    uint32 public constant SOURCE_TYPE_POLYMARKET_SETTLEMENT = 6;
    uint256 public constant CALLBACK_GAS_LIMIT = 2_000_000;

    uint256 public constant DRAW_MARKET_ID = 1_897_398;
    uint256 public constant POLYGON_CHAIN_ID = 137;
    uint256 public constant SOURCE_BLOCK = 89_222_209;
    uint256 public constant LOG_INDEX = 2_077;

    address public constant CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address public constant UMA_ORACLE = 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296;

    bytes32 public constant DRAW_CONDITION_ID = 0x2afe86f96be81a0d89ed776bedbd52d1c75bc47b49e6f0f791ddd009f52faf23;
    bytes32 public constant DRAW_QUESTION_ID = 0x49a5e94a4b5a400dcd720ca1875fcd49ba55c303e43bf091bc175df72f74f501;
    bytes32 public constant DRAW_TX_HASH = 0x97828bf9110f78c07f1ad5cff5415875b67b3fe032e19ee6aa2317355861aab2;

    function setUp() public {
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);

        resolver = new PolymarketSettlementResolver();

        vm.startPrank(governance);
        oracle.setDefaultCallback(SOURCE_TYPE_POLYMARKET_SETTLEMENT, address(resolver));
        resolver.registerMirror(DRAW_MARKET_ID, POLYGON_CHAIN_ID, CTF, DRAW_CONDITION_ID, 2);
        vm.stopPrank();
    }

    function test_RecordsPolymarketDrawSettlementThroughNativeOracle() public {
        bytes memory payload = _drawPayload(DRAW_MARKET_ID, DRAW_CONDITION_ID);

        _record(DRAW_MARKET_ID, 1, SOURCE_BLOCK, payload);

        (
            bool exists,
            uint128 nonce,
            uint256 polygonChainId,
            address ctf,
            address oracleAddress,
            bytes32 questionId,
            uint256 outcomeSlotCount,
            bytes32 txHash,
            uint256 logIndex,
            uint8 settlementKind
        ) = resolver.getSettlement(DRAW_MARKET_ID, DRAW_CONDITION_ID);

        assertTrue(exists);
        assertEq(nonce, 1);
        assertEq(polygonChainId, POLYGON_CHAIN_ID);
        assertEq(ctf, CTF);
        assertEq(oracleAddress, UMA_ORACLE);
        assertEq(questionId, DRAW_QUESTION_ID);
        assertEq(outcomeSlotCount, 2);
        assertEq(txHash, DRAW_TX_HASH);
        assertEq(logIndex, LOG_INDEX);
        assertEq(settlementKind, resolver.SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION());

        uint256[] memory payouts = resolver.getPayoutNumerators(DRAW_MARKET_ID, DRAW_CONDITION_ID);
        assertEq(payouts.length, 2);
        assertEq(payouts[0], 1);
        assertEq(payouts[1], 0);

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_POLYMARKET_SETTLEMENT, DRAW_MARKET_ID, 1);
        assertEq(record.blockNumber, SOURCE_BLOCK);
        assertEq(record.data, payload);
    }

    function test_ReplayStoredSettlementAfterCallbackGasFailure() public {
        bytes memory payload = _drawPayload(DRAW_MARKET_ID, DRAW_CONDITION_ID);

        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_POLYMARKET_SETTLEMENT, DRAW_MARKET_ID, 1, SOURCE_BLOCK, payload, 1);
        (bool exists,,,,,,,,,) = resolver.getSettlement(DRAW_MARKET_ID, DRAW_CONDITION_ID);
        assertFalse(exists);
        assertTrue(resolver.isSettlementObserved(DRAW_MARKET_ID, DRAW_CONDITION_ID));

        resolver.replaySettlement(DRAW_MARKET_ID, 1);
        uint128 nonce;
        (exists, nonce,,,,,,,,) = resolver.getSettlement(DRAW_MARKET_ID, DRAW_CONDITION_ID);
        assertTrue(exists);
        assertEq(nonce, 1);
    }

    function test_RevertWhenRegisteringMirrorTwice() public {
        vm.expectRevert(
            abi.encodeWithSelector(PolymarketSettlementResolver.MirrorAlreadyRegistered.selector, DRAW_MARKET_ID)
        );
        vm.prank(governance);
        resolver.registerMirror(DRAW_MARKET_ID, POLYGON_CHAIN_ID, CTF, DRAW_CONDITION_ID, 2);
    }

    function test_SecondSettlementCannotOverwriteResolvedCondition() public {
        bytes memory payload = _drawPayload(DRAW_MARKET_ID, DRAW_CONDITION_ID);
        _record(DRAW_MARKET_ID, 1, SOURCE_BLOCK, payload);
        _record(DRAW_MARKET_ID, 2, SOURCE_BLOCK + 1, payload);

        (, uint128 nonce,,,,,,,,) = resolver.getSettlement(DRAW_MARKET_ID, DRAW_CONDITION_ID);
        assertEq(nonce, 1);
        assertEq(oracle.getRecord(SOURCE_TYPE_POLYMARKET_SETTLEMENT, DRAW_MARKET_ID, 2).data, payload);
    }

    function test_MismatchedConditionFailsCallbackButStoresRawPayload() public {
        bytes32 wrongCondition = keccak256("wrong-condition");
        bytes memory payload = _drawPayload(DRAW_MARKET_ID, wrongCondition);

        _record(DRAW_MARKET_ID, 1, SOURCE_BLOCK, payload);

        (bool exists,,,,,,,,,) = resolver.getSettlement(DRAW_MARKET_ID, DRAW_CONDITION_ID);
        assertFalse(exists);
        assertTrue(resolver.isSettlementObserved(DRAW_MARKET_ID, DRAW_CONDITION_ID));

        INativeOracle.DataRecord memory record = oracle.getRecord(SOURCE_TYPE_POLYMARKET_SETTLEMENT, DRAW_MARKET_ID, 1);
        assertEq(record.data, payload);
    }

    function test_RevertWhenCallbackCalledOutsideNativeOracle() public {
        bytes memory payload = _drawPayload(DRAW_MARKET_ID, DRAW_CONDITION_ID);

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, alice, SystemAddresses.NATIVE_ORACLE));
        vm.prank(alice);
        resolver.onOracleEvent(SOURCE_TYPE_POLYMARKET_SETTLEMENT, DRAW_MARKET_ID, 1, payload);
    }

    function test_RevertWhenRegisterMirrorOutsideGovernance() public {
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, alice, SystemAddresses.GOVERNANCE));
        vm.prank(alice);
        resolver.registerMirror(42, POLYGON_CHAIN_ID, CTF, keccak256("condition"), 2);
    }

    function _record(
        uint256 sourceId,
        uint128 nonce,
        uint256 blockNumber,
        bytes memory payload
    ) internal {
        vm.prank(systemCaller);
        oracle.record(SOURCE_TYPE_POLYMARKET_SETTLEMENT, sourceId, nonce, blockNumber, payload, CALLBACK_GAS_LIMIT);
    }

    function _drawPayload(
        uint256 mirrorId,
        bytes32 conditionId
    ) internal view returns (bytes memory) {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        return abi.encode(
            PolymarketSettlementResolver.PolymarketSettlementPayload({
                mirrorId: mirrorId,
                polygonChainId: POLYGON_CHAIN_ID,
                ctf: CTF,
                oracle: UMA_ORACLE,
                conditionId: conditionId,
                questionId: DRAW_QUESTION_ID,
                outcomeSlotCount: 2,
                payoutNumerators: payouts,
                txHash: DRAW_TX_HASH,
                logIndex: LOG_INDEX,
                settlementKind: resolver.SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION()
            })
        );
    }
}
