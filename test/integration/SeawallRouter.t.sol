// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { SeawallRouter } from "../../contracts/swapvm/SeawallRouter.sol";
import { OptionInstructions } from "../../contracts/swapvm/OptionInstructions.sol";
import { OptionManager } from "../../contracts/core/OptionManager.sol";
import { CollateralManager } from "../../contracts/core/CollateralManager.sol";
import { PricingEngine } from "../../contracts/core/PricingEngine.sol";
import { MarketParams } from "../../contracts/oracle/MarketParams.sol";
import { OptionStatus, OptionPosition, PoolState } from "../../contracts/interfaces/OptionTypes.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";

/// @notice End-to-end lifecycle through the real SwapVM router and the real Aqua registry.
contract SeawallRouterTest is Test {
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant COLLATERAL = 100_000e6;
    uint256 internal constant STRIKE = 2500e6;
    uint256 internal constant QUANTITY = 4e18;
    uint256 internal constant WETH_DUST = 100;

    Aqua internal aqua;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    PricingEngine internal pricing;
    MarketParams internal params;
    MockOracle internal oracle;
    CollateralManager internal collateral;
    SeawallRouter internal router;
    OptionManager internal manager;

    address internal lp = address(0xB0B);
    address internal alice = address(0xA11CE);
    address internal keeper = address(0x4EE9);

    ISwapVM.Order internal buyOrder;
    ISwapVM.Order internal exerciseOrder;
    ISwapVM.Order internal settleOrder;
    ISwapVM.Order internal expireOrder;

    bytes32 internal poolId;
    uint256 internal expiry;

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

        buyOrder = router.buildOrder(lp, router.buildBuyProgram());
        exerciseOrder = router.buildOrder(lp, router.buildExerciseProgram());
        settleOrder = router.buildOrder(lp, router.buildSettleProgram());
        expireOrder = router.buildOrder(lp, router.buildExpireProgram());
        poolId = router.hash(buyOrder);

        usdc.mint(lp, 1_000_000e6);
        weth.mint(lp, 10e18);
        vm.startPrank(lp);
        usdc.approve(address(aqua), type(uint256).max);
        weth.approve(address(aqua), type(uint256).max);
        aqua.ship(address(router), abi.encode(buyOrder), _tokens(), _balances(COLLATERAL, WETH_DUST));
        aqua.ship(address(router), abi.encode(exerciseOrder), _tokens(), _balances(0, WETH_DUST));
        aqua.ship(address(router), abi.encode(settleOrder), _tokens(), _balances(0, WETH_DUST));
        aqua.ship(address(router), abi.encode(expireOrder), _tokens(), _balances(0, WETH_DUST));
        vm.stopPrank();

        vm.prank(lp);
        manager.registerPool(poolId, 50_000e6, 90 days);

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);

        expiry = block.timestamp + 30 days;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

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

    function _takerData(
        address taker,
        bool useTransferFromAndAquaPush,
        bytes memory instructionsArgs
    )
        internal
        pure
        returns (bytes memory)
    {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: useTransferFromAndAquaPush,
                threshold: "",
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: instructionsArgs,
                signature: ""
            })
        );
    }

    function _buyOption(
        address buyer,
        uint256 strike,
        uint256 quantity,
        uint256 optionExpiry
    )
        internal
        returns (uint256 premium, uint256 positionId)
    {
        premium = manager.quotePremium(strike, quantity, optionExpiry);
        bytes memory data = _takerData(buyer, true, abi.encode(strike, quantity, optionExpiry));
        vm.prank(buyer);
        (uint256 amountIn,,) = router.swap(buyOrder, address(usdc), address(weth), premium, data);
        assertEq(amountIn, premium, "premium moved");
        positionId = manager.nextPositionId() - 1;
    }

    function _exerciseAndSettle(address caller, uint256 positionId) internal {
        bytes memory data = _takerData(caller, false, abi.encode(positionId, positionId));
        vm.prank(caller);
        router.swap(exerciseOrder, address(usdc), address(weth), 0, data);
    }

    function _settle(address caller, uint256 positionId) internal {
        bytes memory data = _takerData(caller, false, abi.encode(positionId));
        vm.prank(caller);
        router.swap(settleOrder, address(usdc), address(weth), 0, data);
    }

    function _expire(address caller, uint256 positionId) internal {
        bytes memory data = _takerData(caller, false, abi.encode(positionId));
        vm.prank(caller);
        router.swap(expireOrder, address(usdc), address(weth), 0, data);
    }

    function _aquaUsdc() internal view returns (uint256) {
        (uint248 balance,) = aqua.rawBalances(lp, address(router), poolId, address(usdc));
        return uint256(balance);
    }

    // ---------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------

    function testFullLifecycleItm() public {
        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 aliceBefore = usdc.balanceOf(alice);

        (uint256 premium, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);

        // Premium moved Alice -> LP, credited to the pool's Aqua strategy.
        assertEq(usdc.balanceOf(alice), aliceBefore - premium);
        assertEq(usdc.balanceOf(lp), lpBefore + premium);
        assertEq(_aquaUsdc(), COLLATERAL + premium);
        assertEq(weth.balanceOf(alice), 1, "execution marker received");

        OptionPosition memory position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.ACTIVE));
        assertEq(position.buyer, alice);
        assertEq(position.notional, 10_000e6);
        assertEq(position.premium, premium);

        PoolState memory pool = manager.poolState(poolId);
        assertEq(pool.reservedLiability, 10_000e6);
        assertEq(pool.availableCollateral, COLLATERAL + premium - 10_000e6);

        // ETH drops to $2,000.
        oracle.setSettlementPrice(expiry, 2000e18);
        vm.warp(expiry + 1);

        _exerciseAndSettle(alice, positionId);

        uint256 payout = 2000e6;
        assertEq(usdc.balanceOf(alice), aliceBefore - premium + payout);
        assertEq(usdc.balanceOf(lp), lpBefore + premium - payout);
        assertEq(_aquaUsdc(), COLLATERAL + premium - payout);

        position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.SETTLED));
        assertEq(position.settlementPrice, 2000e6);
        assertEq(position.payout, payout);

        pool = manager.poolState(poolId);
        assertEq(pool.reservedLiability, 0, "liability released");
        assertEq(pool.payoutsPaid, payout);
        assertEq(pool.premiumEarned, premium);
    }

    function testFullLifecycleOtm() public {
        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 aliceBefore = usdc.balanceOf(alice);
        (uint256 premium, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);

        oracle.setSettlementPrice(expiry, 3100e18);
        vm.warp(expiry + 1);

        _expire(keeper, positionId);

        assertEq(usdc.balanceOf(alice), aliceBefore - premium, "buyer loses premium");
        assertEq(usdc.balanceOf(lp), lpBefore + premium, "LP keeps premium");
        assertEq(_aquaUsdc(), COLLATERAL + premium, "collateral released and intact");

        OptionPosition memory position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.EXPIRED));
        assertEq(position.payout, 0);
        assertEq(manager.poolState(poolId).reservedLiability, 0);
    }

    function testKeeperlessAutoSettlement() public {
        (, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        oracle.setSettlementPrice(expiry, 2000e18);
        vm.warp(expiry + 1);

        // No exercise: any keeper can settle, and the payout still goes to Alice.
        uint256 aliceBefore = usdc.balanceOf(alice);
        _settle(keeper, positionId);
        assertEq(usdc.balanceOf(alice), aliceBefore + 2000e6);
        assertEq(uint8(manager.getPosition(positionId).status), uint8(OptionStatus.SETTLED));
    }

    function testExerciseByBuyerOnly() public {
        (, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        oracle.setSettlementPrice(expiry, 2000e18);
        vm.warp(expiry + 1);

        bytes memory data = _takerData(keeper, false, abi.encode(positionId, positionId));
        vm.expectRevert(abi.encodeWithSelector(OptionManager.UnauthorizedExercise.selector, positionId, keeper, alice));
        vm.prank(keeper);
        router.swap(exerciseOrder, address(usdc), address(weth), 0, data);
    }

    function testDoubleSettlementReverts() public {
        (, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        oracle.setSettlementPrice(expiry, 2000e18);
        vm.warp(expiry + 1);

        _settle(keeper, positionId);

        bytes memory data = _takerData(keeper, false, abi.encode(positionId));
        vm.expectRevert(
            abi.encodeWithSelector(OptionManager.PositionNotSettleable.selector, positionId, OptionStatus.SETTLED)
        );
        vm.prank(keeper);
        router.swap(settleOrder, address(usdc), address(weth), 0, data);
    }

    function testExpiredExerciseReverts() public {
        (, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        oracle.setSettlementPrice(expiry, 2000e18);
        vm.warp(expiry + manager.EXERCISE_WINDOW() + 1);

        bytes memory data = _takerData(alice, false, abi.encode(positionId, positionId));
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionManager.ExerciseWindowClosed.selector,
                positionId,
                expiry + manager.EXERCISE_WINDOW(),
                block.timestamp
            )
        );
        vm.prank(alice);
        router.swap(exerciseOrder, address(usdc), address(weth), 0, data);
    }

    function testExpireItmAfterWindow() public {
        (, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        oracle.setSettlementPrice(expiry, 2000e18);
        vm.warp(expiry + manager.EXERCISE_WINDOW() + 1);
        _expire(keeper, positionId);
        assertEq(uint8(manager.getPosition(positionId).status), uint8(OptionStatus.EXPIRED));
    }

    function testPremiumBelowQuoteReverts() public {
        uint256 premium = manager.quotePremium(STRIKE, QUANTITY, expiry);
        bytes memory data = _takerData(alice, true, abi.encode(STRIKE, QUANTITY, expiry));
        vm.expectRevert(abi.encodeWithSelector(OptionManager.PremiumTooLow.selector, premium - 1, premium));
        vm.prank(alice);
        router.swap(buyOrder, address(usdc), address(weth), premium - 1, data);
    }

    function testSwapVMInstruction() public {
        uint256 premium = manager.quotePremium(STRIKE, QUANTITY, expiry);
        bytes memory data = _takerData(alice, true, abi.encode(STRIKE, QUANTITY, expiry));
        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut, bytes32 orderHash) =
            router.swap(buyOrder, address(usdc), address(weth), premium, data);

        assertEq(amountIn, premium, "taker amount in");
        assertEq(amountOut, 1, "execution marker from the custom instruction");
        assertEq(orderHash, poolId, "aqua order hash");
        assertEq(weth.balanceOf(alice), 1, "marker moved through the VM transfer phase");
        assertEq(manager.getPosition(1).buyer, alice);
    }

    function testAquaIntegration() public {
        // The pool id is the Aqua strategy hash and its balance is the live collateral.
        assertEq(router.hash(buyOrder), poolId);
        (uint248 balance, uint8 tokensCount) = aqua.rawBalances(lp, address(router), poolId, address(usdc));
        assertEq(uint256(balance), COLLATERAL);
        assertEq(tokensCount, 2, "USDC + WETH shipped");
        assertEq(manager.poolState(poolId).totalCollateral, COLLATERAL);

        // The premium is pushed into the same strategy by the VM transfer phase.
        (uint256 premium,) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        (balance,) = aqua.rawBalances(lp, address(router), poolId, address(usdc));
        assertEq(uint256(balance), COLLATERAL + premium);
    }

    // ---------------------------------------------------------------------
    // Aqua-native collateral behaviour
    // ---------------------------------------------------------------------

    function testWithdrawAvailableCollateral() public {
        (uint256 premium,) = _buyOption(alice, STRIKE, QUANTITY, expiry);

        uint256 available = COLLATERAL + premium - 10_000e6;
        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        router.withdrawCollateral(poolId, available);

        // Aqua pull is a maker self-transfer: the wallet balance only changes through the strategy
        // accounting, but the cached collateral must drop by the withdrawn amount.
        assertEq(usdc.balanceOf(lp), lpBefore, "self transfer");
        assertEq(_aquaUsdc(), COLLATERAL + premium - available);
        assertEq(collateral.getPool(poolId).totalCollateral, COLLATERAL + premium - available);
    }

    function testWithdrawBlockedByReservedLiability() public {
        (uint256 premium,) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        uint256 available = COLLATERAL + premium - 10_000e6;
        vm.expectRevert(
            abi.encodeWithSelector(OptionManager.WithdrawTooMuch.selector, poolId, available, available + 1)
        );
        vm.prank(lp);
        router.withdrawCollateral(poolId, available + 1);
    }

    function testWithdrawOnlyMaker() public {
        vm.expectRevert(abi.encodeWithSelector(OptionManager.PoolMakerMismatch.selector, poolId, lp, alice));
        vm.prank(alice);
        router.withdrawCollateral(poolId, 1e6);
    }

    function testDepositMoreCollateralAndSync() public {
        usdc.mint(lp, 10_000e6);
        vm.startPrank(lp);
        aqua.push(lp, address(router), poolId, address(usdc), 10_000e6);
        vm.stopPrank();

        assertEq(_aquaUsdc(), COLLATERAL + 10_000e6);
        manager.syncPool(poolId);
        assertEq(manager.poolState(poolId).totalCollateral, COLLATERAL + 10_000e6);
    }

    function testRegisterPoolRequiresShippedStrategy() public {
        bytes32 unknown = keccak256("unknown-pool");
        vm.expectRevert(abi.encodeWithSelector(OptionManager.PoolNotFunded.selector, unknown, lp, uint256(0), uint8(0)));
        vm.prank(lp);
        manager.registerPool(unknown, 1e6, 30 days);
    }

    // ---------------------------------------------------------------------
    // Safety
    // ---------------------------------------------------------------------

    function testSettlementFailsSafelyWhenMakerDocksStrategy() public {
        (, uint256 positionId) = _buyOption(alice, STRIKE, QUANTITY, expiry);
        oracle.setSettlementPrice(expiry, 2000e18);
        vm.warp(expiry + 1);

        // Maker unilaterally docks the Aqua strategy (Aqua is an allowance layer, not escrow).
        vm.prank(lp);
        aqua.dock(address(router), poolId, _tokens());

        bytes memory data = _takerData(keeper, false, abi.encode(positionId));
        vm.expectRevert();
        vm.prank(keeper);
        router.swap(settleOrder, address(usdc), address(weth), 0, data);
    }

    function testWrongTokenPairReverts() public {
        bytes memory data = _takerData(alice, true, abi.encode(STRIKE, QUANTITY, expiry));
        uint256 premium = manager.quotePremium(STRIKE, QUANTITY, expiry);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionInstructions.OptionInstructionInvalidTokens.selector, address(weth), address(usdc)
            )
        );
        vm.prank(alice);
        router.swap(buyOrder, address(weth), address(usdc), premium, data);
    }
}
