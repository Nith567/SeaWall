// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PricingEngine } from "../../contracts/core/PricingEngine.sol";
import { NormalDist } from "../../contracts/libs/NormalDist.sol";

contract NormalDistHarness {
    function cdf(int256 x) external pure returns (uint256) {
        return NormalDist.cdf(x);
    }
}

contract PricingEngineTest is Test {
    uint256 internal constant WAD = 1e18;

    PricingEngine internal engine;
    NormalDistHarness internal normal;

    function setUp() public {
        engine = new PricingEngine();
        normal = new NormalDistHarness();
        vm.warp(1_700_000_000);
    }

    // ---------------------------------------------------------------------
    // Normal CDF
    // ---------------------------------------------------------------------

    function test_cdfKnownValues() public view {
        assertApproxEqAbs(normal.cdf(0), 0.5e18, 1e11, "N(0)");
        assertApproxEqAbs(normal.cdf(1e18), 0.8413447460685429e18, 1e11, "N(1)");
        assertApproxEqAbs(normal.cdf(1.96e18), 0.9750021048517796e18, 1e11, "N(1.96)");
        assertApproxEqAbs(normal.cdf(-1.96e18), 0.0249978951482204e18, 1e11, "N(-1.96)");
        assertApproxEqAbs(normal.cdf(-3e18), 0.0013498980316301e18, 1e11, "N(-3)");
        assertApproxEqAbs(normal.cdf(2.5e18), 0.9937903346742238e18, 1e11, "N(2.5)");
        assertApproxEqAbs(normal.cdf(8e18), 1e18, 1e11, "N(8)");
        assertApproxEqAbs(normal.cdf(-8e18), 0, 1e11, "N(-8)");
    }

    function testFuzz_cdfIsProbability(int256 x) public view {
        x = bound(x, -20e18, 20e18);
        uint256 p = normal.cdf(x);
        assertLe(p, WAD);
        assertApproxEqAbs(p + normal.cdf(-x), WAD, 1e11, "symmetry");
    }

    function testFuzz_cdfMonotonic(int256 a, int256 b) public view {
        a = bound(a, -10e18, 10e18);
        b = bound(b, -10e18, 10e18);
        if (a > b) (a, b) = (b, a);
        assertLe(normal.cdf(a), normal.cdf(b));
    }

    // ---------------------------------------------------------------------
    // Black-Scholes quotes
    // ---------------------------------------------------------------------

    function _expiry() internal view returns (uint256) {
        return block.timestamp + 30 days;
    }

    function test_quotePremiumReference() public view {
        uint256 premium = engine.quotePremium(3000e18, 2500e18, 4e18, _expiry(), 0.6e18, 0.05e18);
        assertApproxEqRel(premium, 132.89980342545186e18, 1e13, "reference put");
    }

    function test_quotePremiumAtMatchesView() public view {
        uint256 a = engine.quotePremium(3000e18, 2500e18, 4e18, block.timestamp + 30 days, 0.6e18, 0.05e18);
        uint256 b =
            engine.quotePremiumAt(3000e18, 2500e18, 4e18, block.timestamp + 30 days, 0.6e18, 0.05e18, block.timestamp);
        assertEq(a, b);
    }

    function test_quotePremiumAtm() public view {
        uint256 premium = engine.quotePremium(3000e18, 3000e18, 4e18, _expiry(), 0.6e18, 0.05e18);
        assertApproxEqRel(premium, 796.41306e18, 1e13, "atm put");
    }

    function test_quotePremiumDeepOtm() public view {
        uint256 premium = engine.quotePremium(3000e18, 1000e18, 4e18, _expiry(), 0.6e18, 0.05e18);
        assertLt(premium, 1e12, "deep otm put is ~0");
    }

    function test_quotePremiumDeepItm() public view {
        uint256 premium = engine.quotePremium(1000e18, 3000e18, 4e18, _expiry(), 0.6e18, 0.05e18);
        assertApproxEqRel(premium, 7950.786124e18, 1e13, "deep itm put");
    }

    function test_quotePremiumOneYearLowVol() public view {
        uint256 premium = engine.quotePremium(3000e18, 2500e18, 4e18, block.timestamp + 365 days, 0.2e18, 0.05e18);
        assertApproxEqRel(premium, 129.19864e18, 1e13, "1y 20vol put");
    }

    function test_quotePremiumShortTenor() public view {
        // Deep-OTM short-dated quotes suffer from cancellation between the two CDF terms.
        // The A&S approximation error is amplified in relative terms but stays ~1e-5 USD absolute.
        uint256 premium = engine.quotePremium(3000e18, 2500e18, 4e18, block.timestamp + 1 days, 0.9e18, 0.05e18);
        assertApproxEqAbs(premium, 0.00642e18, 1e14, "1d 90vol put");
    }

    function test_quotePremiumRoundsUpInFavourOfPool() public view {
        // The total premium is ceil(per-unit * quantity / 1e18).
        uint256 perUnit = engine.quotePremium(3000e18, 2500e18, 1e18, _expiry(), 0.6e18, 0.05e18);
        uint256 tiny = engine.quotePremium(3000e18, 2500e18, 1, _expiry(), 0.6e18, 0.05e18);
        assertGe(tiny, perUnit / 1e18, "ceil rounding lower bound");
        assertLe(tiny, perUnit / 1e18 + 1, "ceil rounding upper bound");
        assertGt(tiny, 0, "positive premium");
    }

    function test_quotePremiumZeroRate() public view {
        uint256 premium = engine.quotePremium(3000e18, 2500e18, 4e18, _expiry(), 0.6e18, 0);
        assertGt(premium, 0);
    }

    function test_quotePremiumTwoHourAtm() public view {
        // Short-tenor ATM puts amplify the CDF error via cancellation; tolerance is 1 cent.
        uint256 premium = engine.quotePremium(3000e18, 3000e18, 4e18, block.timestamp + 2 hours, 0.6e18, 0.05e18);
        assertApproxEqAbs(premium, 43.332722e18, 1e16, "2h atm put");
    }

    function test_quotePremiumOneDayAtm() public view {
        uint256 premium = engine.quotePremium(3000e18, 3000e18, 4e18, block.timestamp + 1 days, 0.6e18, 0.05e18);
        assertApproxEqAbs(premium, 149.510565e18, 1e16, "24h atm put");
    }

    function test_quotePremiumTwoDayAtm() public view {
        uint256 premium = engine.quotePremium(3000e18, 3000e18, 4e18, block.timestamp + 2 days, 0.6e18, 0.05e18);
        assertApproxEqAbs(premium, 210.937273e18, 1e16, "48h atm put");
    }

    function test_quotePremiumRevertsExpiryInPast() public {
        vm.expectRevert(
            abi.encodeWithSelector(PricingEngine.PricingExpiryNotInFuture.selector, block.timestamp, block.timestamp)
        );
        engine.quotePremium(3000e18, 2500e18, 4e18, block.timestamp, 0.6e18, 0.05e18);
    }

    function test_quotePremiumRevertsZeroStrike() public {
        vm.expectRevert(PricingEngine.PricingZeroStrike.selector);
        engine.quotePremium(3000e18, 0, 4e18, _expiry(), 0.6e18, 0.05e18);
    }

    function test_quotePremiumRevertsZeroQuantity() public {
        vm.expectRevert(PricingEngine.PricingZeroQuantity.selector);
        engine.quotePremium(3000e18, 2500e18, 0, _expiry(), 0.6e18, 0.05e18);
    }

    function test_quotePremiumRevertsZeroVolatility() public {
        vm.expectRevert(abi.encodeWithSelector(PricingEngine.PricingInvalidVolatility.selector, 0));
        engine.quotePremium(3000e18, 2500e18, 4e18, _expiry(), 0, 0.05e18);
    }

    function test_quotePremiumRevertsHugeVolatility() public {
        vm.expectRevert(abi.encodeWithSelector(PricingEngine.PricingInvalidVolatility.selector, 6e18));
        engine.quotePremium(3000e18, 2500e18, 4e18, _expiry(), 6e18, 0.05e18);
    }

    function test_quotePremiumRevertsZeroSpot() public {
        vm.expectRevert(PricingEngine.PricingZeroSpot.selector);
        engine.quotePremium(0, 2500e18, 4e18, _expiry(), 0.6e18, 0.05e18);
    }

    function test_quotePremiumRevertsTenorTooLong() public {
        vm.expectRevert(abi.encodeWithSelector(PricingEngine.PricingTenorTooLong.selector, 6 * 365 days, 5 * 365 days));
        engine.quotePremium(3000e18, 2500e18, 4e18, block.timestamp + 6 * 365 days, 0.6e18, 0.05e18);
    }

    function testFuzz_quotePremiumMonotonicInSpot(uint256 spotA, uint256 spotB) public view {
        spotA = bound(spotA, 1e18, 100_000e18);
        spotB = bound(spotB, 1e18, 100_000e18);
        uint256 pa = engine.quotePremium(spotA, 2500e18, 4e18, _expiry(), 0.6e18, 0.05e18);
        uint256 pb = engine.quotePremium(spotB, 2500e18, 4e18, _expiry(), 0.6e18, 0.05e18);
        if (spotA > spotB) assertLe(pa, pb, "put decreases with spot");
        else assertGe(pa, pb, "put decreases with spot");
    }

    // ---------------------------------------------------------------------
    // Payout math (settlement currency units, e.g. USDC 6dp)
    // ---------------------------------------------------------------------

    function test_maximumPayout() public view {
        assertEq(engine.maximumPayout(2500e6, 4e18), 10_000e6);
    }

    function test_intrinsicValue() public view {
        assertEq(engine.intrinsicValue(2500e6, 2000e6), 500e6);
        assertEq(engine.intrinsicValue(2500e6, 2500e6), 0);
        assertEq(engine.intrinsicValue(2500e6, 3000e6), 0);
    }

    function test_putPayout() public view {
        assertEq(engine.putPayout(2500e6, 2000e6, 4e18), 2000e6);
        assertEq(engine.putPayout(2500e6, 3000e6, 4e18), 0);
        assertEq(engine.putPayout(2500e6, 0, 4e18), 10_000e6);
    }

    function testFuzz_payoutNeverExceedsMaximum(uint256 strike, uint256 settlement, uint256 quantity) public view {
        strike = bound(strike, 1, 1e15);
        settlement = bound(settlement, 0, 1e15);
        quantity = bound(quantity, 1, 1e30);
        assertLe(
            engine.putPayout(strike, settlement, quantity),
            engine.maximumPayout(strike, quantity),
            "payout <= maximum payout"
        );
    }
}
