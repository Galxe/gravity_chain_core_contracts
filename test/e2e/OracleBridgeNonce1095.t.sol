// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { GBridgeSender } from "@src/oracle/evm/native_token_bridge/GBridgeSender.sol";
import { GBridgeReceiver } from "@src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";
import { IGBridgeReceiver } from "@src/oracle/evm/native_token_bridge/IGBridgeReceiver.sol";
import { INativeOracle } from "@src/oracle/INativeOracle.sol";
import { NativeOracle } from "@src/oracle/NativeOracle.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { Errors } from "@src/foundation/Errors.sol";
import { NotAllowed } from "@src/foundation/SystemAccessControl.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";
import { MockGToken } from "@test/utils/MockGToken.sol";
import { MintCapture } from "@test/utils/MintCapture.sol";

/// @notice Regression tests for Issue 1095 using real Portal events and a real NativeOracle/Receiver.
/// @dev SYSTEM_CALLER delivery simulates the consensus boundary; Rust/JWK networking and native
///      balance changes are not tested. MintCapture checks precompile invocation instead.
contract OracleBridgeNonce1095Test is Test {
    NativeOracle private oracle;
    GravityPortal private portal;
    GBridgeSender private sender;
    GBridgeReceiver private receiver;
    MockGToken private token;
    MintCapture private mint;
    address private owner = address(0xA001);
    address private user = address(0xA002);
    address private attacker = address(0xBAD);
    address private recipient = address(0xA003);
    uint256 private constant CHAIN = 1;

    function setUp() public {
        portal = new GravityPortal(owner, 0.0001 ether, 1_250_000_000_000, owner);
        token = new MockGToken();
        sender = new GBridgeSender(address(token), address(portal), owner);
        receiver = new GBridgeReceiver(address(sender), CHAIN);
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(new MintCapture()).code);
        mint = MintCapture(SystemAddresses.NATIVE_MINT_PRECOMPILE);
        token.mint(user, 100 ether);
        vm.deal(user, 1 ether);
        vm.deal(attacker, 1 ether);
        _installOracle(address(new NativeOracle()));
    }

    function _installOracle(
        address implementation
    ) private {
        vm.etch(SystemAddresses.NATIVE_ORACLE, implementation.code);
        oracle = NativeOracle(SystemAddresses.NATIVE_ORACLE);
        uint32[] memory types_ = new uint32[](1);
        address[] memory callbacks = new address[](1);
        callbacks[0] = address(receiver);
        vm.prank(SystemAddresses.GENESIS);
        oracle.initialize(types_, callbacks);
    }

    function _payload() private view returns (uint128 nonce, bytes memory payload) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(portal)
                    && logs[i].topics[0] == keccak256("MessageSent(uint128,uint256,bytes)")
            ) {
                return (uint128(uint256(logs[i].topics[1])), abi.decode(logs[i].data, (bytes)));
            }
        }
        revert("missing Portal event");
    }

    function _attack(
        bytes memory body
    ) private returns (uint128 nonce, bytes memory payload) {
        uint256 fee = portal.calculateFee(body.length);
        vm.recordLogs();
        vm.prank(attacker);
        portal.send{ value: fee }(body);
        return _payload();
    }

    function _deposit() private returns (uint128 nonce, bytes memory payload) {
        uint256 fee = sender.calculateBridgeFee(10 ether, recipient);
        vm.startPrank(user);
        token.approve(address(sender), 10 ether);
        vm.recordLogs();
        sender.bridgeToGravity{ value: fee }(10 ether, recipient);
        vm.stopPrank();
        return _payload();
    }

    function _batch(
        uint128[] memory nonces,
        bytes[] memory payloads
    ) private returns (bool ok, bytes memory reason) {
        uint256[] memory blocks = new uint256[](nonces.length);
        uint256[] memory gasLimits = new uint256[](nonces.length);
        for (uint256 i; i < nonces.length; ++i) {
            blocks[i] = block.number;
            gasLimits[i] = 500_000;
        }
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        return address(oracle).call{ gas: 30_000_000 }(
            abi.encodeCall(NativeOracle.recordBatch, (0, CHAIN, nonces, blocks, payloads, gasLimits))
        );
    }

    function _one(
        uint128 nonce,
        bytes memory payload
    ) private returns (bool ok, bytes memory reason) {
        uint128[] memory nonces = new uint128[](1);
        nonces[0] = nonce;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        return _batch(nonces, payloads);
    }

    function test_Control_LegitimateDepositMints() public {
        (uint128 nonce, bytes memory payload) = _deposit();
        (bool ok,) = _one(nonce, payload);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 1);
        assertEq(mint.callCount(), 1);
        MintCapture.Call memory call_ = mint.lastCall();
        assertEq(call_.recipient, recipient);
        assertEq(call_.amount, 10 ether);
    }

    function test_UntrustedEmptyMessageIsConsumedAndNextDepositMints() public {
        assertTrue(attacker != portal.owner());
        (uint128 badNonce, bytes memory badPayload) = _attack("");
        (address embeddedSender,,) = PortalMessage.decode(badPayload);
        assertEq(embeddedSender, attacker);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit INativeOracle.CallbackFailed(
            0,
            CHAIN,
            badNonce,
            address(receiver),
            abi.encodeWithSelector(IGBridgeReceiver.InvalidSender.selector, attacker, address(sender))
        );
        (bool ok,) = _one(badNonce, badPayload);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 1);
        assertEq(mint.callCount(), 0);

        // Consumed messages cannot be replayed.
        bytes memory reason;
        (ok, reason) = _one(badNonce, badPayload);
        assertFalse(ok);
        assertEq(
            reason, abi.encodeWithSelector(Errors.NonceNotSequential.selector, uint32(0), CHAIN, uint128(2), uint128(1))
        );

        (uint128 goodNonce, bytes memory goodPayload) = _deposit();
        assertEq(goodNonce, 2);
        (ok,) = _one(goodNonce, goodPayload);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 2);
        assertEq(token.balanceOf(address(sender)), 10 ether);
        assertEq(mint.callCount(), 1);
        assertEq(mint.lastCall().amount, 10 ether);
        assertEq(mint.lastCall().recipient, recipient);
    }

    function test_UntrustedBridgeShapedMessageDoesNotMint() public {
        (uint128 nonce, bytes memory payload) = _attack(abi.encode(uint256(999 ether), recipient));
        (bool ok,) = _one(nonce, payload);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 1);
        assertEq(mint.callCount(), 0);
    }

    function test_PayloadCannotOverridePortalAuthenticatedSender() public {
        bytes memory fakeHeader = PortalMessage.encode(address(sender), 999, abi.encode(uint256(999 ether), recipient));
        (uint128 nonce, bytes memory payload) = _attack(fakeHeader);
        (address embeddedSender,,) = PortalMessage.decode(payload);
        assertEq(embeddedSender, attacker);
        (bool ok,) = _one(nonce, payload);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 1);
        assertEq(mint.callCount(), 0);
    }

    function test_LegitimateDepositCannotBeMintedTwice() public {
        (uint128 nonce, bytes memory payload) = _deposit();
        (bool ok,) = _one(nonce, payload);
        assertTrue(ok);
        assertEq(mint.callCount(), 1);
        bytes memory reason;
        (ok, reason) = _one(nonce, payload);
        assertFalse(ok);
        assertEq(
            reason, abi.encodeWithSelector(Errors.NonceNotSequential.selector, uint32(0), CHAIN, uint128(2), uint128(1))
        );
        assertEq(mint.callCount(), 1);
        assertEq(oracle.getLatestNonce(0, CHAIN), 1);
    }

    function test_MixedBatchMintsDepositsBeforeAndAfterUntrustedMessage() public {
        uint128[] memory nonces = new uint128[](3);
        bytes[] memory payloads = new bytes[](3);
        (nonces[0], payloads[0]) = _deposit();
        (nonces[1], payloads[1]) = _attack("");
        (nonces[2], payloads[2]) = _deposit();
        (bool ok,) = _batch(nonces, payloads);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 3);
        assertEq(mint.callCount(), 2);
        assertEq(token.balanceOf(address(sender)), 20 ether);
        assertEq(mint.lastCall().amount, 10 ether);
        assertEq(mint.lastCall().recipient, recipient);
    }

    function test_MintFailureAdvancesBatchAndCanRetryOriginalDepositExactlyOnce() public {
        uint128[] memory nonces = new uint128[](2);
        bytes[] memory payloads = new bytes[](2);
        (nonces[0], payloads[0]) = _attack("");
        (nonces[1], payloads[1]) = _deposit();
        mint.setShouldRevert(true);
        (bool ok,) = _batch(nonces, payloads);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 2);
        assertEq(mint.callCount(), 0);
        assertEq(token.balanceOf(address(sender)), 10 ether);
        assertEq(oracle.getPendingCallback(0, CHAIN, 2).payloadHash, keccak256(payloads[1]));
        mint.setShouldRevert(false);
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        assertTrue(oracle.retryCallback(0, CHAIN, 2, payloads[1], 500_000));
        assertEq(oracle.getLatestNonce(0, CHAIN), 2);
        assertEq(mint.callCount(), 1);
        assertEq(oracle.getPendingCallback(0, CHAIN, 2).callback, address(0));
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleCallbackNotPending.selector, uint32(0), CHAIN, uint128(2)));
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.retryCallback(0, CHAIN, 2, payloads[1], 500_000);
        assertEq(mint.callCount(), 1);

        // An untrusted original sender stays rejected even through the privileged retry path.
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        assertFalse(oracle.retryCallback(0, CHAIN, 1, payloads[0], 500_000));
        assertEq(mint.callCount(), 1);
    }

    function test_UnauthorizedEOACannotRecordOrCallReceiver() public {
        (uint128 nonce, bytes memory payload) = _attack("");
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, attacker, SystemAddresses.SYSTEM_CALLER));
        vm.prank(attacker);
        oracle.record(0, CHAIN, nonce, block.number, payload, 500_000);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, attacker, SystemAddresses.NATIVE_ORACLE));
        vm.prank(attacker);
        receiver.onOracleEvent(0, CHAIN, nonce, payload);
        assertEq(oracle.getLatestNonce(0, CHAIN), 0);
        assertEq(mint.callCount(), 0);
    }

    function test_WrongSourceChainIsRejectedWithoutMintButDoesNotBlockIngestion() public {
        (uint128 nonce, bytes memory payload) = _deposit();
        uint256 wrongChain = 56;
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        oracle.record(0, wrongChain, nonce, block.number, payload, 500_000);
        assertEq(oracle.getLatestNonce(0, wrongChain), 1);
        assertEq(oracle.getPendingCallback(0, wrongChain, 1).callback, address(receiver));
        assertEq(mint.callCount(), 0);
    }

    function test_MixedBatchKeepsEarlierAndLaterMintsWhenMiddleDepositFails() public {
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(new SelectiveMintCapture()).code);
        address failedRecipient = address(0xBEEF);
        SelectiveMintCapture(SystemAddresses.NATIVE_MINT_PRECOMPILE).setFailedRecipient(failedRecipient);
        uint128[] memory nonces = new uint128[](3);
        bytes[] memory payloads = new bytes[](3);
        (nonces[0], payloads[0]) = _deposit();
        recipient = failedRecipient;
        (nonces[1], payloads[1]) = _deposit();
        recipient = address(0xA003);
        (nonces[2], payloads[2]) = _deposit();
        (bool ok,) = _batch(nonces, payloads);
        assertTrue(ok);
        assertEq(oracle.getLatestNonce(0, CHAIN), 3);
        assertEq(mint.callCount(), 2);
        assertEq(token.balanceOf(address(sender)), 30 ether);
        assertEq(oracle.getPendingCallback(0, CHAIN, 2).payloadHash, keccak256(payloads[1]));
        SelectiveMintCapture(SystemAddresses.NATIVE_MINT_PRECOMPILE).setFailedRecipient(address(0));
        vm.prank(SystemAddresses.SYSTEM_CALLER);
        assertTrue(oracle.retryCallback(0, CHAIN, 2, payloads[1], 500_000));
        assertEq(mint.callCount(), 3);
        assertEq(mint.lastCall().recipient, failedRecipient);
        assertEq(mint.lastCall().amount, 10 ether);
        assertEq(oracle.getLatestNonce(0, CHAIN), 3);
    }
}

/// @dev Same capture ABI as MintCapture, with a recipient-specific local failure.
contract SelectiveMintCapture {
    struct Call {
        uint8 op;
        address recipient;
        uint256 amount;
    }
    Call[] public calls;
    bool public shouldRevert;
    address public failedRecipient;

    function setFailedRecipient(
        address recipient_
    ) external {
        failedRecipient = recipient_;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function lastCall() external view returns (Call memory) {
        return calls[calls.length - 1];
    }

    fallback() external {
        require(msg.data.length == 53);
        address recipient_;
        uint256 amount;
        assembly {
            recipient_ := shr(96, calldataload(1))
            amount := calldataload(21)
        }
        require(recipient_ != failedRecipient, "selected mint failed");
        calls.push(Call(uint8(msg.data[0]), recipient_, amount));
    }
}
