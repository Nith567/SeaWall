// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Lifecycle status of an option position.
/// @dev Valid transitions:
///      NONE -> ACTIVE -> EXERCISED -> SETTLED
///                    \-> SETTLED  (auto-settlement of an ITM position after expiry)
///                    \-> EXPIRED  (OTM at expiry, or exercise window closed)
///      Reverse transitions are impossible.
enum OptionStatus {
    NONE,
    ACTIVE,
    EXERCISED,
    SETTLED,
    EXPIRED
}

/// @notice A live ETH put position.
/// @param id Position id (1-indexed).
/// @param buyer Holder of the put (the only address allowed to exercise).
/// @param pool Collateral pool id (the Aqua strategy hash of the pool's buy order).
/// @param notional Maximum payout in collateral token base units (e.g. USDC 6dp).
/// @param quantity Underlying amount in 1e18 (ETH wei).
/// @param strike Strike price in collateral token base units per 1 ETH (e.g. USDC 6dp).
/// @param expiry Unix timestamp of the European expiry.
/// @param premium Premium paid, in collateral token base units.
/// @param settlementPrice Settlement price recorded at exercise/settle/expire.
/// @param payout Final cash payout, in collateral token base units.
/// @param status Lifecycle status.
struct OptionPosition {
    uint256 id;
    address buyer;
    bytes32 pool;
    uint256 notional;
    uint256 quantity;
    uint256 strike;
    uint256 expiry;
    uint256 premium;
    uint256 settlementPrice;
    uint256 payout;
    OptionStatus status;
}

/// @notice An option that has been opened (collateral reserved, premium quoted) but not yet paid for.
/// @dev `OPTION_OPEN` stages a pending option; `OPTION_BUY` converts it into an `OptionPosition`
///      only after the premium has been paid in the same atomic SwapVM execution.
struct PendingOption {
    bytes32 pool;
    address buyer;
    uint256 strike;
    uint256 quantity;
    uint256 notional;
    uint256 expiry;
    uint256 premium;
    uint256 createdAt;
}

/// @notice Collateral accounting and risk configuration of a liquidity pool.
/// @param maker The LP whose Aqua balances back the pool.
/// @param totalCollateral Collateral currently made available through Aqua (cached, synced from Aqua).
/// @param reservedLiability Sum of maximum payouts of all live options.
/// @param premiumEarned Cumulative premium received.
/// @param payoutsPaid Cumulative payouts paid.
/// @param maxNotionalPerOption Risk limit: maximum notional for a single option.
/// @param maxTenor Risk limit: maximum time to expiry.
/// @param active Whether the pool is registered.
struct Pool {
    address maker;
    uint256 totalCollateral;
    uint256 reservedLiability;
    uint256 premiumEarned;
    uint256 payoutsPaid;
    uint256 maxNotionalPerOption;
    uint256 maxTenor;
    bool active;
}

/// @notice Live pool snapshot for the frontend: cached accounting plus the real Aqua balance.
struct PoolState {
    address maker;
    uint256 totalCollateral;
    uint256 reservedLiability;
    uint256 availableCollateral;
    uint256 premiumEarned;
    uint256 payoutsPaid;
    uint256 maxNotionalPerOption;
    uint256 maxTenor;
    bool active;
}
