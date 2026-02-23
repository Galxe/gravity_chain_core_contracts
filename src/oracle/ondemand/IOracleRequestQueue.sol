// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IOracleRequestQueue
/// @author Gravity Team
/// @notice Interface for the On-Demand Oracle Request Queue contract
/// @dev Accepts user-initiated oracle requests with fee payment.
///      Validators monitor this contract to fulfill requests.
///      Unfulfilled requests can be refunded after expiration.
interface IOracleRequestQueue {
    // ========================================================================
    // DATA STRUCTURES
    // ========================================================================

    /// @notice An on-demand oracle request
    struct OracleRequest {
        /// @notice The source type for this request
        uint32 sourceType;
        /// @notice The source identifier for this request
        uint256 sourceId;
        /// @notice Address that submitted the request
        address requester;
        /// @notice Request parameters (e.g., stock ticker for price feeds)
        bytes requestData;
        /// @notice Fee paid for this request
        uint256 fee;
        /// @notice Timestamp when the request was submitted (block.timestamp in seconds, NOT microseconds)
        uint64 requestedAt;
        /// @notice Timestamp when the request expires (block.timestamp in seconds, NOT microseconds)
        uint64 expiresAt;
        /// @notice Whether the request has been fulfilled
        bool fulfilled;
        /// @notice Whether the request has been refunded
        bool refunded;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a request is submitted
    /// @param requestId The unique request ID
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param requester The address that submitted the request
    /// @param requestData The request parameters
    /// @param fee The fee paid
    /// @param expiresAt When the request expires
    event RequestSubmitted(
        uint256 indexed requestId,
        uint32 indexed sourceType,
        uint256 indexed sourceId,
        address requester,
        bytes requestData,
        uint256 fee,
        uint64 expiresAt
    );

    /// @notice Emitted when a request is fulfilled
    /// @param requestId The request ID that was fulfilled
    event RequestFulfilled(uint256 indexed requestId);

    /// @notice Emitted when a request is refunded
    /// @param requestId The request ID that was refunded
    /// @param requester The address that received the refund
    /// @param amount The refund amount
    event RequestRefunded(uint256 indexed requestId, address indexed requester, uint256 amount);

    /// @notice Emitted when the fee for a source type is updated
    /// @param sourceType The source type
    /// @param oldFee The previous fee
    /// @param newFee The new fee
    event FeeUpdated(uint32 indexed sourceType, uint256 oldFee, uint256 newFee);

    /// @notice Emitted when the expiration duration for a source type is updated
    /// @param sourceType The source type
    /// @param oldDuration The previous duration
    /// @param newDuration The new duration
    event ExpirationUpdated(uint32 indexed sourceType, uint64 oldDuration, uint64 newDuration);

    /// @notice Emitted when the treasury address is updated
    /// @param oldTreasury The previous treasury address
    /// @param newTreasury The new treasury address
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ========================================================================
    // REQUEST SUBMISSION
    // ========================================================================

    /// @notice Submit an on-demand oracle request
    /// @dev Requires payment of the fee for the source type.
    ///      The source type/id must be supported by OnDemandOracleTaskConfig.
    /// @param sourceType The source type
    /// @param sourceId The source identifier
    /// @param requestData The request parameters (e.g., stock ticker)
    /// @return requestId The unique ID assigned to this request
    function request(
        uint32 sourceType,
        uint256 sourceId,
        bytes calldata requestData
    ) external payable returns (uint256 requestId);

    // ========================================================================
    // FULFILLMENT (System Caller Only)
    // ========================================================================

    /// @notice Mark a request as fulfilled
    /// @dev Only callable by SYSTEM_CALLER. Transfers fee to treasury.
    /// @param requestId The request ID to mark as fulfilled
    function markFulfilled(
        uint256 requestId
    ) external;

    // ========================================================================
    // REFUNDS
    // ========================================================================

    /// @notice Refund an expired, unfulfilled request
    /// @dev Anyone can call this. Only works if request is expired and not fulfilled/refunded.
    /// @param requestId The request ID to refund
    function refund(
        uint256 requestId
    ) external;

    // ========================================================================
    // CONFIGURATION (Governance Only)
    // ========================================================================

    /// @notice Set the fee for a source type
    /// @dev Only callable by GOVERNANCE.
    /// @param sourceType The source type
    /// @param fee The fee amount in wei
    function setFee(
        uint32 sourceType,
        uint256 fee
    ) external;

    /// @notice Set the expiration duration for a source type
    /// @dev Only callable by GOVERNANCE.
    /// @param sourceType The source type
    /// @param duration The expiration duration in seconds
    function setExpiration(
        uint32 sourceType,
        uint64 duration
    ) external;

    /// @notice Set the treasury address
    /// @dev Only callable by GOVERNANCE.
    /// @param newTreasury The new treasury address
    function setTreasury(
        address newTreasury
    ) external;

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @notice Get a request by ID
    /// @param requestId The request ID
    /// @return The oracle request
    function getRequest(
        uint256 requestId
    ) external view returns (OracleRequest memory);

    /// @notice Check if a request is expired
    /// @param requestId The request ID
    /// @return True if the request is expired
    function isExpired(
        uint256 requestId
    ) external view returns (bool);

    /// @notice Get the fee for a source type
    /// @param sourceType The source type
    /// @return The fee amount in wei
    function getFee(
        uint32 sourceType
    ) external view returns (uint256);

    /// @notice Get the expiration duration for a source type
    /// @param sourceType The source type
    /// @return The expiration duration in seconds
    function getExpiration(
        uint32 sourceType
    ) external view returns (uint64);

    /// @notice Get the treasury address
    /// @return The treasury address
    function treasury() external view returns (address);

    /// @notice Get the task config contract address
    /// @return The OnDemandOracleTaskConfig contract address
    function taskConfig() external view returns (address);

    /// @notice Get the next request ID
    /// @return The next request ID that will be assigned
    function nextRequestId() external view returns (uint256);
}

