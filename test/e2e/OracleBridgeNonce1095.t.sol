// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "@src/oracle/evm/native_token_bridge/GBridgeSender.sol";
import { GBridgeReceiver } from "@src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";
import { IGBridgeReceiver } from "@src/oracle/evm/native_token_bridge/IGBridgeReceiver.sol";
import { NativeOracle } from "@src/oracle/NativeOracle.sol";
import { INativeOracle } from "@src/oracle/INativeOracle.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { MockGToken } from "@test/utils/MockGToken.sol";
import { MintCapture } from "@test/utils/MintCapture.sol";

/// @dev Local Portal/Sender/Oracle/Receiver integration. Native mint uses MintCapture,
///      and vm.prank simulates system delivery; this does not exercise the Rust client.
contract OracleBridgeNonce1095Test is Test {
    NativeOracle private oracle;
    GravityPortal private portal;
    GBridgeSender private sender;
    GBridgeReceiver private receiver;
    MockGToken private token;
    MintCapture private mint;
    address private constant USER = address(0xA002);
    address private constant ATTACKER = address(0xBAD);
    address private constant RECIPIENT = address(0xA003);
    uint256 private constant CHAIN = 1;

    function setUp() public {
        portal = new GravityPortal(address(this), 0.0001 ether, 1_250_000_000_000, address(this));
        token = new MockGToken();
        sender = new GBridgeSender(address(token), address(portal), address(this));
        receiver = new GBridgeReceiver(address(sender), CHAIN);
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(new MintCapture()).code);
        mint = MintCapture(SystemAddresses.NATIVE_MINT_PRECOMPILE);
        vm.etch(SystemAddresses.NATIVE_ORACLE, address(new NativeOracle()).code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
        vm.prank(SystemAddresses.GOVERNANCE);
        oracle.setDefaultCallback(0, address(receiver));
        token.mint(USER, 100 ether);
        vm.deal(USER, 1 ether);
        vm.deal(ATTACKER, 1 ether);
    }

    function _payload() private view returns (bytes memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(portal)) return abi.decode(logs[i].data, (bytes));
        }
        revert("missing Portal event");
    }

    function _publicMessage() private returns (bytes memory) {
        uint256 fee = portal.calculateFee(0);
        vm.recordLogs();
        vm.prank(ATTACKER);
        portal.send{ value: fee }("");
        return _payload();
    }

    function _deposit() private returns (bytes memory) {
        uint256 fee = sender.calculateBridgeFee(10 ether, RECIPIENT);
        vm.startPrank(USER);
        token.approve(address(sender), 10 ether);
        vm.recordLogs();
        sender.bridgeToGravity{ value: fee }(10 ether, RECIPIENT);
        vm.stopPrank();
        return _payload();
    }

    function _record(
        uint128 nonce,
        bytes memory payload
    ) private {
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.record(0, CHAIN, nonce, block.number, payload, 500_000);
    }

    function test_PublicSenderIsRejectedButNextDepositMints() public {
        bytes memory payload = _publicMessage();
        vm.expectEmit(true, true, false, true, address(oracle));
        emit INativeOracle.CallbackFailed(
            0,
            CHAIN,
            1,
            address(receiver),
            abi.encodeWithSelector(IGBridgeReceiver.InvalidSender.selector, ATTACKER, address(sender))
        );
        _record(1, payload);
        assertEq(oracle.getLatestNonce(0, CHAIN), 1);
        assertEq(mint.callCount(), 0);
        _record(2, _deposit());
        assertEq(oracle.getLatestNonce(0, CHAIN), 2);
        assertEq(mint.callCount(), 1);
        assertEq(mint.lastCall().recipient, RECIPIENT);
        assertEq(mint.lastCall().amount, 10 ether);
    }

    function test_MintFailureIsReportedAndNextDepositCanContinue() public {
        bytes memory payload = _deposit();
        mint.setShouldRevert(true);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit INativeOracle.CallbackFailed(
            0,
            CHAIN,
            1,
            address(receiver),
            abi.encodeWithSelector(IGBridgeReceiver.MintFailed.selector, RECIPIENT, 10 ether)
        );
        _record(1, payload);
        assertEq(oracle.getLatestNonce(0, CHAIN), 1);
        assertEq(mint.callCount(), 0);
        assertEq(token.balanceOf(address(sender)), 10 ether);
        mint.setShouldRevert(false);
        _record(2, _deposit());
        assertEq(oracle.getLatestNonce(0, CHAIN), 2);
        assertEq(mint.callCount(), 1);
        assertEq(token.balanceOf(address(sender)), 20 ether);
    }

    function test_MixedBatchKeepsDepositsBeforeAndAfterRejectedPublicMessage() public {
        uint128[] memory nonces = new uint128[](3);
        uint256[] memory positions = new uint256[](3);
        uint256[] memory gasLimits = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        payloads[0] = _deposit();
        payloads[1] = _publicMessage();
        payloads[2] = _deposit();
        for (uint256 i; i < 3; ++i) {
            nonces[i] = uint128(i + 1);
            positions[i] = block.number;
            gasLimits[i] = 500_000;
        }
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.recordBatch(0, CHAIN, nonces, positions, payloads, gasLimits);
        assertEq(oracle.getLatestNonce(0, CHAIN), 3);
        assertEq(mint.callCount(), 2);
        assertEq(token.balanceOf(address(sender)), 20 ether);
    }
}
