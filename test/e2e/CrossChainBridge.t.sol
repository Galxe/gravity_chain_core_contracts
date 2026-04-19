// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { GravityPortal } from "@src/oracle/evm/GravityPortal.sol";
import { IGravityPortal } from "@src/oracle/evm/IGravityPortal.sol";
import { GBridgeSender } from "@src/oracle/evm/native_token_bridge/GBridgeSender.sol";
import { IGBridgeSender } from "@src/oracle/evm/native_token_bridge/IGBridgeSender.sol";
import { GBridgeReceiver } from "@src/oracle/evm/native_token_bridge/GBridgeReceiver.sol";
import { IGBridgeReceiver } from "@src/oracle/evm/native_token_bridge/IGBridgeReceiver.sol";
import { PortalMessage } from "@src/oracle/evm/PortalMessage.sol";
import { SystemAddresses } from "@src/foundation/SystemAddresses.sol";
import { NotAllowed } from "@src/foundation/SystemAccessControl.sol";
import { Errors } from "@src/foundation/Errors.sol";
import { MockGToken } from "@test/utils/MockGToken.sol";
import { MintCapture } from "@test/utils/MintCapture.sol";

/// @title CrossChainBridgeE2E
/// @notice End-to-end cross-chain tests that exercise the real Sender → Portal
///         → (oracle capture) → Receiver → NativeMint flow in a single EVM.
/// @dev    We deploy all three production contracts exactly as they will be
///         deployed in prod, then simulate the consensus engine's oracle
///         capture by recording Portal's MessageSent event and replaying the
///         payload into the Receiver via vm.prank(NATIVE_ORACLE).
///
///         This catches regressions that pure per-contract unit tests miss —
///         namely that Sender + Portal + Receiver agree on the payload layout,
///         the nonce semantics, and the trust boundary (sender / sourceId).
contract CrossChainBridgeE2E is Test {
    // ---- Ethereum side ----
    MockGToken internal gToken;
    GravityPortal internal portal;
    GBridgeSender internal sender;

    // ---- Gravity side ----
    GBridgeReceiver internal receiver;
    MintCapture internal mintCapture;

    address internal owner;
    address internal feeRecipient;
    address internal alice;
    uint256 internal alicePk;
    address internal bob;
    address internal charlie;

    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint32 internal constant SOURCE_TYPE_BLOCKCHAIN = 0;

    uint256 internal constant BASE_FEE = 0.0001 ether;
    uint256 internal constant FEE_PER_BYTE = 1_250_000_000_000; // matches mainnet default

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        alicePk = 0xA11CE;
        alice = vm.addr(alicePk);
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // --- Ethereum side ---
        gToken = new MockGToken();
        portal = new GravityPortal(owner, BASE_FEE, FEE_PER_BYTE, feeRecipient);
        sender = new GBridgeSender(address(gToken), address(portal), owner);

        gToken.mint(alice, INITIAL_BALANCE);
        vm.deal(alice, 100 ether);

        // --- Gravity side ---
        receiver = new GBridgeReceiver(address(sender), ETHEREUM_CHAIN_ID);

        // Etch MintCapture at NATIVE_MINT_PRECOMPILE so the receiver's low-level
        // call lands somewhere we can introspect.
        MintCapture impl = new MintCapture();
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(impl).code);
        mintCapture = MintCapture(SystemAddresses.NATIVE_MINT_PRECOMPILE);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /// @dev Extract the payload bytes from the last Portal.MessageSent event
    ///      recorded since the most recent vm.recordLogs() call.
    function _capturePayload() internal returns (uint128 messageNonce, uint256 blockNumber, bytes memory payload) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("MessageSent(uint128,uint256,bytes)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter != address(portal)) continue;
            if (l.topics.length == 0 || l.topics[0] != sig) continue;
            messageNonce = uint128(uint256(l.topics[1]));
            blockNumber = uint256(l.topics[2]);
            payload = abi.decode(l.data, (bytes));
            return (messageNonce, blockNumber, payload);
        }
        revert("MessageSent not emitted");
    }

    /// @dev Bridge `amount` to `recipient` from Alice, paying the exact fee.
    function _bridge(uint256 amount, address recipient) internal returns (uint128 portalNonce, bytes memory payload) {
        uint256 fee = sender.calculateBridgeFee(amount, recipient);
        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.recordLogs();
        sender.bridgeToGravity{ value: fee }(amount, recipient);
        vm.stopPrank();
        (portalNonce,, payload) = _capturePayload();
    }

    /// @dev Deliver a captured payload to the receiver as if it were the oracle.
    function _deliver(uint128 oracleNonce, uint256 sourceId, bytes memory payload) internal {
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, sourceId, oracleNonce, payload);
    }

    // ========================================================================
    // HAPPY PATH
    // ========================================================================

    /// @notice A single bridge: lock on Ethereum → mint on Gravity.
    function test_E2E_HappyPath_SingleBridge() public {
        uint256 amount = 100 ether;
        uint256 fee = sender.calculateBridgeFee(amount, bob);

        // ---- Ethereum side ----
        uint256 aliceBalBefore = gToken.balanceOf(alice);
        uint256 portalEthBefore = address(portal).balance;

        (uint128 portalNonce, bytes memory payload) = _bridge(amount, bob);

        assertEq(portalNonce, 1, "first portal nonce must be 1");
        assertEq(portal.nonce(), 1, "portal nonce advanced");
        assertEq(gToken.balanceOf(alice), aliceBalBefore - amount, "alice debited");
        assertEq(gToken.balanceOf(address(sender)), amount, "sender locked tokens");
        assertEq(address(portal).balance, portalEthBefore + fee, "portal collected fee");

        // Decode the payload and assert it mirrors what we broadcast.
        (address decodedSender, uint128 decodedNonce, bytes memory msgBody) = PortalMessage.decode(payload);
        assertEq(decodedSender, address(sender), "payload sender");
        assertEq(decodedNonce, portalNonce, "payload nonce");

        (uint256 msgAmount, address msgRecipient) = abi.decode(msgBody, (uint256, address));
        assertEq(msgAmount, amount, "payload amount");
        assertEq(msgRecipient, bob, "payload recipient");

        // ---- Gravity side ----
        vm.expectEmit(true, true, true, true, address(receiver));
        emit IGBridgeReceiver.NativeMinted(bob, amount, portalNonce);
        _deliver({ oracleNonce: 1, sourceId: ETHEREUM_CHAIN_ID, payload: payload });

        assertEq(mintCapture.callCount(), 1, "precompile called once");
        MintCapture.Call memory c = mintCapture.lastCall();
        assertEq(c.op, 0x01, "op byte");
        assertEq(c.recipient, bob, "mint recipient");
        assertEq(c.amount, amount, "mint amount");
    }

    /// @notice Three sequential bridges must produce three sequential nonces,
    ///         be locked correctly, and mint three separate times on Gravity.
    function test_E2E_HappyPath_SequentialBridges() public {
        uint256[3] memory amounts = [uint256(10 ether), 20 ether, 30 ether];
        address[3] memory recipients = [bob, charlie, bob];

        bytes[] memory payloads = new bytes[](3);
        uint128[] memory nonces = new uint128[](3);

        for (uint256 i = 0; i < 3; i++) {
            (uint128 n, bytes memory p) = _bridge(amounts[i], recipients[i]);
            nonces[i] = n;
            payloads[i] = p;
            assertEq(n, uint128(i + 1), "portal nonces must be strictly sequential");
        }

        assertEq(gToken.balanceOf(address(sender)), amounts[0] + amounts[1] + amounts[2], "total locked");
        assertEq(portal.nonce(), 3, "portal nonce");

        // Oracle delivers each payload. Oracle nonce is independent of portal nonce;
        // we just feed a monotonic value.
        for (uint256 i = 0; i < 3; i++) {
            _deliver({ oracleNonce: uint128(1000 + i), sourceId: ETHEREUM_CHAIN_ID, payload: payloads[i] });
        }

        assertEq(mintCapture.callCount(), 3, "precompile called three times");
        MintCapture.Call memory last = mintCapture.lastCall();
        assertEq(last.recipient, recipients[2]);
        assertEq(last.amount, amounts[2]);
    }

    /// @notice Bridge via permit: no prior approve() tx, signed permit inside the bridge call.
    function test_E2E_HappyPath_BridgeWithPermit() public {
        uint256 amount = 50 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 fee = sender.calculateBridgeFee(amount, bob);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                gToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        alice,
                        address(sender),
                        amount,
                        gToken.nonces(alice),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.recordLogs();
        vm.prank(alice);
        sender.bridgeToGravityWithPermit{ value: fee }(amount, bob, deadline, v, r, s);
        (uint128 portalNonce,, bytes memory payload) = _capturePayload();

        _deliver({ oracleNonce: 1, sourceId: ETHEREUM_CHAIN_ID, payload: payload });

        assertEq(portalNonce, 1);
        assertEq(gToken.balanceOf(address(sender)), amount);
        MintCapture.Call memory c = mintCapture.lastCall();
        assertEq(c.recipient, bob);
        assertEq(c.amount, amount);
    }

    /// @notice Portal fees accumulate across many bridges, and the owner can
    ///         withdraw them to the configured fee recipient.
    function test_E2E_FeeCollection_AndWithdraw() public {
        _bridge(10 ether, bob);
        _bridge(20 ether, bob);
        _bridge(30 ether, bob);

        uint256 portalBal = address(portal).balance;
        assertGt(portalBal, 0, "portal accumulates fees");
        assertEq(feeRecipient.balance, 0, "feeRecipient starts empty");

        vm.prank(owner);
        portal.withdrawFees();

        assertEq(address(portal).balance, 0, "portal drained");
        assertEq(feeRecipient.balance, portalBal, "feeRecipient paid");
    }

    // ========================================================================
    // NEGATIVE PATHS — ETHEREUM SIDE (Sender / Portal)
    // ========================================================================

    function test_E2E_Send_RevertsOnInsufficientFee() public {
        uint256 amount = 100 ether;
        uint256 fee = sender.calculateBridgeFee(amount, bob);

        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.expectRevert(); // Portal reverts with InsufficientFee; exact args bubble through
        sender.bridgeToGravity{ value: fee - 1 }(amount, bob);
        vm.stopPrank();

        assertEq(portal.nonce(), 0, "portal nonce must not advance on revert");
        assertEq(gToken.balanceOf(alice), INITIAL_BALANCE, "alice not debited on revert");
    }

    function test_E2E_Send_RevertsOnExcessiveFee() public {
        uint256 amount = 100 ether;
        uint256 fee = sender.calculateBridgeFee(amount, bob);

        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.expectRevert();
        sender.bridgeToGravity{ value: 2 * fee + 1 }(amount, bob);
        vm.stopPrank();
    }

    function test_E2E_Send_RevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IGBridgeSender.ZeroAmount.selector);
        sender.bridgeToGravity{ value: 0 }(0, bob);
    }

    function test_E2E_Send_RevertsOnZeroRecipient() public {
        uint256 amount = 1 ether;
        uint256 fee = sender.calculateBridgeFee(amount, address(0));
        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.expectRevert(IGBridgeSender.ZeroRecipient.selector);
        sender.bridgeToGravity{ value: fee }(amount, address(0));
        vm.stopPrank();
    }

    // ========================================================================
    // NEGATIVE PATHS — GRAVITY SIDE (Receiver trust boundary)
    // ========================================================================

    /// @notice A malicious EOA calls Portal.send directly to forge a payload —
    ///         the Receiver must reject it because embedded sender != trustedBridge.
    ///         This is the central trust boundary for the whole bridge.
    function test_E2E_Receiver_RejectsForgedPayloadFromRandomSender() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);

        // Craft a legitimate-looking Gravity-bridge message body (but with attacker as sender).
        bytes memory body = abi.encode(uint256(999 ether), bob);
        uint256 requiredFee = portal.calculateFee(PortalMessage.MIN_PAYLOAD_LENGTH + body.length);

        vm.recordLogs();
        vm.prank(attacker);
        portal.send{ value: requiredFee }(body);
        (,, bytes memory payload) = _capturePayload();

        // Sanity: the portal embedded attacker as the sender.
        (address embeddedSender,,) = PortalMessage.decode(payload);
        assertEq(embeddedSender, attacker, "Portal embeds msg.sender as the payload sender");

        // Oracle tries to deliver. Receiver must reject.
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        vm.expectRevert(abi.encodeWithSelector(IGBridgeReceiver.InvalidSender.selector, attacker, address(sender)));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, payload);

        assertEq(mintCapture.callCount(), 0, "no mint on forged payload");
    }

    /// @notice Even a legitimate payload must be rejected if the oracle claims
    ///         it came from the wrong source chain.
    function test_E2E_Receiver_RejectsWrongSourceId() public {
        (, bytes memory payload) = _bridge(10 ether, bob);
        uint256 wrongSourceId = 56; // BSC

        vm.prank(SystemAddresses.NATIVE_ORACLE);
        vm.expectRevert(
            abi.encodeWithSelector(IGBridgeReceiver.InvalidSourceChain.selector, wrongSourceId, ETHEREUM_CHAIN_ID)
        );
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, wrongSourceId, 1, payload);

        assertEq(mintCapture.callCount(), 0, "no mint on wrong sourceId");
    }

    /// @notice Only NATIVE_ORACLE may invoke onOracleEvent; EOAs must be rejected.
    function test_E2E_Receiver_RejectsNonOracleCaller() public {
        (, bytes memory payload) = _bridge(10 ether, bob);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, attacker, SystemAddresses.NATIVE_ORACLE));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, payload);

        assertEq(mintCapture.callCount(), 0, "no mint on wrong caller");
    }

    /// @notice Sanity: even if the oracle call passes all trust checks, if the
    ///         body decodes to (0, …) the receiver reverts with ZeroAmount.
    ///         To reach this we bypass the sender and craft a payload directly.
    function test_E2E_Receiver_RejectsZeroAmountBody() public {
        bytes memory body = abi.encode(uint256(0), bob);
        bytes memory payload = PortalMessage.encode(address(sender), 1, body);

        vm.prank(SystemAddresses.NATIVE_ORACLE);
        vm.expectRevert(Errors.ZeroAmount.selector);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, payload);
    }

    function test_E2E_Receiver_RejectsZeroRecipientBody() public {
        bytes memory body = abi.encode(uint256(1 ether), address(0));
        bytes memory payload = PortalMessage.encode(address(sender), 1, body);

        vm.prank(SystemAddresses.NATIVE_ORACLE);
        vm.expectRevert(Errors.ZeroAddress.selector);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, payload);
    }

    /// @notice If the precompile reverts (grevm returned !success), the receiver
    ///         reverts with MintFailed — no half-finished state.
    function test_E2E_Receiver_RevertsWhenPrecompileFails() public {
        (, bytes memory payload) = _bridge(10 ether, bob);
        mintCapture.setShouldRevert(true);

        vm.prank(SystemAddresses.NATIVE_ORACLE);
        vm.expectRevert(abi.encodeWithSelector(IGBridgeReceiver.MintFailed.selector, bob, 10 ether));
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, payload);
    }

    // ========================================================================
    // FUZZ
    // ========================================================================

    /// @notice Fuzz the full round-trip: any (amount, recipient) that Alice can
    ///         afford must lock on Ethereum and mint exactly that much on Gravity.
    function testFuzz_E2E_RoundTrip(uint256 amount, address recipient) public {
        amount = bound(amount, 1, INITIAL_BALANCE);
        vm.assume(recipient != address(0));

        (uint128 portalNonce, bytes memory payload) = _bridge(amount, recipient);
        _deliver({ oracleNonce: uint128(portalNonce), sourceId: ETHEREUM_CHAIN_ID, payload: payload });

        MintCapture.Call memory c = mintCapture.lastCall();
        assertEq(c.recipient, recipient);
        assertEq(c.amount, amount);
    }
}
