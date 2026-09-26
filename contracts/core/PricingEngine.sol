// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { NormalDist } from "../libs/NormalDist.sol";

/// @title PricingEngine
/// @notice Deterministic, on-chain European put option pricing engine.
///
/// @dev Model: Black-Scholes for a European put on a non-dividend paying asset.
///
///      ```
///      d1    = [ ln(S/K) + (r + sigma^2 / 2) * T ] / (sigma * sqrt(T))
///      d2    = d1 - sigma * sqrt(T)
///      Put   = K * exp(-rT) * N(-d2) - S * N(-d1)
///      Total = Put * Q
///      ```
///
///      Representation (all inputs and the output are 1e18 fixed point, "WAD"):
///      - `spot`          : quote currency per 1 underlying, WAD  (e.g. 3000e18 USDC/ETH)
///      - `strike`        : quote currency per 1 underlying, WAD  (e.g. 2500e18 USDC/ETH)
///      - `quantity`      : underlying amount, WAD               (e.g. 4e18 ETH)
///      - `expiry`        : unix timestamp, seconds
///      - `volatility`    : annualised, WAD                      (e.g. 0.6e18 = 60%)
///      - `riskFreeRate`  : annualised, WAD, non-negative        (e.g. 0.05e18 = 5%)
///      - return          : total premium in quote currency, WAD
///
///      Rounding: the premium is rounded UP (`Math.Rounding.Ceil`) so the protocol never
///      under-charges the buyer relative to the model. `intrinsic`/`payout` are rounded DOWN.
///
///      Numerical error: the normal CDF uses the A&S 26.2.17 approximation with |eps| < 7.5e-8
///      (see `NormalDist`). For a $3,000 spot and 4 ETH quantity the resulting premium error is
///      below 1e-4 USD. All intermediate math uses full-precision `mulDiv` and `lnWad`/`expWad`
///      from Solady (well-tested fixed point library), so no custom ln/exp/sqrt is implemented here.
///
///      The quote is a MODEL-BASED price. It is deterministic and manipulation resistant with
///      respect to the option lifecycle, but it is not a claim about the fair market premium.
contract PricingEngine {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    /// @dev Sanity bounds for the model parameters.
    uint256 public constant MAX_TENOR = 5 * YEAR;
    uint256 public constant MAX_VOLATILITY = 5e18; // 500%
    uint256 public constant MAX_RISK_FREE_RATE = 0.5e18; // 50%

    error PricingExpiryNotInFuture(uint256 expiry, uint256 timestamp);
    error PricingTenorTooLong(uint256 tenor, uint256 maxTenor);
    error PricingZeroStrike();
    error PricingZeroQuantity();
    error PricingZeroSpot();
    error PricingInvalidVolatility(uint256 volatility);
    error PricingInvalidRiskFreeRate(uint256 riskFreeRate);

    /// @notice Deterministic Black-Scholes quote for a European put.
    /// @return premiumWad Total premium (not per unit) in quote currency, WAD, rounded up.
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
        returns (uint256 premiumWad)
    {
        return _quotePremium(spot, strike, quantity, expiry, volatility, riskFreeRate, block.timestamp);
    }

    /// @notice Same quote with an explicit "now" timestamp, for deterministic testing.
    function quotePremiumAt(
        uint256 spot,
        uint256 strike,
        uint256 quantity,
        uint256 expiry,
        uint256 volatility,
        uint256 riskFreeRate,
        uint256 timestamp
    )
        external
        pure
        returns (uint256 premiumWad)
    {
        return _quotePremium(spot, strike, quantity, expiry, volatility, riskFreeRate, timestamp);
    }

    /// @notice Maximum liability of a put position: the payout if the underlying goes to zero.
    /// @dev `strike` and the result are in the settlement currency base units (e.g. USDC 6dp),
    ///      `quantity` is underlying in 1e18.
    function maximumPayout(uint256 strike, uint256 quantity) external pure returns (uint256) {
        return Math.mulDiv(strike, quantity, WAD);
    }

    /// @notice Intrinsic value of a put at settlement: max(strike - settlement, 0).
    /// @dev `strike` and `settlementPrice` must share the same decimals; result uses those decimals.
    function intrinsicValue(uint256 strike, uint256 settlementPrice) external pure returns (uint256) {
        return settlementPrice >= strike ? 0 : strike - settlementPrice;
    }

    /// @notice Cash payout of a put position at settlement.
    /// @dev `strike`/`settlementPrice` in settlement currency base units, `quantity` in 1e18.
    ///      Rounded down, which can only favour the collateral pool.
    function putPayout(uint256 strike, uint256 settlementPrice, uint256 quantity) external pure returns (uint256) {
        if (settlementPrice >= strike) return 0;
        return Math.mulDiv(strike - settlementPrice, quantity, WAD);
    }

    function _quotePremium(
        uint256 spot,
        uint256 strike,
        uint256 quantity,
        uint256 expiry,
        uint256 volatility,
        uint256 riskFreeRate,
        uint256 timestamp
    )
        internal
        pure
        returns (uint256 premiumWad)
    {
        if (spot == 0) revert PricingZeroSpot();
        if (strike == 0) revert PricingZeroStrike();
        if (quantity == 0) revert PricingZeroQuantity();
        if (volatility == 0 || volatility > MAX_VOLATILITY) revert PricingInvalidVolatility(volatility);
        if (riskFreeRate > MAX_RISK_FREE_RATE) revert PricingInvalidRiskFreeRate(riskFreeRate);
        if (expiry <= timestamp) revert PricingExpiryNotInFuture(expiry, timestamp);
        uint256 tenor = expiry - timestamp;
        if (tenor > MAX_TENOR) revert PricingTenorTooLong(tenor, MAX_TENOR);

        // T in years, WAD.
        uint256 tWad = Math.mulDiv(tenor, WAD, YEAR);

        // ln(S/K)
        int256 lnMoneyness = FixedPointMathLib.lnWad(int256(Math.mulDiv(spot, WAD, strike)));

        int256 sigma = int256(volatility);
        int256 sigmaSquared = (sigma * sigma) / int256(WAD);
        int256 drift = int256(riskFreeRate) + sigmaSquared / 2;

        // sqrt(T) in WAD: sqrt(T_wad * WAD)
        int256 sqrtT = int256(FixedPointMathLib.sqrt(tWad * WAD));

        // sigma * sqrt(T), WAD
        int256 volSqrtT = (sigma * sqrtT) / int256(WAD);
        if (volSqrtT == 0) revert PricingInvalidVolatility(volatility);

        // d1 = (ln(S/K) + (r + sigma^2/2) T) / (sigma sqrt(T))
        int256 d1 = ((lnMoneyness + (drift * int256(tWad)) / int256(WAD)) * int256(WAD)) / volSqrtT;
        int256 d2 = d1 - volSqrtT;

        // Discount factor exp(-rT), WAD.
        int256 discount = FixedPointMathLib.expWad(-((int256(riskFreeRate) * int256(tWad)) / int256(WAD)));

        uint256 nNegD1 = NormalDist.cdf(-d1);
        uint256 nNegD2 = NormalDist.cdf(-d2);

        // K * exp(-rT) * N(-d2)
        uint256 term1 = Math.mulDiv(Math.mulDiv(strike, uint256(discount), WAD), nNegD2, WAD);
        // S * N(-d1)
        uint256 term2 = Math.mulDiv(spot, nNegD1, WAD);

        uint256 putPerUnit = term1 > term2 ? term1 - term2 : 0;

        // Total premium, rounded up in favour of the collateral pool.
        premiumWad = Math.mulDiv(putPerUnit, quantity, WAD, Math.Rounding.Ceil);
    }
}
