// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @title NormalDist
/// @notice Fixed-point standard normal cumulative distribution function (CDF) in 1e18 WAD.
/// @dev Uses the Zelen & Severo rational approximation (Abramowitz & Stegun 26.2.17) of the
///      standard normal CDF, with a documented absolute error bound of |eps| < 7.5e-8 over the
///      whole real line. That is ~7.5e10 wei in WAD terms, well below any economically relevant
///      amount for an option premium quoted in 6-decimal USDC.
///
///      Precision / rounding notes:
///      - Input/output are 1e18 fixed point (WAD).
///      - `expWad` and the Horner polynomial each add < 1e-17 relative error, so the total error
///        is dominated by the 7.5e-8 approximation bound.
///      - |x| is clamped to 8 WAD before evaluation. For |x| > 8 the true CDF is within 6.2e-16
///        of 0 or 1, so clamping is safe and keeps every intermediate bounded.
library NormalDist {
    using FixedPointMathLib for int256;

    int256 internal constant WAD = 1e18;

    /// @dev Hart / A&S 26.2.17 coefficients, WAD.
    int256 private constant B1 = 0.31938153e18;
    int256 private constant B2 = -0.356563782e18;
    int256 private constant B3 = 1.781477937e18;
    int256 private constant B4 = -1.821255978e18;
    int256 private constant B5 = 1.330274429e18;

    /// @dev 1 / sqrt(2 * pi), WAD.
    int256 private constant INV_SQRT_2PI = 0.398942280401432678e18;

    /// @dev 0.2316419, WAD.
    int256 private constant P = 0.2316419e18;

    /// @notice Standard normal CDF, N(x), returned as an unsigned WAD in [0, 1e18].
    /// @param x Argument in WAD (may be negative).
    /// @return result N(x) in WAD.
    function cdf(int256 x) internal pure returns (uint256 result) {
        int256 ax = x < 0 ? -x : x;
        if (ax > 8 * WAD) ax = 8 * WAD;

        // t = 1 / (1 + p * ax)
        int256 t = (WAD * WAD) / (WAD + (P * ax) / WAD);

        // pdf = exp(-ax^2 / 2) / sqrt(2*pi)
        int256 ax2Half = (ax * ax) / WAD / 2;
        int256 pdf = FixedPointMathLib.expWad(-ax2Half);
        pdf = (pdf * INV_SQRT_2PI) / WAD;

        // poly = b1 t + b2 t^2 + b3 t^3 + b4 t^4 + b5 t^5 (Horner, from the tail)
        int256 poly = B5;
        poly = (poly * t) / WAD + B4;
        poly = (poly * t) / WAD + B3;
        poly = (poly * t) / WAD + B2;
        poly = (poly * t) / WAD + B1;
        poly = (poly * t) / WAD;

        int256 tail = (pdf * poly) / WAD;
        if (tail < 0) tail = 0;
        if (tail > WAD) tail = WAD;

        int256 cdfPositive = WAD - tail;
        result = uint256(x >= 0 ? cdfPositive : WAD - cdfPositive);
    }
}
