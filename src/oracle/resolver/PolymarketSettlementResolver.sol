// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IOracleCallback } from "../INativeOracle.sol";
import { IPolymarketSettlementResolver } from "./IPolymarketSettlementResolver.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";

/// @title PolymarketSettlementResolver
/// @notice Stores canonical terminal Polygon CTF settlements agreed by Gravity validators.
/// @dev Each governance-registered mirror is permanently bound to one Polygon condition.
contract PolymarketSettlementResolver is IOracleCallback, IPolymarketSettlementResolver {
    /// @notice NativeOracle source type reserved for Polymarket settlement mirrors.
    uint32 public constant SOURCE_TYPE_POLYMARKET_SETTLEMENT = 6;
    /// @notice Polygon PoS mainnet chain identifier.
    uint256 public constant POLYGON_CHAIN_ID = 137;
    /// @notice Payload discriminator for a CTF `ConditionResolution` event.
    uint8 public constant SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION = 1;
    /// @notice Maximum supported outcome count, bounding decode and callback costs.
    uint256 public constant MAX_OUTCOME_SLOT_COUNT = 32;

    uint256 private constant _MIN_OUTCOME_SLOT_COUNT = 2;
    // Top-level tuple offset, eleven tuple-head words, array length, then N array elements.
    uint256 private constant _ENCODED_PAYLOAD_BASE_WORDS = 13;

    struct MirrorConfig {
        bool exists;
        uint64 polygonChainId;
        address ctf;
        uint8 outcomeSlotCount;
        bytes32 conditionId;
    }

    /// @notice Canonical callback payload produced by the Polygon settlement provider.
    struct PolymarketSettlementPayload {
        uint256 mirrorId;
        uint256 polygonChainId;
        address ctf;
        address oracle;
        bytes32 conditionId;
        bytes32 questionId;
        uint256 outcomeSlotCount;
        uint256[] payoutNumerators;
        bytes32 txHash;
        uint256 logIndex;
        uint8 settlementKind;
    }

    struct Settlement {
        ObservationStatus status;
        uint8 winningSlot;
        uint64 recordedAt;
        uint128 nonce;
        address oracle;
        uint64 logIndex;
        bytes32 questionId;
        bytes32 txHash;
    }

    mapping(uint256 mirrorId => MirrorConfig config) private _mirrorConfigs;
    mapping(uint256 mirrorId => Settlement settlement) private _settlements;

    event MirrorRegistered(
        uint256 indexed mirrorId,
        uint256 polygonChainId,
        address indexed ctf,
        bytes32 indexed conditionId,
        uint256 outcomeSlotCount
    );

    event PolymarketConditionResolved(
        uint256 indexed mirrorId,
        bytes32 indexed conditionId,
        bytes32 indexed questionId,
        uint128 nonce,
        address oracle,
        bytes32 txHash,
        uint256 logIndex,
        ObservationStatus status,
        uint8 winningSlot,
        uint256[] payoutNumerators
    );

    error UnsupportedSourceType(uint32 sourceType);
    error MirrorNotRegistered(uint256 mirrorId);
    error SourceIdMismatch(uint256 expected, uint256 provided);
    error InvalidMirrorConfig();
    error InvalidSettlementKind(uint8 settlementKind);
    error InvalidSettlementPayload();
    error ConditionMismatch(bytes32 expected, bytes32 provided);
    error ConditionIdentityMismatch(bytes32 expected, bytes32 provided);
    error CtfMismatch(address expected, address provided);
    error ChainIdMismatch(uint256 expected, uint256 provided);
    error OutcomeSlotCountMismatch(uint256 expected, uint256 provided);
    error MirrorAlreadyRegistered(uint256 mirrorId);
    error SettlementAlreadyResolved(uint256 mirrorId);

    /// @notice Bind a stable mirror ID to exactly one Polygon CTF condition.
    /// @dev `mirrorId` is restricted to the `uint64` identity supported by relayer task URIs.
    function registerMirror(
        uint256 mirrorId,
        uint256 polygonChainId,
        address ctf,
        bytes32 conditionId,
        uint256 outcomeSlotCount
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        if (
            mirrorId == 0 || mirrorId > type(uint64).max || polygonChainId != POLYGON_CHAIN_ID || ctf == address(0)
                || conditionId == bytes32(0) || outcomeSlotCount < _MIN_OUTCOME_SLOT_COUNT
                || outcomeSlotCount > MAX_OUTCOME_SLOT_COUNT
        ) {
            revert InvalidMirrorConfig();
        }
        if (_mirrorConfigs[mirrorId].exists) revert MirrorAlreadyRegistered(mirrorId);

        _mirrorConfigs[mirrorId] = MirrorConfig({
            exists: true,
            // Bounds are fixed to Polygon mainnet above.
            // forge-lint: disable-next-line(unsafe-typecast)
            polygonChainId: uint64(polygonChainId),
            ctf: ctf,
            // Bounds are checked against MAX_OUTCOME_SLOT_COUNT above.
            // forge-lint: disable-next-line(unsafe-typecast)
            outcomeSlotCount: uint8(outcomeSlotCount),
            conditionId: conditionId
        });

        emit MirrorRegistered(mirrorId, polygonChainId, ctf, conditionId, outcomeSlotCount);
    }

    /// @inheritdoc IPolymarketSettlementResolver
    function getMirrorConfig(
        uint256 mirrorId
    )
        external
        view
        override
        returns (bool exists, uint256 polygonChainId, address ctf, bytes32 conditionId, uint256 outcomeSlotCount)
    {
        MirrorConfig storage config = _mirrorConfigs[mirrorId];
        return (config.exists, config.polygonChainId, config.ctf, config.conditionId, config.outcomeSlotCount);
    }

    /// @inheritdoc IOracleCallback
    function onOracleEvent(
        uint32 sourceType,
        uint256 sourceId,
        uint128 nonce,
        bytes calldata payload
    ) external override returns (bool shouldStore) {
        requireAllowed(SystemAddresses.NATIVE_ORACLE);
        if (sourceType != SOURCE_TYPE_POLYMARKET_SETTLEMENT) revert UnsupportedSourceType(sourceType);

        _resolveEncoded(sourceId, nonce, payload);
        return false;
    }

    /// @inheritdoc IPolymarketSettlementResolver
    function isSettlementObserved(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view override returns (bool observed) {
        return _isRegisteredCondition(mirrorId, conditionId) && _settlements[mirrorId].status != ObservationStatus.None;
    }

    /// @inheritdoc IPolymarketSettlementResolver
    function getSettlementObservation(
        uint256 mirrorId,
        bytes32 conditionId
    )
        external
        view
        override
        returns (
            ObservationStatus status,
            uint8 winningSlot,
            uint128 nonce,
            uint64 recordedAt,
            bytes32 txHash,
            uint256 logIndex
        )
    {
        if (!_isRegisteredCondition(mirrorId, conditionId)) {
            return (ObservationStatus.None, type(uint8).max, 0, 0, bytes32(0), 0);
        }

        Settlement storage settlement = _settlements[mirrorId];
        if (settlement.status == ObservationStatus.None) {
            return (ObservationStatus.None, type(uint8).max, 0, 0, bytes32(0), 0);
        }
        return (
            settlement.status,
            settlement.winningSlot,
            settlement.nonce,
            settlement.recordedAt,
            settlement.txHash,
            settlement.logIndex
        );
    }

    /// @notice Strictly classify canonical payload bytes without modifying state.
    function classifySettlementPayload(
        uint256 sourceId,
        bytes calldata encoded
    ) external view returns (ObservationStatus status, uint8 winningSlot) {
        (, status, winningSlot) = _decodeAndClassify(sourceId, encoded);
    }

    /// @inheritdoc IPolymarketSettlementResolver
    function getSettlement(
        uint256 mirrorId,
        bytes32 conditionId
    )
        external
        view
        override
        returns (
            bool exists,
            uint128 nonce,
            uint256 polygonChainId,
            address ctf,
            address oracle,
            bytes32 questionId,
            uint256 outcomeSlotCount,
            bytes32 txHash,
            uint256 logIndex,
            uint8 settlementKind
        )
    {
        if (!_isRegisteredCondition(mirrorId, conditionId)) {
            return (false, 0, 0, address(0), address(0), bytes32(0), 0, bytes32(0), 0, 0);
        }

        Settlement storage settlement = _settlements[mirrorId];
        if (settlement.status == ObservationStatus.None) {
            return (false, 0, 0, address(0), address(0), bytes32(0), 0, bytes32(0), 0, 0);
        }

        MirrorConfig storage config = _mirrorConfigs[mirrorId];
        return (
            true,
            settlement.nonce,
            config.polygonChainId,
            config.ctf,
            settlement.oracle,
            settlement.questionId,
            config.outcomeSlotCount,
            settlement.txHash,
            settlement.logIndex,
            SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION
        );
    }

    function _resolveEncoded(
        uint256 sourceId,
        uint128 nonce,
        bytes memory encoded
    ) internal {
        (PolymarketSettlementPayload memory payload, ObservationStatus status, uint8 winningSlot) =
            _decodeAndClassify(sourceId, encoded);

        Settlement storage stored = _settlements[sourceId];
        if (stored.status != ObservationStatus.None) revert SettlementAlreadyResolved(sourceId);

        stored.status = status;
        stored.winningSlot = winningSlot;
        stored.recordedAt = uint64(block.timestamp);
        stored.nonce = nonce;
        stored.oracle = payload.oracle;
        stored.logIndex = uint64(payload.logIndex);
        stored.questionId = payload.questionId;
        stored.txHash = payload.txHash;

        emit PolymarketConditionResolved(
            sourceId,
            payload.conditionId,
            payload.questionId,
            nonce,
            payload.oracle,
            payload.txHash,
            payload.logIndex,
            status,
            winningSlot,
            payload.payoutNumerators
        );
    }

    function _decodeAndClassify(
        uint256 sourceId,
        bytes memory encoded
    ) internal view returns (PolymarketSettlementPayload memory payload, ObservationStatus status, uint8 winningSlot) {
        MirrorConfig memory config = _mirrorConfigs[sourceId];
        if (!config.exists) revert MirrorNotRegistered(sourceId);

        uint256 expectedLength = (_ENCODED_PAYLOAD_BASE_WORDS + config.outcomeSlotCount) * 32;
        if (encoded.length != expectedLength) revert InvalidSettlementPayload();

        payload = abi.decode(encoded, (PolymarketSettlementPayload));
        if (keccak256(encoded) != keccak256(abi.encode(payload))) revert InvalidSettlementPayload();
        if (sourceId != payload.mirrorId) revert SourceIdMismatch(payload.mirrorId, sourceId);
        if (payload.settlementKind != SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION) {
            revert InvalidSettlementKind(payload.settlementKind);
        }
        if (payload.polygonChainId != config.polygonChainId) {
            revert ChainIdMismatch(config.polygonChainId, payload.polygonChainId);
        }
        if (payload.ctf != config.ctf) revert CtfMismatch(config.ctf, payload.ctf);
        if (payload.conditionId != config.conditionId) {
            revert ConditionMismatch(config.conditionId, payload.conditionId);
        }
        if (payload.outcomeSlotCount != config.outcomeSlotCount) {
            revert OutcomeSlotCountMismatch(config.outcomeSlotCount, payload.outcomeSlotCount);
        }
        if (payload.payoutNumerators.length != payload.outcomeSlotCount) {
            revert OutcomeSlotCountMismatch(payload.outcomeSlotCount, payload.payoutNumerators.length);
        }
        if (
            payload.oracle == address(0) || payload.questionId == bytes32(0) || payload.txHash == bytes32(0)
                || payload.logIndex > type(uint64).max
        ) {
            revert InvalidSettlementPayload();
        }

        bytes32 derivedConditionId =
            keccak256(abi.encodePacked(payload.oracle, payload.questionId, payload.outcomeSlotCount));
        if (derivedConditionId != payload.conditionId) {
            revert ConditionIdentityMismatch(payload.conditionId, derivedConditionId);
        }

        uint256 positivePayoutCount;
        winningSlot = type(uint8).max;
        for (uint256 i; i < payload.payoutNumerators.length;) {
            if (payload.payoutNumerators[i] > 0) {
                ++positivePayoutCount;
                // The registered outcome count is at most 32.
                // forge-lint: disable-next-line(unsafe-typecast)
                if (positivePayoutCount == 1) winningSlot = uint8(i);
            }
            unchecked {
                ++i;
            }
        }
        if (positivePayoutCount == 0) revert InvalidSettlementPayload();
        if (positivePayoutCount == 1) return (payload, ObservationStatus.ResolvedWinner, winningSlot);
        return (payload, ObservationStatus.ResolvedVoidable, type(uint8).max);
    }

    function _isRegisteredCondition(
        uint256 mirrorId,
        bytes32 conditionId
    ) private view returns (bool) {
        MirrorConfig storage config = _mirrorConfigs[mirrorId];
        return config.exists && config.conditionId == conditionId;
    }
}
