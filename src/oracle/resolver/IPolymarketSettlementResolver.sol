// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IPolymarketSettlementResolver
/// @notice Read interface used by markets that settle from mirrored Polymarket CTF resolutions.
interface IPolymarketSettlementResolver {
    enum ObservationStatus {
        None,
        PendingValid,
        ResolvedValid,
        Invalid
    }

    /// @notice Returns the immutable Polygon condition bound to a mirror ID.
    function getMirrorConfig(
        uint256 mirrorId
    )
        external
        view
        returns (bool exists, uint256 polygonChainId, address ctf, bytes32 conditionId, uint256 outcomeSlotCount);

    /// @notice Returns true once a settlement is resolved or its consensus payload is pending replay.
    /// @dev Markets use this fail-closed predicate to stop accepting stake as soon as the result is public.
    function isSettlementObserved(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (bool observed);

    /// @notice Returns the consensus observation used to resolve the deadline race.
    /// @dev Resolved observations are tied to the settlement's stored nonce, not the latest source nonce.
    function getSettlementObservation(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (ObservationStatus status, uint128 nonce, uint64 recordedAt);

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
        );

    function getPayoutNumerators(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (uint256[] memory);
}
