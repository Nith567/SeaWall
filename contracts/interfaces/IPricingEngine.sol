// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Deterministic option pricing surface.
interface IPricingEngine {
    /// @notice Black-Scholes quote for a European put. All amounts 1e18 fixed point.
    function quotePremium(
        uint256 spot,
        uint256 strike,
        uint256 quantity,
        uint256 expiry,
        uint256 volatility,
        uint256 riskFreeRate
    )
        external
        view
        returns (uint256 premiumWad);

    /// @notice Maximum liability: strike * quantity / 1e18 (collateral token units, e.g. USDC 6dp).
    function maximumPayout(uint256 strike, uint256 quantity) external pure returns (uint256);

    /// @notice Intrinsic value at settlement: max(strike - settlementPrice, 0).
    function intrinsicValue(uint256 strike, uint256 settlementPrice) external pure returns (uint256);

    /// @notice Cash payout at settlement: max(strike - settlementPrice, 0) * quantity / 1e18.
    function putPayout(uint256 strike, uint256 settlementPrice, uint256 quantity) external pure returns (uint256);
}
