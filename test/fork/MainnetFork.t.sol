// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { SeawallRouter } from "../../contracts/swapvm/SeawallRouter.sol";
import { OptionManager } from "../../contracts/core/OptionManager.sol";
import { CollateralManager } from "../../contracts/core/CollateralManager.sol";
import { PricingEngine } from "../../contracts/core/PricingEngine.sol";
import { MarketParams } from "../../contracts/oracle/MarketParams.sol";
import { ChainlinkETHOracle, AggregatorV3Interface } from "../../contracts/oracle/ChainlinkETHOracle.sol";
import { OptionStatus, OptionPosition } from "../../contracts/interfaces/OptionTypes.sol";

/// @notice Mainnet fork demo: real deployed Aqua registry, real USDC and WETH, real Chainlink
///         ETH/USD feed, with the full option lifecycle settled through Aqua + SwapVM.
///
/// @dev Requires network access. Set MAINNET_RPC_URL to use a private RPC, otherwise a public one
///      is used. Run with: `forge test --match-contract MainnetForkTest -vvv`
contract MainnetForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;

    uint256 internal constant WETH_DUST = 1e6;

    IERC20 internal usdc;
    IWETH internal weth;
    PricingEngine internal pricing;
    MarketParams internal params;
    ChainlinkETHOracle internal oracle;
    CollateralManager internal collateral;
    SeawallRouter internal router;
    OptionManager internal manager;

    address internal lp = address(0xB0B);
    address internal alice = address(0xA11CE);

    ISwapVM.Order internal buyOrder;
    ISwapVM.Order internal exerciseOrder;
    ISwapVM.Order internal settleOrder;
    ISwapVM.Order internal expireOrder;

    bytes32 internal poolId;
    uint256 internal expiry;
    uint256 internal strike;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc);

        usdc = IERC20(USDC);
        weth = IWETH(WETH);

        pricing = new PricingEngine();
        params = new MarketParams(address(this), 0.6e18, 0.05e18);
        oracle = new ChainlinkETHOracle(address(this), ETH_USD_FEED, 1 days, 1 days);

        collateral = new CollateralManager(address(this));
        router = new SeawallRouter(AQUA, WETH, address(this), USDC);
        manager = new OptionManager(
            address(router), AQUA, USDC, address(collateral), address(pricing), address(params), address(oracle)
        );
        router.setOptionManager(address(manager), address(collateral));
        collateral.setManager(address(manager));

        // Fund LP and Alice with real USDC, and LP with WETH for the execution marker.
        vm.startPrank(USDC_WHALE);
        usdc.transfer(lp, 200_000e6);
        usdc.transfer(alice, 10_000e6);
        vm.stopPrank();
        vm.deal(lp, 1 ether);
        vm.prank(lp);
        weth.deposit{ value: 1 ether }();

        buyOrder = router.buildOrder(lp, router.buildBuyProgram());
        exerciseOrder = router.buildOrder(lp, router.buildExerciseProgram());
        settleOrder = router.buildOrder(lp, router.buildSettleProgram());
        expireOrder = router.buildOrder(lp, router.buildExpireProgram());
        poolId = router.hash(buyOrder);

        vm.startPrank(lp);
        usdc.approve(AQUA, type(uint256).max);
        weth.approve(AQUA, type(uint256).max);
        _ship(buyOrder, 100_000e6, WETH_DUST);
        _ship(exerciseOrder, 0, WETH_DUST);
        _ship(settleOrder, 0, WETH_DUST);
        _ship(expireOrder, 0, WETH_DUST);
        manager.registerPool(poolId, 50_000e6, 90 days);
        vm.stopPrank();

        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);

        expiry = block.timestamp + 7 days;
    }

    function _ship(ISwapVM.Order memory order, uint256 usdcAmount, uint256 wethAmount) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = wethAmount;
        IAqua(AQUA).ship(address(router), abi.encode(order), tokens, amounts);
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

    function testFullLifecycleOnMainnetFork() public {
        uint256 spot = oracle.spot();
        assertGt(spot, 0, "real chainlink spot");
        emit log_named_decimal_uint("Chainlink ETH/USD spot", spot, 18);

        // 10% out of the money put, $10,000 notional. Strike is in 6-decimal USDC per ETH.
        strike = (spot * 90) / 100 / 1e12;
        uint256 notional = 10_000e6;
        uint256 quantity = notional * 1e18 / strike;
        assertGt(quantity, 0);

        uint256 premium = manager.quotePremium(strike, quantity, expiry);
        emit log_named_decimal_uint("Quoted premium (USDC)", premium, 6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 lpBefore = usdc.balanceOf(lp);

        bytes memory buyData = _takerData(alice, true, abi.encode(strike, quantity, expiry));
        vm.prank(alice);
        router.swap(buyOrder, USDC, WETH, premium, buyData);

        uint256 positionId = manager.nextPositionId() - 1;
        OptionPosition memory position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.ACTIVE));
        assertApproxEqAbs(position.notional, notional, 1e6, "notional rounding");
        assertEq(usdc.balanceOf(alice), aliceBefore - premium, "premium paid in real USDC");
        assertEq(usdc.balanceOf(lp), lpBefore + premium, "premium received in real USDC");

        (uint248 poolBalance,) = _aquaBalances();
        assertEq(uint256(poolBalance), 100_000e6 + premium, "collateral + premium in Aqua");

        // ETH crashes to $2,000 at expiry.
        vm.warp(expiry + 1);
        _mockFeedPrice(2000e8);

        bytes memory exerciseData = _takerData(alice, false, abi.encode(positionId, positionId));
        vm.prank(alice);
        router.swap(exerciseOrder, USDC, WETH, 0, exerciseData);

        uint256 expectedPayout = (strike - 2000e6) * quantity / 1e18;
        position = manager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(OptionStatus.SETTLED));
        assertEq(position.payout, expectedPayout);
        assertEq(usdc.balanceOf(alice), aliceBefore - premium + expectedPayout, "payout received in real USDC");
        assertEq(usdc.balanceOf(lp), lpBefore + premium - expectedPayout, "LP collateral paid out");

        (uint248 poolBalanceAfter,) = _aquaBalances();
        assertEq(uint256(poolBalanceAfter), 100_000e6 + premium - expectedPayout);

        emit log_named_decimal_uint("Settlement payout (USDC)", expectedPayout, 6);
        emit log_named_decimal_uint("Remaining LP collateral (USDC)", uint256(poolBalanceAfter), 6);
    }

    function _aquaBalances() internal view returns (uint248, uint8) {
        return IAqua(AQUA).rawBalances(lp, address(router), poolId, USDC);
    }

    function _mockFeedPrice(int256 answer) internal {
        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
