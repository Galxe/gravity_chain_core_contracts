// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IPolymarketSettlementResolver
/// @notice Read interface for contracts consuming mirrored Polygon CTF settlements.
interface IPolymarketSettlementResolver {
    /// @notice Terminal classification of a canonical CTF payout vector.
    enum ObservationStatus {
        None,
        ResolvedWinner,
        ResolvedVoidable
    }

    /// @notice Return the immutable Polygon condition registered for a mirror.
    function getMirrorConfig(
        uint256 mirrorId
    )
        external
        view
        returns (bool exists, uint256 polygonChainId, address ctf, bytes32 conditionId, uint256 outcomeSlotCount);

    /// @notice Return true after the registered condition reaches a canonical terminal state.
    function isSettlementObserved(
        uint256 mirrorId,
        bytes32 conditionId
    ) external view returns (bool observed);

    /// @notice Return the terminal classification and source-event provenance.
    /// @dev `recordedAt` is Gravity audit metadata and never limits source finality.
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

    /// @notice Return canonical settlement metadata for auditing and integrations.
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
}
