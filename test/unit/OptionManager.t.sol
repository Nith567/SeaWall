// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { PricingEngine } from "../../contracts/core/PricingEngine.sol";
import { CollateralManager } from "../../contracts/core/CollateralManager.sol";
import { OptionManager } from "../../contracts/core/OptionManager.sol";
import { MarketParams } from "../../contracts/oracle/MarketParams.sol";
import { OptionPosition, PendingOption, PoolState, OptionStatus } from "../../contracts/interfaces/OptionTypes.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockRouter } from "../mocks/MockRouter.sol";

contract OptionManagerTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ONE_USDC = 1e6;

    Aqua internal aqua;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    PricingEngine internal pricing;
    MarketParams internal params;
    MockOracle internal oracle;
    CollateralManager internal collateral;
    OptionManager internal manager;
    MockRouter internal router;

    address internal lp = address(0xB0B);
    address internal alice = address(0xA11CE);
    address internal keeper = address(0x4EE9);

    bytes32 internal poolId;
    uint256 internal expiry;

    uint256 internal constant COLLATERAL = 100_000e6;
    uint256 internal constant STRIKE = 2500e6;
    uint256 internal constant QUANTITY = 4e18;
    uint256 internal constant NOTIONAL = 10_000e6;

    function setUp() public {
        vm.warp(1_700_000_000);

        aqua = new Aqua();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        pricing = new PricingEngine();
        params = new MarketParams(address(this), 0.6e18, 0.05e18);
        oracle = new MockOracle();
        oracle.setSpot(3000e18);

        collateral = new CollateralManager(address(this));
        router = new MockRouter();
        manager = new OptionManager(
            address(router),
            address(aqua),
            address(usdc),
            address(collateral),
            address(pricing),
            address(params),
            address(oracle)
        );
        router.setManager(manager);
        collateral.setManager(address(manager));

        // LP makes collateral available through Aqua (real Aqua registry, no mock).
        bytes memory strategy = abi.encode("seawall-pool", lp);
        poolId = keccak256(strategy);
        vm.prank(lp);
        bytes32 shipped = aqua.ship(address(router), strategy, _tokens(), _balances(COLLATERAL));
        assertEq(shipped, poolId, "strategy hash");

        // Pool registration is permissionless: the caller becomes the maker.
        vm.prank(lp);
        manager.registerPool(poolId, 50_000e6, 90 days);

        expiry = block.timestamp + 30 days;
    }

    function _tokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
    }

    function _balances(uint256 usdcAmount) internal pure returns (uint256[] memory balances) {
        balances = new uint256[](2);
        balances[0] = usdcAmount;
        balances[1] = 0;
    }

    function _openDefault() internal returns (uint256 notional) {
        notional = router.open(poolId, lp, alice, STRIKE, QUANTITY, expiry);
    }

    function _buyDefault(uint256 premium) internal returns (uint256 positionId) {
        positionId = router.buy(poolId, alice, premium);
    }

    function _quotedPremium() internal view returns (uint256) {
        uint256 premiumWad =
            pricing.quotePremium(3000e18, STRIKE * 1e12, QUANTITY, expiry, params.volatility(), params.riskFreeRate());
        return (premiumWad + 1e12 - 1) / 1e12;
    }

    // ---------------------------------------------------------------------
    // OPEN
    // ---------------------------------------------------------------------

    function testOpenOption() public {
        uint256 notional = _openDefault();
        assertEq(notional, NOTIONAL, "notional");

        PendingOption memory pending = manager.getPending(poolId);
        assertEq(pending.buyer, alice);
        assertEq(pending.pool, poolId);
        assertEq(pending.strike, STRIKE);
        assertEq(pending.quantity, QUANTITY);
        assertEq(pending.notional, NOTIONAL);
        assertEq(pending.expiry, expiry);
        assertEq(pending.premium, _quotedPremium());

        PoolState memory state = manager.poolState(poolId);
        assertEq(state.totalCollateral, COLLATERAL);
        assertEq(state.reservedLiability, NOTIONAL);
        assertEq(state.availableCollateral, COLLATERAL - NOTIONAL);
    }

    function testPremiumCalculation() public {
        _openDefault();
        assertEq(manager.getPending(poolId).premium, _quotedPremium());
    }

    function testMaximumLiability() public {
        uint256 notional = _openDefault();
        assertEq(notional, pricing.maximumPayout(STRIKE, QUANTITY));
        assertEq(notional, 10_000e6);
    }

    function testOpenRevertsOnUnregisteredPool() public {
        bytes32 unknown = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(OptionManager.PoolNotRegistered.selector, unknown));
        router.open(unknown, lp, alice, STRIKE, QUANTITY, expiry);
    }

    function testOpenRevertsOnWrongMaker() public {
        vm.expectRevert(abi.encodeWithSelector(OptionManager.PoolMakerMismatch.selector, poolId, lp, address(0xDEAD)));
        router.open(poolId, address(0xDEAD), alice, STRIKE, QUANTITY, expiry);
    }

    function testOpenRevertsOnZeroBuyer() public {
        vm.expectRevert(OptionManager.ZeroBuyer.selector);
        router.open(poolId, lp, address(0), STRIKE, QUANTITY, expiry);
    }

    function testOpenRevertsOnZeroStrike() public {
        vm.expectRevert(OptionManager.InvalidOptionParams.selector);
        router.open(poolId, lp, alice, 0, QUANTITY, expiry);
    }

    function testOpenRevertsOnExpiryInPast() public {
        vm.expectRevert(
            abi.encodeWithSelector(OptionManager.ExpiryNotInFuture.selector, block.timestamp, block.timestamp)
        );
        router.open(poolId, lp, alice, STRIKE, QUANTITY, block.timestamp);
    }

    function testOpenRevertsOnTenorTooLong() public {
        uint256 tooLong = block.timestamp + 91 days;
        vm.expectRevert(abi.encodeWithSelector(OptionManager.TenorTooLong.selector, 91 days, 90 days));
        router.open(poolId, lp, alice, STRIKE, QUANTITY, tooLong);
    }

    function testOpenRevertsOnNotionalTooLarge() public {
        // 30 ETH * 2500 = 75k notional > 50k per-option limit.
        vm.expectRevert(abi.encodeWithSelector(OptionManager.NotionalTooLarge.selector, 75_000e6, 50_000e6));
        router.open(poolId, lp, alice, STRIKE, 30e18, expiry);
    }

    function testOpenRevertsOnInsufficientCollateral() public {
        // Raise the per-option limit so the collateral check is what fails.
        bytes memory strategy = abi.encode("big-pool-seed");
        bytes32 bigPool = keccak256(strategy);
        vm.prank(lp);
        aqua.ship(address(router), strategy, _tokens(), _balances(20_000e6));
        vm.prank(lp);
        manager.registerPool(bigPool, 100_000e6, 90 days);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralManager.CollateralInsufficient.selector, bigPool, 20_000e6, 0, 75_000e6)
        );
        router.open(bigPool, lp, alice, STRIKE, 30e18, expiry);
    }

    function testOpenRevertsOnDuplicatePending() public {
        _openDefault();
        vm.expectRevert(abi.encodeWithSelector(OptionManager.PendingAlreadyExists.selector, poolId));
        router.open(poolId, lp, alice, STRIKE, QUANTITY, expiry);
    }

    // ---------------------------------------------------------------------
    // BUY
    // ---------------------------------------------------------------------

    function testBuyOption() public {
        _openDefault();
        uint256 premium = _quotedPremium();
        uint256 positionId = _buyDefault(premium);

        assertEq(positionId, 1);
        OptionPosition memory position = manager.getPosition(positionId);
        assertEq(position.buyer, alice);
        assertEq(position.pool, poolId);
        assertEq(position.notional, NOTIONAL);
        assertEq(position.quantity, QUANTITY);
        assertEq(position.strike, STRIKE);
        assertEq(position.expiry, expiry);
        assertEq(position.premium, premium);
        assertEq(uint8(position.status), uint8(OptionStatus.ACTIVE));

        PendingOption memory pending = manager.getPending(poolId);
        assertEq(pending.createdAt, 0, "pending cleared");

        PoolState memory state = manager.poolState(poolId);
        assertEq(state.premiumEarned, premium);
        assertEq(state.reservedLiability, NOTIONAL);
        // Stored accounting includes the premium; the live Aqua balance only reflects it once the
        // SwapVM transfer phase pushes it (covered by the integration tests).
        assertEq(collateral.getPool(poolId).totalCollateral, COLLATERAL + premium);
    }

    function testBuyRevertsOnLowPremium() public {
        _openDefault();
        uint256 quoted = _quotedPremium();
        vm.expectRevert(abi.encodeWithSelector(OptionManager.PremiumTooLow.selector, quoted - 1, quoted));
        _buyDefault(quoted - 1);
    }

    function testBuyRevertsOnWrongBuyer() public {
        _openDefault();
        uint256 premium = _quotedPremium();
        vm.expectRevert(abi.encodeWithSelector(OptionManager.BuyerMismatch.selector, alice, keeper));
        router.buy(poolId, keeper, premium);
    }

    function testBuyRevertsWithoutPending() public {
        uint256 premium = _quotedPremium();
        vm.expectRevert(abi.encodeWithSelector(OptionManager.NoPendingOption.selector, poolId));
        _buyDefault(premium);
    }

    function testCancelPendingReleasesCollateral() public {
        _openDefault();
        vm.prank(alice);
        manager.cancelPending(poolId);
        PoolState memory state = manager.poolState(poolId);
        assertEq(state.reservedLiability, 0);
        assertEq(state.availableCollateral, COLLATERAL);
    }

    function testCancelPendingByStrangerReverts() public {
        _openDefault();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(OptionManager.CannotCancelPending.selector, poolId, keeper));
        manager.cancelPending(poolId);
    }

    // ---------------------------------------------------------------------
    // EXERCISE
    // ---------------------------------------------------------------------

    function _buyAndWarp(uint256 settlementPrice) internal returns (uint256 positionId) {
        _openDefault();
        positionId = _buyDefault(_quotedPremium());
        oracle.setSettlementPrice(expiry, settlementPrice);
        vm.warp(expiry + 1);
    }

    function testExercise() public {
        uint256 positionId = _buyAndWarp(2000e18);
        vm.prank(alice);
        router.exercise(positionId, alice);
        OptionPosition memory position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.EXERCISED));
        assertEq(position.settlementPrice, 2000e6);
    }

    function testExerciseRevertsBeforeExpiry() public {
        _openDefault();
        uint256 positionId = _buyDefault(_quotedPremium());
        vm.expectRevert(abi.encodeWithSelector(OptionManager.NotYetExpired.selector, expiry, block.timestamp));
        router.exercise(positionId, alice);
    }

    function testExerciseRevertsAfterWindow() public {
        uint256 positionId = _buyAndWarp(2000e18);
        vm.warp(expiry + manager.EXERCISE_WINDOW() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionManager.ExerciseWindowClosed.selector,
                positionId,
                expiry + manager.EXERCISE_WINDOW(),
                block.timestamp
            )
        );
        router.exercise(positionId, alice);
    }

    function testExerciseRevertsForNonBuyer() public {
        uint256 positionId = _buyAndWarp(2000e18);
        vm.expectRevert(abi.encodeWithSelector(OptionManager.UnauthorizedExercise.selector, positionId, keeper, alice));
        vm.prank(keeper);
        router.exercise(positionId, keeper);
    }

    function testExerciseRevertsOutOfTheMoney() public {
        uint256 positionId = _buyAndWarp(3000e18);
        vm.expectRevert(abi.encodeWithSelector(OptionManager.NotInTheMoney.selector, STRIKE, 3000e6));
        router.exercise(positionId, alice);
    }

    function testDoubleExerciseReverts() public {
        uint256 positionId = _buyAndWarp(2000e18);
        router.exercise(positionId, alice);
        vm.expectRevert(
            abi.encodeWithSelector(OptionManager.PositionNotActive.selector, positionId, OptionStatus.EXERCISED)
        );
        router.exercise(positionId, alice);
    }

    // ---------------------------------------------------------------------
    // SETTLE
    // ---------------------------------------------------------------------

    function testSettlement() public {
        uint256 positionId = _buyAndWarp(2000e18);
        uint256 premium = manager.getPosition(positionId).premium;
        router.exercise(positionId, alice);

        (address buyer, bytes32 pool, uint256 payout) = router.settle(positionId);
        assertEq(buyer, alice);
        assertEq(pool, poolId);
        assertEq(payout, 2000e6, "payout = (2500-2000)*4");

        OptionPosition memory position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.SETTLED));
        assertEq(position.payout, 2000e6);
        assertEq(position.settlementPrice, 2000e6);

        PoolState memory state = manager.poolState(poolId);
        assertEq(state.reservedLiability, 0, "liability released");
        assertEq(state.payoutsPaid, 2000e6);
        assertEq(state.premiumEarned, premium);
        // settle() re-syncs from the live Aqua balance; the mock harness never pushed the premium,
        // so the cached total tracks the shipped collateral minus the payout.
        assertEq(collateral.getPool(poolId).totalCollateral, COLLATERAL - 2000e6);
        assertEq(state.availableCollateral, COLLATERAL, "live balance unchanged in the mock harness");
    }

    function testAutoSettlementByKeeper() public {
        uint256 positionId = _buyAndWarp(2000e18);
        // No explicit exercise: anyone can settle an ITM position inside the window.
        (address buyer,, uint256 payout) = router.settle(positionId);
        assertEq(buyer, alice, "payout goes to buyer");
        assertEq(payout, 2000e6);
        assertEq(uint8(manager.getPosition(positionId).status), uint8(OptionStatus.SETTLED));
    }

    function testSettleRevertsBeforeExpiry() public {
        _openDefault();
        uint256 positionId = _buyDefault(_quotedPremium());
        vm.expectRevert(abi.encodeWithSelector(OptionManager.NotYetExpired.selector, expiry, block.timestamp));
        router.settle(positionId);
    }

    function testDoubleSettlementReverts() public {
        uint256 positionId = _buyAndWarp(2000e18);
        router.settle(positionId);
        vm.expectRevert(
            abi.encodeWithSelector(OptionManager.PositionNotSettleable.selector, positionId, OptionStatus.SETTLED)
        );
        router.settle(positionId);
    }

    function testSettleRevertsForExpiredPosition() public {
        uint256 positionId = _buyAndWarp(3000e18);
        router.expire(positionId);
        vm.expectRevert(
            abi.encodeWithSelector(OptionManager.PositionNotSettleable.selector, positionId, OptionStatus.EXPIRED)
        );
        router.settle(positionId);
    }

    // ---------------------------------------------------------------------
    // EXPIRE
    // ---------------------------------------------------------------------

    function testExpiry() public {
        uint256 positionId = _buyAndWarp(3000e18);
        uint256 premium = manager.getPosition(positionId).premium;
        router.expire(positionId);

        OptionPosition memory position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.EXPIRED));
        assertEq(position.payout, 0);
        assertEq(position.settlementPrice, 3000e6);

        PoolState memory state = manager.poolState(poolId);
        assertEq(state.reservedLiability, 0);
        assertEq(state.payoutsPaid, 0);
        assertEq(state.premiumEarned, premium, "LP keeps premium");
        assertEq(collateral.getPool(poolId).totalCollateral, COLLATERAL, "collateral intact after sync");
    }

    function testExpireRevertsItmInsideWindow() public {
        uint256 positionId = _buyAndWarp(2000e18);
        vm.expectRevert(abi.encodeWithSelector(OptionManager.NotExpirable.selector, positionId));
        router.expire(positionId);
    }

    function testExpireItmAfterWindow() public {
        uint256 positionId = _buyAndWarp(2000e18);
        vm.warp(expiry + manager.EXERCISE_WINDOW() + 1);
        router.expire(positionId);
        assertEq(uint8(manager.getPosition(positionId).status), uint8(OptionStatus.EXPIRED));
    }

    function testExpireRevertsBeforeExpiry() public {
        _openDefault();
        uint256 positionId = _buyDefault(_quotedPremium());
        vm.expectRevert(abi.encodeWithSelector(OptionManager.NotYetExpired.selector, expiry, block.timestamp));
        router.expire(positionId);
    }

    function testPutInTheMoney() public {
        uint256 positionId = _buyAndWarp(2000e18);
        router.exercise(positionId, alice);
        (,, uint256 payout) = router.settle(positionId);
        assertEq(payout, 2000e6, "intrinsic * quantity");
    }

    function testPutOutOfTheMoney() public {
        uint256 positionId = _buyAndWarp(3000e18);
        router.expire(positionId);
        assertEq(manager.getPosition(positionId).payout, 0);
    }

    function testUnauthorizedExerciseReverts() public {
        uint256 positionId = _buyAndWarp(2000e18);
        vm.expectRevert(abi.encodeWithSelector(OptionManager.UnauthorizedExercise.selector, positionId, keeper, alice));
        vm.prank(keeper);
        router.exercise(positionId, keeper);
    }

    function testInsufficientCollateralReverts() public {
        bytes memory strategy = abi.encode("small-pool-seed");
        bytes32 smallPool = keccak256(strategy);
        vm.prank(lp);
        aqua.ship(address(router), strategy, _tokens(), _balances(5_000e6));
        vm.prank(lp);
        manager.registerPool(smallPool, 50_000e6, 90 days);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralManager.CollateralInsufficient.selector, smallPool, 5_000e6, 0, 10_000e6)
        );
        router.open(smallPool, lp, alice, STRIKE, QUANTITY, expiry);
    }

    function testPricingEdgeCases() public {
        // Zero terms are rejected before the pricing engine is reached.
        vm.expectRevert(OptionManager.InvalidOptionParams.selector);
        router.open(poolId, lp, alice, 0, QUANTITY, expiry);

        vm.expectRevert(OptionManager.InvalidOptionParams.selector);
        router.open(poolId, lp, alice, STRIKE, 0, expiry);

        vm.expectRevert(
            abi.encodeWithSelector(OptionManager.ExpiryNotInFuture.selector, block.timestamp, block.timestamp)
        );
        router.open(poolId, lp, alice, STRIKE, QUANTITY, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(OptionManager.TenorTooLong.selector, 91 days, 90 days));
        router.open(poolId, lp, alice, STRIKE, QUANTITY, block.timestamp + 91 days);
    }

    function testShortTenorLifecycleTwoHours() public {
        uint256 shortExpiry = block.timestamp + 2 hours;
        uint256 notional = router.open(poolId, lp, alice, 3000e6, 4e18, shortExpiry);
        assertEq(notional, 12_000e6);

        uint256 premium = manager.getPending(poolId).premium;
        assertGt(premium, 0, "2h ATM premium is positive");
        uint256 positionId = router.buy(poolId, alice, premium);

        oracle.setSettlementPrice(shortExpiry, 2500e18);
        vm.warp(shortExpiry + 1);

        router.exercise(positionId, alice);
        (,, uint256 payout) = router.settle(positionId);
        assertEq(payout, 2000e6, "intrinsic * quantity");
        assertEq(uint8(manager.getPosition(positionId).status), uint8(OptionStatus.SETTLED));
    }

    function testShortTenorLifecycleTwoDays() public {
        uint256 shortExpiry = block.timestamp + 2 days;
        router.open(poolId, lp, alice, 2500e6, 4e18, shortExpiry);
        uint256 premium = manager.getPending(poolId).premium;
        uint256 positionId = router.buy(poolId, alice, premium);

        oracle.setSettlementPrice(shortExpiry, 2000e18);
        vm.warp(shortExpiry + 1);

        (,, uint256 payout) = router.settle(positionId);
        assertEq(payout, 2000e6);
    }

    // ---------------------------------------------------------------------
    // Collateral accounting
    // ---------------------------------------------------------------------

    function testCollateralReleaseAfterSettle() public {
        uint256 positionId = _buyAndWarp(2000e18);
        router.settle(positionId);
        PoolState memory state = manager.poolState(poolId);
        assertEq(state.reservedLiability, 0);
        assertEq(state.availableCollateral, state.totalCollateral);
    }

    function testSyncPoolReflectsAdditionalAquaPush() public {
        // LP increases the strategy balance directly through Aqua (self-transfer needs balance/approval).
        usdc.mint(lp, 5_000e6);
        vm.startPrank(lp);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.push(lp, address(router), poolId, address(usdc), 5_000e6);
        vm.stopPrank();
        manager.syncPool(poolId);
        assertEq(manager.poolState(poolId).totalCollateral, COLLATERAL + 5_000e6);
    }

    function testTwoOptionsShareCollateral() public {
        _openDefault();
        uint256 premium = _quotedPremium();
        _buyDefault(premium);

        uint256 expiry2 = block.timestamp + 60 days;
        router.open(poolId, lp, keeper, 2000e6, 5e18, expiry2);
        PoolState memory state = manager.poolState(poolId);
        assertEq(state.reservedLiability, 10_000e6 + 10_000e6, "shared reserved liability");
        assertEq(state.availableCollateral, COLLATERAL - 20_000e6);
        assertEq(state.premiumEarned, premium);
    }

    // ---------------------------------------------------------------------
    // Decimals and rounding
    // ---------------------------------------------------------------------

    function testDecimalsUsdcSix() public {
        _openDefault();
        PendingOption memory pending = manager.getPending(poolId);
        // Premium is quoted in 6-decimal USDC, ~132.8998 USDC. The A&S CDF bound allows
        // up to ~2e-3 USD of absolute error on this quote.
        assertApproxEqAbs(pending.premium, 132_899_803, 2_000);
        assertEq(pending.notional % ONE_USDC, 0);
    }

    function testPremiumIsCeilRounded() public {
        _openDefault();
        uint256 premiumWad =
            pricing.quotePremium(3000e18, STRIKE * 1e12, QUANTITY, expiry, params.volatility(), params.riskFreeRate());
        uint256 exactFloor = premiumWad / 1e12;
        assertGe(manager.getPending(poolId).premium, exactFloor);
        assertLe(manager.getPending(poolId).premium, exactFloor + 1);
    }
}
