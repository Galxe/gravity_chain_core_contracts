// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { INativeOracle, IOracleCallback } from "../INativeOracle.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";

/// @title PolymarketSettlementResolver
/// @notice Callback for finalized Polymarket CTF settlement events mirrored from Polygon.
/// @dev NativeOracle keeps the raw payload. This resolver stores application-ready settlement state.
contract PolymarketSettlementResolver is IOracleCallback {
    uint32 public constant SOURCE_TYPE_POLYMARKET_SETTLEMENT = 6;
    uint256 public constant POLYGON_CHAIN_ID = 137;
    uint8 public constant SETTLEMENT_KIND_CTF_CONDITION_RESOLUTION = 1;
    uint256 public constant MAX_OUTCOME_SLOT_COUNT = 32;

    struct MirrorConfig {
        bool exists;
        uint256 polygonChainId;
        address ctf;
        bytes32 conditionId;
        uint256 outcomeSlotCount;
    }

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
        bool exists;
        uint128 nonce;
        uint256 polygonChainId;
        address ctf;
        address oracle;
        bytes32 conditionId;
        bytes32 questionId;
        uint256 outcomeSlotCount;
        bytes32 txHash;
        uint256 logIndex;
        uint8 settlementKind;
        uint256[] payoutNumerators;
    }

    mapping(uint256 mirrorId => MirrorConfig config) public mirrorConfigs;
    mapping(uint256 mirrorId => mapping(bytes32 conditionId => Settlement settlement)) private _settlements;

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
        uint256[] payoutNumerators
    );

    error UnsupportedSourceType(uint32 sourceType);
    error MirrorNotRegistered(uint256 mirrorId);
    error SourceIdMismatch(uint256 expected, uint256 provided);
    error InvalidMirrorConfig();
    error InvalidSettlementKind(uint8 settlementKind);
    error InvalidSettlementPayload();
    error ConditionMismatch(bytes32 expected, bytes32 provided);
    error CtfMismatch(address expected, address provided);
    error ChainIdMismatch(uint256 expected, uint256 provided);
    error OutcomeSlotCountMismatch(uint256 expected, uint256 provided);
    error MirrorAlreadyRegistered(uint256 mirrorId);
    error SettlementAlreadyResolved(uint256 mirrorId, bytes32 conditionId);
    error RecordUnavailable(uint32 sourceType, uint256 sourceId, uint128 nonce);

    function registerMirror(
        uint256 mirrorId,
        uint256 polygonChainId,
        address ctf,
        bytes32 conditionId,
        uint256 outcomeSlotCount
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        if (
            mirrorId == 0 || polygonChainId != POLYGON_CHAIN_ID || ctf == address(0) || conditionId == bytes32(0)
                || outcomeSlotCount == 0 || outcomeSlotCount > MAX_OUTCOME_SLOT_COUNT
        ) {
            revert InvalidMirrorConfig();
        }
        if (mirrorConfigs[mirrorId].exists) revert MirrorAlreadyRegistered(mirrorId);

        mirrorConfigs[mirrorId] = MirrorConfig({
            exists: true,
            polygonChainId: polygonChainId,
            ctf: ctf,
            conditionId: conditionId,
            outcomeSlotCount: outcomeSlotCount
        });

        emit MirrorRegistered(mirrorId, polygonChainId, ctf, conditionId, outcomeSlotCount);
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

        PolymarketSettlementPayload memory settlement = abi.decode(payload, (PolymarketSettlementPayload));
        _resolve(sourceId, nonce, settlement);
        return true;
    }

    /// @notice Replays a consensus-stored settlement when its callback previously failed.
    /// @dev Anyone may call this because the payload is read from NativeOracle.
    function replaySettlement(
        uint256 mirrorId,
        uint128 nonce
    ) external {
        INativeOracle.DataRecord memory record =
            INativeOracle(SystemAddresses.NATIVE_ORACLE).getRecord(SOURCE_TYPE_POLYMARKET_SETTLEMENT, mirrorId, nonce);
        if (record.recordedAt == 0) {
            revert RecordUnavailable(SOURCE_TYPE_POLYMARKET_SETTLEMENT, mirrorId, nonce);
        }
        _resolve(mirrorId, nonce, abi.decode(record.data, (PolymarketSettlementPayload)));
    }

    function getSettlement(
        uint256 mirrorId,
        bytes32 conditionId
    )
        external
        view
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
        Settlement storage settlement = _settlements[mirrorId][conditionId];
        return (
            settlement.exists,
            settlement.nonce,
            settlement.polygonChainId,
            settlement.ctf,
            settlement.oracle,
            settlement.questionId,
            settlement.outcomeSlotCount,
            settlement.txHash,
            settlement.logIndex,
            settlement.settlementKind
        );
    }

    function getPayoutNumerators(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (uint256[] memory) {
        return _settlements[mirrorId][conditionId].payoutNumerators;
    }

    function _resolve(
        uint256 sourceId,
        uint128 nonce,
        PolymarketSettlementPayload memory payload
    ) internal {
        if (sourceId != payload.mirrorId) revert SourceIdMismatch(payload.mirrorId, sourceId);

        MirrorConfig memory config = mirrorConfigs[payload.mirrorId];
        if (!config.exists) revert MirrorNotRegistered(payload.mirrorId);
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
        if (payload.oracle == address(0) || payload.questionId == bytes32(0) || payload.txHash == bytes32(0)) {
            revert InvalidSettlementPayload();
        }

        bool hasPayout;
        for (uint256 i; i < payload.payoutNumerators.length;) {
            if (payload.payoutNumerators[i] > 0) hasPayout = true;
            unchecked {
                ++i;
            }
        }
        if (!hasPayout) revert InvalidSettlementPayload();

        Settlement storage stored = _settlements[payload.mirrorId][payload.conditionId];
        if (stored.exists) revert SettlementAlreadyResolved(payload.mirrorId, payload.conditionId);
        stored.exists = true;
        stored.nonce = nonce;
        stored.polygonChainId = payload.polygonChainId;
        stored.ctf = payload.ctf;
        stored.oracle = payload.oracle;
        stored.conditionId = payload.conditionId;
        stored.questionId = payload.questionId;
        stored.outcomeSlotCount = payload.outcomeSlotCount;
        stored.txHash = payload.txHash;
        stored.logIndex = payload.logIndex;
        stored.settlementKind = payload.settlementKind;
        stored.payoutNumerators = payload.payoutNumerators;

        emit PolymarketConditionResolved(
            payload.mirrorId,
            payload.conditionId,
            payload.questionId,
            nonce,
            payload.oracle,
            payload.txHash,
            payload.logIndex,
            payload.payoutNumerators
        );
    }
}
