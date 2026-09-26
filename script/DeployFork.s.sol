// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { SeawallRouter } from "../contracts/swapvm/SeawallRouter.sol";
import { OptionManager } from "../contracts/core/OptionManager.sol";
import { CollateralManager } from "../contracts/core/CollateralManager.sol";
import { PricingEngine } from "../contracts/core/PricingEngine.sol";
import { MarketParams } from "../contracts/oracle/MarketParams.sol";
import { MockOracle } from "../test/mocks/MockOracle.sol";
import { RouterDeployer } from "./RouterDeployer.sol";

/// @notice Deploys Seawall on a **mainnet fork** against the canonical deployed Aqua registry,
///         real USDC and real WETH. A mock oracle is used so the demo UI can move the price; the
///         Chainlink integration is exercised by `test/fork/MainnetFork.t.sol`.
///
/// Usage:
///   anvil --fork-url $MAINNET_RPC_URL --auto-impersonate --port 8546
///   # fund Bob/Alice with real USDC (see script/demo-fork.sh)
///   forge script script/DeployFork.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
contract DeployFork is Script {
    // Canonical deployments (same address on 13 chains).
    address internal constant CANONICAL_AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant ANVIL_LP_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_ALICE_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant WETH_DUST = 1e6;

    function run() external {
        uint256 deployerPk = vm.envOr("PRIVATE_KEY", ANVIL_LP_PK);
        address lp = vm.addr(deployerPk);
        address alice = vm.addr(ANVIL_ALICE_PK);

        vm.startBroadcast(deployerPk);

        // The router is created from inside a call (see RouterDeployer).
        PricingEngine pricing = new PricingEngine();
        MarketParams marketParams = new MarketParams(lp, 0.6e18, 0.05e18);
        MockOracle oracle = new MockOracle();
        oracle.setSpot(3000e18);

        CollateralManager collateral = new CollateralManager(lp);
        RouterDeployer routerDeployer = new RouterDeployer();
        SeawallRouter router = SeawallRouter(payable(routerDeployer.deploy(CANONICAL_AQUA, WETH, lp, USDC)));
        OptionManager manager = new OptionManager(
            address(router),
            CANONICAL_AQUA,
            USDC,
            address(collateral),
            address(pricing),
            address(marketParams),
            address(oracle)
        );
        router.setOptionManager(address(manager), address(collateral));
        collateral.setManager(address(manager));

        // Bob needs a little real WETH for the SwapVM execution marker.
        if (IERC20(WETH).balanceOf(lp) < WETH_DUST) {
            (bool ok,) = WETH.call{ value: 0.1 ether }(abi.encodeWithSignature("deposit()"));
            require(ok, "weth deposit failed");
        }

        ISwapVM.Order memory buyOrder = router.buildOrder(lp, router.buildBuyProgram());
        ISwapVM.Order memory exerciseOrder = router.buildOrder(lp, router.buildExerciseProgram());
        ISwapVM.Order memory settleOrder = router.buildOrder(lp, router.buildSettleProgram());
        ISwapVM.Order memory expireOrder = router.buildOrder(lp, router.buildExpireProgram());
        bytes32 poolId = router.hash(buyOrder);

        IERC20(USDC).approve(CANONICAL_AQUA, type(uint256).max);
        IERC20(WETH).approve(CANONICAL_AQUA, type(uint256).max);
        _ship(CANONICAL_AQUA, address(router), buyOrder, 100_000e6, WETH_DUST);
        _ship(CANONICAL_AQUA, address(router), exerciseOrder, 0, WETH_DUST);
        _ship(CANONICAL_AQUA, address(router), settleOrder, 0, WETH_DUST);
        _ship(CANONICAL_AQUA, address(router), expireOrder, 0, WETH_DUST);

        manager.registerPool(poolId, 50_000e6, 90 days);

        vm.stopBroadcast();

        console2.log("Aqua (canonical)  ", CANONICAL_AQUA);
        console2.log("USDC (real)       ", USDC);
        console2.log("WETH (real)       ", WETH);
        console2.log("PricingEngine     ", address(pricing));
        console2.log("MarketParams      ", address(marketParams));
        console2.log("Oracle (mock)     ", address(oracle));
        console2.log("CollateralManager ", address(collateral));
        console2.log("SeawallRouter ", address(router));
        console2.log("OptionManager     ", address(manager));
        console2.log("LP / maker        ", lp);
        console2.log("Alice             ", alice);
        console2.log("Pool id           ", uint256(poolId));

        _writeDeployment(
            CANONICAL_AQUA,
            USDC,
            WETH,
            address(pricing),
            address(marketParams),
            address(oracle),
            address(collateral),
            address(router),
            address(manager),
            lp,
            alice,
            poolId
        );
    }

    function _ship(
        address aqua,
        address app,
        ISwapVM.Order memory order,
        uint256 usdcAmount,
        uint256 wethAmount
    )
        internal
    {
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = wethAmount;
        IAqua(aqua).ship(app, abi.encode(order), tokens, amounts);
    }

    function _writeDeployment(
        address aqua_,
        address usdc_,
        address weth_,
        address pricing_,
        address marketParams_,
        address oracle_,
        address collateral_,
        address router_,
        address manager_,
        address lp,
        address alice,
        bytes32 poolId
    )
        internal
    {
        string memory objectKey = "deployment";
        vm.serializeAddress(objectKey, "aqua", aqua_);
        vm.serializeAddress(objectKey, "usdc", usdc_);
        vm.serializeAddress(objectKey, "weth", weth_);
        vm.serializeAddress(objectKey, "pricingEngine", pricing_);
        vm.serializeAddress(objectKey, "marketParams", marketParams_);
        vm.serializeAddress(objectKey, "oracle", oracle_);
        vm.serializeAddress(objectKey, "collateralManager", collateral_);
        vm.serializeAddress(objectKey, "router", router_);
        vm.serializeAddress(objectKey, "optionManager", manager_);
        vm.serializeAddress(objectKey, "lp", lp);
        vm.serializeAddress(objectKey, "alice", alice);
        vm.serializeUint(objectKey, "deployBlock", block.number);
        string memory json = vm.serializeBytes32(objectKey, "poolId", poolId);
        vm.writeJson(json, "deployments/31337.json");
    }
}
