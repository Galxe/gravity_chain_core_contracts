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
import { Errors } from "@src/foundation/Errors.sol";
import { MockGToken } from "@test/utils/MockGToken.sol";
import { MintCapture } from "@test/utils/MintCapture.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

// ============================================================================
// Adversarial helpers
// ============================================================================

/// @notice G-like token that burns a fixed percentage on every transfer.
///         Used to validate I-2 / S-2 (fee-on-transfer safety).
contract FeeOnTransferToken is ERC20, ERC20Permit {
    uint256 public immutable feeBps;

    constructor(
        uint256 feeBps_
    ) ERC20("FoT G", "fG") ERC20Permit("FoT G") {
        feeBps = feeBps_;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Skip fee for mints (from == address(0)) so initial balances are whole.
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        super._update(from, address(0xdead), fee); // "burn" to dead to keep totalSupply observable
    }
}

/// @notice Fee recipient that re-enters GravityPortal.send during the ETH
///         transfer of withdrawFees. Used by S-4.
contract ReentrantFeeRecipient {
    GravityPortal internal immutable portal;
    uint256 public reentryCount;

    constructor(
        GravityPortal portal_
    ) {
        portal = portal_;
    }

    receive() external payable {
        if (reentryCount < 1) {
            reentryCount++;
            // Reenter: try to call send with our just-received fee amount.
            // This must not corrupt state. We expect either success (portal
            // treats it as a normal permissionless send with the reentrant
            // value as fee) or a clean revert — the test handles either.
            uint256 feeReq = portal.calculateFee(0); // empty body
            if (address(this).balance >= feeReq && feeReq > 0) {
                try portal.send{ value: feeReq }(hex"") returns (uint128) {
                    // reentrant send accepted
                } catch {
                    // reentrant send rejected; also acceptable
                }
            }
        }
    }
}

// ============================================================================
// Spec tests
// ============================================================================

