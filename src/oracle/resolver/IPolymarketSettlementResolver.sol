// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IPolymarketSettlementResolver
/// @notice Read interface used by markets that settle from mirrored Polymarket CTF resolutions.
interface IPolymarketSettlementResolver {
    enum ObservationStatus {
        None,
        PendingValid, // Legacy raw-payload state; new atomic deliveries never return this.
        ResolvedWinner,
        ResolvedVoidable,
        Invalid
    }

    /// @notice Returns the immutable Polygon condition bound to a mirror ID.
    function getMirrorConfig(
        uint256 mirrorId
    )
        external
        view
        returns (bool exists, uint256 polygonChainId, address ctf, bytes32 conditionId, uint256 outcomeSlotCount);

    /// @notice Returns true once a settlement has been resolved by the callback.
    /// @dev NativeOracle callback execution and progress advancement are atomic.
    function isSettlementObserved(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (bool observed);

    /// @notice Returns the canonical state derived from the mirrored Polymarket CTF resolution.
    /// @dev recordedAt is audit metadata only and must not affect market finalization.
    function getSettlementObservation(
        uint256 mirrorId,
        bytes32 conditionId
    )
        external
        view
        returns (
            ObservationStatus status,
            uint8 winningSlot,
            uint128 nonce,
            uint64 recordedAt,
            bytes32 txHash,
            uint256 logIndex
        );

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
