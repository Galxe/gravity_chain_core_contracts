// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IGBridgeSender
/// @author Gravity Team
/// @notice Interface for the GBridgeSender contract deployed on Ethereum
/// @dev Locks G tokens (ERC20) on Ethereum and sends bridge message via GravityPortal.
///      Works with GBridgeReceiver on Gravity to mint native G tokens.
///      The contract is Ownable2Step and Pausable; `pause()` halts new bridge deposits.
///      Emergency withdrawal of locked G is gated by a 7-day timelock
///      (request -> wait -> execute, with a single in-flight request).
interface IGBridgeSender {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when G tokens are locked for bridging
    /// @param from The address that locked the tokens
    /// @param recipient The recipient address on Gravity
    /// @param amount The amount of tokens locked
    /// @param nonce The portal nonce for this bridge operation
    event TokensLocked(address indexed from, address indexed recipient, uint256 amount, uint128 indexed nonce);

    /// @notice Emitted when an emergency withdrawal is requested (starts the timelock)
    /// @param recipient The address that will receive the tokens on execution
    /// @param amount The amount of G tokens to withdraw on execution
    /// @param executableAt The timestamp at/after which the request can be executed
    event EmergencyWithdrawRequested(address indexed recipient, uint256 amount, uint256 executableAt);

    /// @notice Emitted when a pending emergency withdrawal request is cancelled
    event EmergencyWithdrawCancelled();

    /// @notice Emitted when a timelocked emergency withdrawal of G tokens is executed
    /// @param recipient The address receiving the tokens
    /// @param amount The amount of tokens withdrawn
    event EmergencyWithdraw(address indexed recipient, uint256 amount);

    /// @notice Emitted when stuck (non-G) ERC20 tokens are recovered
    /// @param token The ERC20 token address
    /// @param recipient The address receiving the tokens
    /// @param amount The amount of tokens recovered
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Cannot use zero address
    error ZeroAddress();

    /// @notice Cannot bridge zero amount
    error ZeroAmount();

    /// @notice Cannot bridge to zero address
    error ZeroRecipient();

    /// @notice `recoverERC20` cannot move the G token — use the timelocked emergency path
    error CannotRecoverGToken();

    /// @notice An emergency withdrawal request is already in flight (only one at a time)
    error WithdrawalAlreadyPending();

    /// @notice No emergency withdrawal request is currently pending
    error NoWithdrawalPending();

    /// @notice The emergency withdrawal timelock has not elapsed yet
    /// @param executableAt The timestamp at/after which execution is allowed
    /// @param currentTime The current block timestamp
    error TimelockNotElapsed(uint256 executableAt, uint256 currentTime);

    // ========================================================================
    // BRIDGE FUNCTIONS
    // ========================================================================

    /// @notice Lock G tokens and bridge to Gravity
    /// @dev Caller must approve this contract to spend G tokens first.
    ///      ETH must be sent to cover the portal fee.
    ///      Message format: abi.encode(amount, recipient).
    ///      Reverts when the contract is paused.
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity chain
    /// @return messageNonce The portal nonce assigned to this bridge operation
    function bridgeToGravity(
        uint256 amount,
        address recipient
    ) external payable returns (uint128 messageNonce);

    /// @notice Lock G tokens and bridge to Gravity using ERC20Permit
    /// @dev Uses permit to approve and transfer in one transaction.
    ///      ETH must be sent to cover the portal fee.
    ///      Message format: abi.encode(amount, recipient).
    ///      Reverts when the contract is paused (before consuming the permit).
    /// @param amount Amount of G tokens to bridge
    /// @param recipient Recipient address on Gravity chain
    /// @param deadline The deadline timestamp for the permit signature
    /// @param v The recovery byte of the signature
    /// @param r Half of the ECDSA signature pair
    /// @param s Half of the ECDSA signature pair
    /// @return messageNonce The portal nonce assigned to this bridge operation
    function bridgeToGravityWithPermit(
        uint256 amount,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (uint128 messageNonce);

    // ========================================================================
    // PAUSE (Owner Only)
    // ========================================================================

    /// @notice Pause the contract — halts new bridge deposits
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

    // ========================================================================
    // EMERGENCY WITHDRAW — 7-DAY TIMELOCK (Owner Only)
    // ========================================================================

    /// @notice Start the timelock for an emergency withdrawal of locked G tokens
    /// @dev Only one request may be in flight at a time. The request becomes
    ///      executable TIMELOCK_DELAY seconds later, unless cancelled first.
    /// @param recipient Address that will receive the G tokens on execution
    /// @param amount Amount of G tokens to withdraw on execution
    function requestEmergencyWithdraw(
        address recipient,
        uint256 amount
    ) external;

    /// @notice Cancel the pending emergency withdrawal request
    function cancelEmergencyWithdraw() external;

    /// @notice Execute the pending emergency withdrawal once the timelock has elapsed
    /// @dev Transfers the requested amount of G tokens to the requested recipient.
    function executeEmergencyWithdraw() external;

    /// @notice Recover arbitrary ERC20 tokens accidentally sent to this contract
    /// @dev Only callable by the contract owner. Reverts for the G token —
    ///      G can only leave via the timelocked emergency withdrawal path.
    /// @param token The ERC20 token address to recover (must not be the G token)
    /// @param recipient Address to receive the tokens
    /// @param amount Amount of tokens to recover
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the G token contract address
    /// @return The G token (ERC20) address
    function gToken() external view returns (address);

    /// @notice Get the GravityPortal contract address
    /// @return The GravityPortal address
    function gravityPortal() external view returns (address);

    /// @notice The emergency-withdrawal timelock delay, in seconds
    /// @return The delay (7 days)
    function TIMELOCK_DELAY() external view returns (uint256);

    /// @notice Recipient of the pending emergency withdrawal request (zero if none)
    /// @return The pending recipient address
    function pendingWithdrawRecipient() external view returns (address);

    /// @notice Amount of the pending emergency withdrawal request (zero if none)
    /// @return The pending amount
    function pendingWithdrawAmount() external view returns (uint256);

    /// @notice Timestamp at/after which the pending request can be executed (zero if none)
    /// @return The executable-at timestamp
    function pendingWithdrawExecutableAt() external view returns (uint256);

    /// @notice Calculate the fee required for bridging
    /// @dev Delegates to GravityPortal.calculateFee with the encoded message length
    /// @param amount The amount to bridge (used to calculate message length)
    /// @param recipient The recipient address (used to calculate message length)
    /// @return requiredFee The required fee in ETH
    function calculateBridgeFee(
        uint256 amount,
        address recipient
    ) external view returns (uint256 requiredFee);
}