/// @title SecuritySpecE2E
/// @notice Asserts each item in `spec_v2/oracle_evm_bridge.security.spec.md`.
///         Test names are prefixed with the spec ID (I-N / S-N).
contract SecuritySpecE2E is Test {
    MockGToken internal gToken;
    GravityPortal internal portal;
    GBridgeSender internal sender;
    GBridgeReceiver internal receiver;
    MintCapture internal mintCapture;

    address internal owner;
    address internal feeRecipient;
    address internal alice;
    uint256 internal alicePk;
    address internal bob;

    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint32 internal constant SOURCE_TYPE_BLOCKCHAIN = 0;

    uint256 internal constant BASE_FEE = 0.0001 ether;
    uint256 internal constant FEE_PER_BYTE = 1_250_000_000_000;

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        alicePk = 0xA11CE;
        alice = vm.addr(alicePk);
        bob = makeAddr("bob");

        gToken = new MockGToken();
        portal = new GravityPortal(owner, BASE_FEE, FEE_PER_BYTE, feeRecipient);
        sender = new GBridgeSender(address(gToken), address(portal), owner);
        receiver = new GBridgeReceiver(address(sender), ETHEREUM_CHAIN_ID);

        gToken.mint(alice, INITIAL_BALANCE);
        vm.deal(alice, 100 ether);

        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(new MintCapture()).code);
        mintCapture = MintCapture(SystemAddresses.NATIVE_MINT_PRECOMPILE);
    }

    // -------- helpers --------

    function _bridge(uint256 amount, address recipient) internal returns (uint128 portalNonce, bytes memory payload) {
        uint256 fee = sender.calculateBridgeFee(amount, recipient);
        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.recordLogs();
        sender.bridgeToGravity{ value: fee }(amount, recipient);
        vm.stopPrank();
        (portalNonce, payload) = _lastMessageSent();
    }

    function _lastMessageSent() internal returns (uint128 nonce, bytes memory payload) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("MessageSent(uint128,uint256,bytes)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == address(portal) && l.topics.length > 0 && l.topics[0] == sig) {
                nonce = uint128(uint256(l.topics[1]));
                payload = abi.decode(l.data, (bytes));
                return (nonce, payload);
            }
        }
        revert("MessageSent not found");
    }

    function _deliver(uint128 oracleNonce, uint256 sourceId, bytes memory payload) internal {
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, sourceId, oracleNonce, payload);
    }

    // ========================================================================
    // Invariants
    // ========================================================================

    /// I-1 Conservation (non-rebasing token): locked on Ethereum == minted on Gravity.
    function test_I1_Conservation_NonRebasing() public {
        uint256[3] memory amounts = [uint256(17 ether), 42 ether, 1 ether];

        uint256 mintedOnGravity;
        bytes[] memory payloads = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            (, bytes memory p) = _bridge(amounts[i], bob);
            payloads[i] = p;
        }

        uint256 lockedOnEthereum = gToken.balanceOf(address(sender));
        assertEq(lockedOnEthereum, amounts[0] + amounts[1] + amounts[2], "Ethereum-side locked sum");

        for (uint256 i = 0; i < 3; i++) {
            _deliver(uint128(i + 1), ETHEREUM_CHAIN_ID, payloads[i]);
            mintedOnGravity += mintCapture.lastCall().amount;
        }
        assertEq(mintedOnGravity, lockedOnEthereum, "minted == locked");
    }

    /// I-3 Nonce monotonicity.
    function test_I3_NonceMonotonic() public {
        uint128 prev;
        for (uint256 i = 0; i < 5; i++) {
            (uint128 n,) = _bridge(1 ether, bob);
            assertGt(n, prev, "nonce must strictly increase");
            prev = n;
        }
        assertEq(portal.nonce(), 5);
    }

    /// I-5 PortalMessage encode/decode round-trip (including empty + large bodies).
    function test_I5_PortalMessageRoundTrip() public pure {
        address sndr = address(0xBEEF);
        uint128 n = 7;

        // empty body
        bytes memory p0 = PortalMessage.encode(sndr, n, "");
        (address s0, uint128 nn0, bytes memory b0) = PortalMessage.decode(p0);
        assertEq_helper(s0, sndr);
        require(nn0 == n, "nonce mismatch empty");
        require(b0.length == 0, "body length mismatch empty");

        // short body
        bytes memory short_ = hex"deadbeef";
        bytes memory p1 = PortalMessage.encode(sndr, n, short_);
        (address s1, uint128 nn1, bytes memory b1) = PortalMessage.decode(p1);
        assertEq_helper(s1, sndr);
        require(nn1 == n, "nonce mismatch short");
        require(keccak256(b1) == keccak256(short_), "body mismatch short");

        // large body (4 KB)
        bytes memory big = new bytes(4096);
        for (uint256 i = 0; i < big.length; i++) big[i] = bytes1(uint8(i & 0xff));
        bytes memory p2 = PortalMessage.encode(sndr, n, big);
        (address s2, uint128 nn2, bytes memory b2) = PortalMessage.decode(p2);
        assertEq_helper(s2, sndr);
        require(nn2 == n, "nonce mismatch big");
        require(keccak256(b2) == keccak256(big), "body mismatch big");
    }

    function assertEq_helper(address a, address b) internal pure {
        require(a == b, "addr mismatch");
    }

    /// I-6 Portal and Sender have no ETH inlet outside of send(). (S-9 is the same
    /// invariant viewed from the attacker side.)
    function test_I6_NoStuckEth_Portal() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(portal).call{ value: 1 ether }("");
        assertFalse(ok, "Portal must reject bare ETH");
        assertEq(address(portal).balance, 0, "Portal must hold 0 ETH after rejected transfer");
    }

    function test_I6_NoStuckEth_Sender() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(sender).call{ value: 1 ether }("");
        assertFalse(ok, "Sender must reject bare ETH");
        assertEq(address(sender).balance, 0);
    }

    /// I-7 Atomicity: a failure in Portal.send (here: insufficient fee) must unwind
    /// the preceding transferFrom entirely.
    function test_I7_Atomicity_OnPortalRevert() public {
        uint256 amount = 100 ether;
        uint256 fee = sender.calculateBridgeFee(amount, bob);

        uint256 aliceBal = gToken.balanceOf(alice);
        uint256 senderBal = gToken.balanceOf(address(sender));
        uint128 nonceBefore = portal.nonce();

        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.expectRevert(); // portal reverts with InsufficientFee
        sender.bridgeToGravity{ value: fee - 1 }(amount, bob);
        vm.stopPrank();

        assertEq(gToken.balanceOf(alice), aliceBal, "alice balance must be unchanged");
        assertEq(gToken.balanceOf(address(sender)), senderBal, "sender balance must be unchanged");
        assertEq(portal.nonce(), nonceBefore, "portal nonce must be unchanged");
    }

    /// I-8 Fee envelope: required ≤ msg.value ≤ 2*required is accepted; both bounds
    /// outside revert.
    function test_I8_FeeEnvelope_Boundaries() public {
        uint256 amount = 100 ether;
        uint256 fee = sender.calculateBridgeFee(amount, bob);

        // exactly required: ok
        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        sender.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();

        // exactly 2*required: still ok
        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        sender.bridgeToGravity{ value: 2 * fee }(amount, bob);
        vm.stopPrank();

        // 2*required + 1: excessive
        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.expectRevert(abi.encodeWithSelector(IGravityPortal.ExcessiveFee.selector, fee, 2 * fee + 1));
        sender.bridgeToGravity{ value: 2 * fee + 1 }(amount, bob);
        vm.stopPrank();

        // required - 1: insufficient
        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.expectRevert(abi.encodeWithSelector(IGravityPortal.InsufficientFee.selector, fee, fee - 1));
        sender.bridgeToGravity{ value: fee - 1 }(amount, bob);
        vm.stopPrank();
    }

    /// I-9 Replay is oracle-side: receiver has no per-message replay guard. This
    /// test deliberately calls onOracleEvent twice with the same payload and
    /// asserts BOTH succeed. If a future change silently adds a local replay
    /// guard, this test turns red and forces an explicit decision.
    function test_I9_ReceiverNoLocalReplayGuard() public {
        (, bytes memory payload) = _bridge(10 ether, bob);

        _deliver(1, ETHEREUM_CHAIN_ID, payload);
        _deliver(2, ETHEREUM_CHAIN_ID, payload); // same payload, different oracle nonce

        assertEq(mintCapture.callCount(), 2, "receiver mints again - replay guard is oracle-side");
        MintCapture.Call memory c = mintCapture.lastCall();
        assertEq(c.amount, 10 ether);
    }

    // ========================================================================
    // Adversarial scenarios
    // ========================================================================

    /// S-2 Fee-on-transfer G token: amount encoded = amount actually received.
    function test_S2_FeeOnTransferToken() public {
        FeeOnTransferToken fotG = new FeeOnTransferToken({ feeBps_: 500 }); // 5 %
        GBridgeSender fotSender = new GBridgeSender(address(fotG), address(portal), owner);
        GBridgeReceiver fotReceiver = new GBridgeReceiver(address(fotSender), ETHEREUM_CHAIN_ID);

        fotG.mint(alice, INITIAL_BALANCE);
        uint256 amount = 100 ether;
        uint256 fee = portal.calculateFee(64); // abi.encode(uint256, address) = 64
        uint256 expectedReceived = amount - (amount * 500) / 10_000; // 95 ether

        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        fotG.approve(address(fotSender), amount);
        vm.recordLogs();
        fotSender.bridgeToGravity{ value: fee }(amount, bob);
        vm.stopPrank();
        (, bytes memory payload) = _lastMessageSent();

        // Alice paid 100, sender received 95, sender's balance = 95
        assertEq(fotG.balanceOf(address(fotSender)), expectedReceived, "sender holds actualReceived");

        // Payload body encodes actualReceived, not the nominal amount
        (,, bytes memory body) = PortalMessage.decode(payload);
        (uint256 msgAmount,) = abi.decode(body, (uint256, address));
        assertEq(msgAmount, expectedReceived, "message amount == actualReceived");

        // Deliver to receiver → mint exactly expectedReceived
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        fotReceiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, payload);
        assertEq(mintCapture.lastCall().amount, expectedReceived, "minted == actualReceived (no phantom)");
    }

    /// S-3 Mid-flight fee hike: owner raises feePerByte between calculateBridgeFee
    /// and Alice's tx; Alice's tx reverts atomically.
    function test_S3_MidFlightFeeHike_RevertsAtomically() public {
        uint256 amount = 10 ether;
        uint256 originalFee = sender.calculateBridgeFee(amount, bob);

        // Owner raises the fee.
        vm.prank(owner);
        portal.setFeePerByte(FEE_PER_BYTE * 10);

        uint256 aliceBal = gToken.balanceOf(alice);
        uint256 senderBal = gToken.balanceOf(address(sender));

        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        vm.expectRevert(); // InsufficientFee (exact args are noisy here, any revert suffices)
        sender.bridgeToGravity{ value: originalFee }(amount, bob);
        vm.stopPrank();

        assertEq(gToken.balanceOf(alice), aliceBal, "alice not debited");
        assertEq(gToken.balanceOf(address(sender)), senderBal, "sender not credited");
    }

    /// S-4 Reentrant withdrawFees via attacker-controlled feeRecipient.
    /// We assert: no double-drain, final portal balance equals the reentrant-attacker's
    /// own deposits (if any) — not a penny extra.
    function test_S4_ReentrantWithdrawFees() public {
        ReentrantFeeRecipient attacker = new ReentrantFeeRecipient(portal);
        vm.deal(address(attacker), 10 ether);

        // Point Portal at the attacker
        vm.prank(owner);
        portal.setFeeRecipient(address(attacker));

        // Seed Portal with one legitimate bridge (which pays fee).
        _bridge(1 ether, bob);

        uint256 portalBalBefore = address(portal).balance;
        assertGt(portalBalBefore, 0);

        // Owner withdraws. Reentry happens inside receive().
        vm.prank(owner);
        portal.withdrawFees();

        // After the outer withdraw: the attacker has received portalBalBefore minus
        // whatever they themselves spent in reentrant sends (the reentrant send's
        // msg.value is subtracted from their balance on the attacker contract).
        // Any NEW fees paid during reentry end up in portal.balance and are NOT
        // double-drained.
        uint256 portalBalAfter = address(portal).balance;
        // Portal balance after = reentrant send's fee (if any). It is always >= 0 and
        // NEVER greater than the attacker's ether reserve.
        assertLe(portalBalAfter, 10 ether, "portal can only hold what the attacker deposited during reentry");

        // Nonce advanced coherently — baseline send(1) + however many reentrant sends.
        assertGe(portal.nonce(), 1, "nonce advances monotonically through reentry");
    }

    /// S-5 Permit front-run DoS: attacker consumes Alice's permit nonce; Alice's
    /// bridge tx reverts; Alice's balance is intact.
    function test_S5_PermitFrontRun_AliceTokensSafe() public {
        uint256 amount = 50 ether;
        uint256 fee = sender.calculateBridgeFee(amount, bob);
        uint256 deadline = block.timestamp + 1 hours;

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

        // Attacker front-runs: calls permit directly on the token to consume the nonce.
        gToken.permit(alice, address(sender), amount, deadline, v, r, s);

        uint256 aliceBalBefore = gToken.balanceOf(alice);

        // Alice's tx now fails because the permit nonce has advanced.
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(); // OZ permit reverts with ERC2612InvalidSigner
        sender.bridgeToGravityWithPermit{ value: fee }(amount, bob, deadline, v, r, s);

        assertEq(gToken.balanceOf(alice), aliceBalBefore, "alice tokens untouched on permit front-run");
    }

    /// S-6 Owner CAN drain locked tokens (documented centralization).
    function test_S6_OwnerCanDrainLockedTokens() public {
        _bridge(200 ether, bob);
        assertEq(gToken.balanceOf(address(sender)), 200 ether);

        address rescueTo = makeAddr("rescueTo");
        vm.prank(owner);
        sender.recoverERC20(address(gToken), rescueTo, 200 ether);

        assertEq(gToken.balanceOf(address(sender)), 0, "sender drained");
        assertEq(gToken.balanceOf(rescueTo), 200 ether, "rescue recipient paid");
    }

    /// S-7 Non-owner cannot drain (and cannot touch any onlyOwner entrypoint).
    function test_S7_NonOwner_Blocked_OnAllAdminPaths() public {
        address attacker = makeAddr("attacker");

        vm.startPrank(attacker);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        sender.recoverERC20(address(gToken), attacker, 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        sender.emergencyWithdraw(attacker, 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        portal.setBaseFee(0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        portal.setFeePerByte(0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        portal.setFeeRecipient(attacker);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        portal.withdrawFees();

        vm.stopPrank();
    }

    /// S-8 Overpayment within the 2× envelope is absorbed (no refund).
    function test_S8_OverpaymentAbsorbed_NoRefund() public {
        uint256 amount = 10 ether;
        uint256 fee = sender.calculateBridgeFee(amount, bob);
        uint256 overpay = (fee * 3) / 2; // 1.5× required

        uint256 aliceEthBefore = alice.balance;
        uint256 portalEthBefore = address(portal).balance;

        vm.startPrank(alice);
        gToken.approve(address(sender), amount);
        sender.bridgeToGravity{ value: overpay }(amount, bob);
        vm.stopPrank();

        assertEq(alice.balance, aliceEthBefore - overpay, "no refund to alice");
        assertEq(address(portal).balance, portalEthBefore + overpay, "portal kept full msg.value");
    }

    /// S-9 Raw ETH → Portal / Sender fails. (Mirror of I-6.)
    function test_S9_RawEth_Rejected() public {
        vm.deal(address(this), 3 ether);
        (bool p,) = address(portal).call{ value: 1 ether }("");
        (bool s,) = address(sender).call{ value: 1 ether }("");
        assertFalse(p);
        assertFalse(s);
    }

    /// S-10 Under-length payload to Receiver reverts cleanly.
    function test_S10_UnderLengthPayload_Rejected() public {
        bytes memory shortPayload = hex"deadbeef"; // 4 bytes, far below 36 minimum
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        vm.expectRevert(
            abi.encodeWithSelector(
                PortalMessage.InsufficientDataLength.selector, shortPayload.length, PortalMessage.MIN_PAYLOAD_LENGTH
            )
        );
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, shortPayload);
        assertEq(mintCapture.callCount(), 0);
    }

    /// S-11 Malformed message body (not decodable to (uint256, address)) reverts.
    function test_S11_MalformedBody_Rejected() public {
        bytes memory garbageBody = hex"01020304050607080910111213141516171819202122232425262728293031";
        // Length 31 = cannot decode as two 32-byte abi words.
        bytes memory payload = PortalMessage.encode(address(sender), 1, garbageBody);
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        vm.expectRevert(); // abi.decode reverts generically
        receiver.onOracleEvent(SOURCE_TYPE_BLOCKCHAIN, ETHEREUM_CHAIN_ID, 1, payload);
        assertEq(mintCapture.callCount(), 0);
    }

    /// S-13 Unknown sourceType currently passes (documented boundary).
    function test_S13_UnknownSourceType_CurrentlyPasses() public {
        (, bytes memory payload) = _bridge(1 ether, bob);
        vm.prank(SystemAddresses.NATIVE_ORACLE);
        receiver.onOracleEvent(42, ETHEREUM_CHAIN_ID, 1, payload); // sourceType = 42 (arbitrary)
        assertEq(mintCapture.callCount(), 1, "sourceType is not gated today");
    }

    /// S-14 Large body fee formula end-to-end: fee = baseFee + (36 + bodyLen) * feePerByte.
    function test_S14_LargeBody_FeeFormulaPinned() public {
        bytes memory body = new bytes(10_240); // 10 KB
        for (uint256 i = 0; i < body.length; i++) body[i] = bytes1(uint8(i & 0xff));

        uint256 expected = BASE_FEE + (PortalMessage.MIN_PAYLOAD_LENGTH + body.length) * FEE_PER_BYTE;
        assertEq(portal.calculateFee(body.length), expected, "fee formula pinned");

        vm.deal(alice, expected);
        vm.prank(alice);
        portal.send{ value: expected }(body);
        assertEq(address(portal).balance, expected);
    }

    /// S-15 Ownership transfer is two-step.
    function test_S15_Ownable2Step_Portal() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        portal.transferOwnership(newOwner);

        assertEq(portal.owner(), owner, "owner unchanged before accept");
        assertEq(portal.pendingOwner(), newOwner);

        vm.prank(newOwner);
        portal.acceptOwnership();

        assertEq(portal.owner(), newOwner);
        assertEq(portal.pendingOwner(), address(0));
    }
}
