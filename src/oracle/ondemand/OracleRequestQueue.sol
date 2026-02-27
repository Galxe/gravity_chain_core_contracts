// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IOracleRequestQueue } from "./IOracleRequestQueue.sol";
import { IOnDemandOracleTaskConfig } from "./IOnDemandOracleTaskConfig.sol";
import { SystemAddresses } from "../../foundation/SystemAddresses.sol";
import { requireAllowed } from "../../foundation/SystemAccessControl.sol";
import { Errors } from "../../foundation/Errors.sol";

/// @title OracleRequestQueue
/// @author Gravity Team
/// @notice Accepts user-initiated on-demand oracle requests with fee payment
/// @dev Validators monitor this contract to fulfill requests.
///      Fees are held until fulfillment, then sent to treasury.
///      Unfulfilled requests can be refunded after expiration.
///
///      NOTE ON TIMESTAMPS: This contract intentionally uses `block.timestamp` (seconds) rather than
///      the Gravity system's microsecond `Timestamp` contract. This is because on-demand oracle requests
///      operate on EVM block boundaries, and expiration/grace periods are denominated in seconds.
///      All timestamp fields (requestedAt, expiresAt, FULFILLMENT_GRACE_PERIOD) are in seconds.
contract OracleRequestQueue is IOracleRequestQueue {
    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Source type/id is not supported
    error UnsupportedSourceType(uint32 sourceType, uint256 sourceId);

    /// @notice Insufficient fee provided
    error InsufficientFee(uint256 required, uint256 provided);

    /// @notice Request not found
    error RequestNotFound(uint256 requestId);

    /// @notice Request already fulfilled
    error AlreadyFulfilled(uint256 requestId);

    /// @notice Request already refunded
    error AlreadyRefunded(uint256 requestId);

    /// @notice Request not expired yet
    error NotExpired(uint256 requestId, uint64 expiresAt, uint64 currentTime);

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Transfer failed
    error TransferFailed();

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Oracle requests: requestId -> OracleRequest
    mapping(uint256 => OracleRequest) private _requests;

    /// @notice Next request ID to be assigned
    uint256 private _nextRequestId;

    /// @notice Fee per source type in wei
    mapping(uint32 => uint256) private _fees;

    /// @notice Expiration duration per source type in seconds (block.timestamp units, NOT microseconds)
    mapping(uint32 => uint64) private _expirationDurations;

    /// @notice Treasury address for fee collection
    address private _treasury;

    /// @notice Reference to OnDemandOracleTaskConfig contract
    address private _taskConfig;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Initialize the request queue
    /// @param taskConfigAddr The OnDemandOracleTaskConfig contract address
    /// @param treasuryAddr The treasury address for fee collection
    constructor(
        address taskConfigAddr,
        address treasuryAddr
    ) {
        if (taskConfigAddr == address(0) || treasuryAddr == address(0)) {
            revert ZeroAddress();
        }
        _taskConfig = taskConfigAddr;
        _treasury = treasuryAddr;
        _nextRequestId = 1; // Start from 1, 0 means not found
    }

    // ========================================================================
    // REQUEST SUBMISSION
    // ========================================================================

    /// @inheritdoc IOracleRequestQueue
    function request(
        uint32 sourceType,
        uint256 sourceId,
        bytes calldata requestData
    ) external payable returns (uint256 requestId) {
        // Validate source type/id is supported
        if (!IOnDemandOracleTaskConfig(_taskConfig).isSupported(sourceType, sourceId)) {
            revert UnsupportedSourceType(sourceType, sourceId);
        }

        // Validate fee
        uint256 requiredFee = _fees[sourceType];
        if (msg.value < requiredFee) {
            revert InsufficientFee(requiredFee, msg.value);
        }

        // Calculate expiration (using block.timestamp in seconds, NOT microseconds)
        uint64 duration = _expirationDurations[sourceType];
        uint64 expiresAt = uint64(block.timestamp) + duration;

        // Assign request ID
        requestId = _nextRequestId++;

        // Store request
        _requests[requestId] = OracleRequest({
            sourceType: sourceType,
            sourceId: sourceId,
            requester: msg.sender,
            requestData: requestData,
            fee: msg.value,
            requestedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            fulfilled: false,
            refunded: false
        });

        emit RequestSubmitted(requestId, sourceType, sourceId, msg.sender, requestData, msg.value, expiresAt);
    }

    // ========================================================================
    // FULFILLMENT (System Caller Only)
    // ========================================================================

    /// @inheritdoc IOracleRequestQueue
    function markFulfilled(
        uint256 requestId
    ) external {
        requireAllowed(SystemAddresses.SYSTEM_CALLER);

        OracleRequest storage req = _requests[requestId];

        // Validate request exists
        if (req.requester == address(0)) {
            revert RequestNotFound(requestId);
        }

        // Validate not already fulfilled or refunded
        if (req.fulfilled) {
            revert AlreadyFulfilled(requestId);
        }
        if (req.refunded) {
            revert AlreadyRefunded(requestId);
        }

        // Mark as fulfilled (CEI pattern)
        req.fulfilled = true;

        // Transfer fee to treasury
        uint256 feeAmount = req.fee;
        if (feeAmount > 0) {
            (bool success,) = _treasury.call{ value: feeAmount }("");
            if (!success) {
                revert TransferFailed();
            }
        }

        emit RequestFulfilled(requestId);
    }

    // ========================================================================
    // REFUNDS
    // ========================================================================

    /// @inheritdoc IOracleRequestQueue
    function refund(
        uint256 requestId
    ) external {
        OracleRequest storage req = _requests[requestId];

        // Validate request exists
        if (req.requester == address(0)) {
            revert RequestNotFound(requestId);
        }

        // Validate not already fulfilled or refunded
        if (req.fulfilled) {
            revert AlreadyFulfilled(requestId);
        }
        if (req.refunded) {
            revert AlreadyRefunded(requestId);
        }

        // Validate expired
        if (block.timestamp < req.expiresAt) {
            revert NotExpired(requestId, req.expiresAt, uint64(block.timestamp));
        }

        // Mark as refunded (CEI pattern)
        req.refunded = true;

        // Transfer fee back to requester
        uint256 refundAmount = req.fee;
        address requester = req.requester;

        if (refundAmount > 0) {
            (bool success,) = requester.call{ value: refundAmount }("");
            if (!success) {
                revert TransferFailed();
            }
        }

        emit RequestRefunded(requestId, requester, refundAmount);
    }

    // ========================================================================
    // CONFIGURATION (Governance Only)
    // ========================================================================

    /// @inheritdoc IOracleRequestQueue
    function setFee(
        uint32 sourceType,
        uint256 fee
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        uint256 oldFee = _fees[sourceType];
        _fees[sourceType] = fee;

        emit FeeUpdated(sourceType, oldFee, fee);
    }

    /// @inheritdoc IOracleRequestQueue
    function setExpiration(
        uint32 sourceType,
        uint64 duration
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        uint64 oldDuration = _expirationDurations[sourceType];
        _expirationDurations[sourceType] = duration;

        emit ExpirationUpdated(sourceType, oldDuration, duration);
    }

    /// @inheritdoc IOracleRequestQueue
    function setTreasury(
        address newTreasury
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        if (newTreasury == address(0)) {
            revert ZeroAddress();
        }

        address oldTreasury = _treasury;
        _treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /// @inheritdoc IOracleRequestQueue
    function getRequest(
        uint256 requestId
    ) external view returns (OracleRequest memory) {
        return _requests[requestId];
    }

    /// @inheritdoc IOracleRequestQueue
    function isExpired(
        uint256 requestId
    ) external view returns (bool) {
        OracleRequest storage req = _requests[requestId];
        if (req.requester == address(0)) {
            return false;
        }
        return block.timestamp >= req.expiresAt;
    }

    /// @inheritdoc IOracleRequestQueue
    function getFee(
        uint32 sourceType
    ) external view returns (uint256) {
        return _fees[sourceType];
    }

    /// @inheritdoc IOracleRequestQueue
    function getExpiration(
        uint32 sourceType
    ) external view returns (uint64) {
        return _expirationDurations[sourceType];
    }

    /// @inheritdoc IOracleRequestQueue
    function treasury() external view returns (address) {
        return _treasury;
    }

    /// @inheritdoc IOracleRequestQueue
    function taskConfig() external view returns (address) {
        return _taskConfig;
    }

    /// @inheritdoc IOracleRequestQueue
    function nextRequestId() external view returns (uint256) {
        return _nextRequestId;
    }
}

