// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { SeawallRouter } from "../contracts/swapvm/SeawallRouter.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { MockOracle } from "../test/mocks/MockOracle.sol";
import { PricingEngine } from "../contracts/core/PricingEngine.sol";
import { MarketParams } from "../contracts/oracle/MarketParams.sol";
import { CollateralManager } from "../contracts/core/CollateralManager.sol";
import { OptionManager } from "../contracts/core/OptionManager.sol";
import { RouterDeployer } from "./RouterDeployer.sol";

/// @notice Deploys the full Seawall stack on a local anvil chain, funds the demo actors and
///         sets up Bob's LP pool. Writes `deployments/31337.json` for the frontend.
///
/// Usage:
///   anvil --port 8546
///   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
contract DeployLocal is Script {
    uint256 internal constant ANVIL_LP_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_ALICE_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant WETH_DUST = 1e6;

    function run() external {
        uint256 deployerPk = vm.envOr("PRIVATE_KEY", ANVIL_LP_PK);
        address lp = vm.addr(deployerPk);
        address alice = vm.addr(ANVIL_ALICE_PK);

        vm.startBroadcast(deployerPk);

        Aqua aqua = new Aqua();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);

        PricingEngine pricing = new PricingEngine();
        MarketParams marketParams = new MarketParams(lp, 0.6e18, 0.05e18);
        MockOracle oracle = new MockOracle();
        oracle.setSpot(3000e18);

        CollateralManager collateral = new CollateralManager(lp);
        RouterDeployer routerDeployer = new RouterDeployer();
        SeawallRouter router =
            SeawallRouter(payable(routerDeployer.deploy(address(aqua), address(weth), lp, address(usdc))));
        OptionManager manager = new OptionManager(
            address(router),
            address(aqua),
            address(usdc),
            address(collateral),
            address(pricing),
            address(marketParams),
            address(oracle)
        );

        router.setOptionManager(address(manager), address(collateral));
        collateral.setManager(address(manager));

        // Fund the demo actors.
        usdc.mint(lp, 1_000_000e6);
        usdc.mint(alice, 100_000e6);
        weth.mint(lp, 1e18);

        // Bob ships his LP strategies through Aqua.
        ISwapVM.Order memory buyOrder = router.buildOrder(lp, router.buildBuyProgram());
        ISwapVM.Order memory exerciseOrder = router.buildOrder(lp, router.buildExerciseProgram());
        ISwapVM.Order memory settleOrder = router.buildOrder(lp, router.buildSettleProgram());
        ISwapVM.Order memory expireOrder = router.buildOrder(lp, router.buildExpireProgram());
        bytes32 poolId = router.hash(buyOrder);

        usdc.approve(address(aqua), type(uint256).max);
        weth.approve(address(aqua), type(uint256).max);
        _ship(aqua, router, address(usdc), address(weth), buyOrder, 100_000e6, WETH_DUST);
        _ship(aqua, router, address(usdc), address(weth), exerciseOrder, 0, WETH_DUST);
        _ship(aqua, router, address(usdc), address(weth), settleOrder, 0, WETH_DUST);
        _ship(aqua, router, address(usdc), address(weth), expireOrder, 0, WETH_DUST);

        manager.registerPool(poolId, 50_000e6, 90 days);

        vm.stopBroadcast();

        console2.log("Aqua              ", address(aqua));
        console2.log("USDC              ", address(usdc));
        console2.log("WETH              ", address(weth));
        console2.log("PricingEngine     ", address(pricing));
        console2.log("MarketParams      ", address(marketParams));
        console2.log("Oracle            ", address(oracle));
        console2.log("CollateralManager ", address(collateral));
        console2.log("SeawallRouter ", address(router));
        console2.log("OptionManager     ", address(manager));
        console2.log("LP / maker        ", lp);
        console2.log("Alice             ", alice);
        console2.log("Pool id           ", uint256(poolId));

        _writeDeployment(
            address(aqua),
            address(usdc),
            address(weth),
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
        Aqua aqua,
        SeawallRouter router,
        address usdc,
        address weth,
        ISwapVM.Order memory order,
        uint256 usdcAmount,
        uint256 wethAmount
    )
        internal
    {
        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = weth;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = wethAmount;
        aqua.ship(address(router), abi.encode(order), tokens, amounts);
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
