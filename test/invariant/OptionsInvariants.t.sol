// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SeawallRouter } from "../../contracts/swapvm/SeawallRouter.sol";
import { OptionManager } from "../../contracts/core/OptionManager.sol";
import { CollateralManager } from "../../contracts/core/CollateralManager.sol";
import { PricingEngine } from "../../contracts/core/PricingEngine.sol";
import { MarketParams } from "../../contracts/oracle/MarketParams.sol";
import { Pool } from "../../contracts/interfaces/OptionTypes.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { OptionsHandler } from "./OptionsHandler.sol";

/// @notice Invariants for the fully collateralised design:
///         1. reservedLiability <= totalCollateral
///         2. reservedLiability == sum of maximum payouts of live options
///         3. payout <= notional for every position
///         4. totalCollateral + payoutsPaid + withdrawn == initial + deposited + premiumEarned
///         5. premiumEarned == sum of recorded premiums
contract OptionsInvariantsTest is Test {
    uint256 internal constant COLLATERAL = 1_000_000e6;
    uint256 internal constant WETH_DUST = 10_000;

    Aqua internal aqua;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    PricingEngine internal pricing;
    MarketParams internal params;
    MockOracle internal oracle;
    CollateralManager internal collateral;
    SeawallRouter internal router;
    OptionManager internal manager;
    OptionsHandler internal handler;

    address internal lp = address(0xB0B);

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
        router = new SeawallRouter(address(aqua), address(weth), address(this), address(usdc));
        manager = new OptionManager(
            address(router),
            address(aqua),
            address(usdc),
            address(collateral),
            address(pricing),
            address(params),
            address(oracle)
        );
        router.setOptionManager(address(manager), address(collateral));
        collateral.setManager(address(manager));

        bytes memory buyStrategy = abi.encode(router.buildOrder(lp, router.buildBuyProgram()));
        bytes memory exerciseStrategy = abi.encode(router.buildOrder(lp, router.buildExerciseProgram()));
        bytes memory settleStrategy = abi.encode(router.buildOrder(lp, router.buildSettleProgram()));
        bytes memory expireStrategy = abi.encode(router.buildOrder(lp, router.buildExpireProgram()));

        usdc.mint(lp, COLLATERAL);
        weth.mint(lp, 10e18);
        vm.startPrank(lp);
        usdc.approve(address(aqua), type(uint256).max);
        weth.approve(address(aqua), type(uint256).max);
        aqua.ship(address(router), buyStrategy, _tokens(), _balances(COLLATERAL, WETH_DUST));
        aqua.ship(address(router), exerciseStrategy, _tokens(), _balances(0, WETH_DUST));
        aqua.ship(address(router), settleStrategy, _tokens(), _balances(0, WETH_DUST));
        aqua.ship(address(router), expireStrategy, _tokens(), _balances(0, WETH_DUST));
        vm.stopPrank();

        bytes32 poolId = router.hash(router.buildOrder(lp, router.buildBuyProgram()));
        vm.prank(lp);
        manager.registerPool(poolId, 100_000e6, 300 days);
        manager.syncPool(poolId);

        handler = new OptionsHandler(aqua, usdc, weth, oracle, collateral, router, manager, lp);
        targetContract(address(handler));
    }

    function _tokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
    }

    function _balances(uint256 usdcAmount, uint256 wethAmount) internal pure returns (uint256[] memory balances) {
        balances = new uint256[](2);
        balances[0] = usdcAmount;
        balances[1] = wethAmount;
    }

    function invariant_reservedNeverExceedsCollateral() public view {
        Pool memory pool = collateral.getPool(handler.getPoolId());
        assertLe(pool.reservedLiability, pool.totalCollateral, "reserved <= total");
    }

    function invariant_reservedMatchesLiveLiability() public view {
        Pool memory pool = collateral.getPool(handler.getPoolId());
        assertEq(pool.reservedLiability, handler.sumActiveLiability(), "reserved == sum(notional of live options)");
    }

    function invariant_payoutNeverExceedsNotional() public view {
        assertFalse(handler.firstBrokenPayout(), "payout <= notional");
    }

    function invariant_collateralAccountingIdentity() public view {
        Pool memory pool = collateral.getPool(handler.getPoolId());
        assertEq(
            pool.totalCollateral + pool.payoutsPaid + handler.withdrawn(),
            handler.initialCollateral() + handler.deposited() + pool.premiumEarned,
            "collateral accounting identity"
        );
    }

    function invariant_premiumAccounting() public view {
        Pool memory pool = collateral.getPool(handler.getPoolId());
        assertEq(pool.premiumEarned, handler.sumPremiums(), "premiumEarned == sum(premiums)");
    }
}
