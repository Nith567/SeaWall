// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { SeawallRouter } from "../../contracts/swapvm/SeawallRouter.sol";
import { OptionManager } from "../../contracts/core/OptionManager.sol";
import { CollateralManager } from "../../contracts/core/CollateralManager.sol";
import { OptionStatus, OptionPosition } from "../../contracts/interfaces/OptionTypes.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";

/// @notice Stateful fuzzing handler driving the full lifecycle through the real router.
contract OptionsHandler is Test {
    uint256 internal constant MAX_NOTIONAL = 100_000e6;
    uint256 internal constant WETH_DUST = 10_000;

    Aqua internal immutable aqua;
    MockERC20 internal immutable usdc;
    MockERC20 internal immutable weth;
    MockOracle internal immutable oracle;
    CollateralManager internal immutable collateral;
    SeawallRouter internal immutable router;
    OptionManager internal immutable manager;

    address internal immutable lp;
    address[] internal buyers;

    ISwapVM.Order internal buyOrder;
    ISwapVM.Order internal exerciseOrder;
    ISwapVM.Order internal settleOrder;
    ISwapVM.Order internal expireOrder;
    bytes32 internal poolId;

    uint256 public initialCollateral = 1_000_000e6;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public ghostOpened;
    uint256 public ghostBought;

    uint256[] public positionIds;

    constructor(
        Aqua aqua_,
        MockERC20 usdc_,
        MockERC20 weth_,
        MockOracle oracle_,
        CollateralManager collateral_,
        SeawallRouter router_,
        OptionManager manager_,
        address lp_
    ) {
        aqua = aqua_;
        usdc = usdc_;
        weth = weth_;
        oracle = oracle_;
        collateral = collateral_;
        router = router_;
        manager = manager_;
        lp = lp_;

        buyers.push(address(0xB0B1));
        buyers.push(address(0xB0B2));
        buyers.push(address(0xB0B3));

        buyOrder = router.buildOrder(lp, router.buildBuyProgram());
        exerciseOrder = router.buildOrder(lp, router.buildExerciseProgram());
        settleOrder = router.buildOrder(lp, router.buildSettleProgram());
        expireOrder = router.buildOrder(lp, router.buildExpireProgram());
        poolId = router.hash(buyOrder);
    }

    function getPoolId() external view returns (bytes32) {
        return poolId;
    }

    function buyersLength() external view returns (uint256) {
        return buyers.length;
    }

    function positionsLength() external view returns (uint256) {
        return positionIds.length;
    }

    function positionIdAt(uint256 index) external view returns (uint256) {
        return positionIds[index];
    }

    function sumActiveLiability() external view returns (uint256 total) {
        for (uint256 i = 0; i < positionIds.length; ++i) {
            OptionPosition memory position = manager.getPosition(positionIds[i]);
            if (position.status == OptionStatus.ACTIVE || position.status == OptionStatus.EXERCISED) {
                total += position.notional;
            }
        }
    }

    function sumPremiums() external view returns (uint256 total) {
        for (uint256 i = 0; i < positionIds.length; ++i) {
            total += manager.getPosition(positionIds[i]).premium;
        }
    }

    function sumPayouts() external view returns (uint256 total) {
        for (uint256 i = 0; i < positionIds.length; ++i) {
            total += manager.getPosition(positionIds[i]).payout;
        }
    }

    function firstBrokenPayout() external view returns (bool broken) {
        for (uint256 i = 0; i < positionIds.length; ++i) {
            OptionPosition memory position = manager.getPosition(positionIds[i]);
            if (position.payout > position.notional) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    function openAndBuy(uint256 strikeSeed, uint256 quantitySeed, uint256 tenorSeed, uint256 buyerSeed) external {
        uint256 strike = bound(strikeSeed, 100e6, 10_000e6);
        uint256 quantity = bound(quantitySeed, 0.01e18, 20e18);
        uint256 notional = strike * quantity / 1e18;
        if (notional == 0 || notional > MAX_NOTIONAL) return;

        uint256 tenor = bound(tenorSeed, 1 hours, 300 days);
        uint256 expiry = block.timestamp + tenor;

        address buyer = buyers[buyerSeed % buyers.length];
        uint256 premium = manager.quotePremium(strike, quantity, expiry);
        if (premium == 0 || premium > notional) return;
        if (usdc.balanceOf(buyer) < premium) usdc.mint(buyer, 1_000_000e6);

        bytes memory data = _takerData(buyer, true, abi.encode(strike, quantity, expiry));
        vm.prank(buyer);
        try router.swap(buyOrder, address(usdc), address(weth), premium, data) {
            positionIds.push(manager.nextPositionId() - 1);
            ghostOpened += 1;
            ghostBought += 1;
        } catch { }
    }

    function exercisePosition(uint256 positionSeed) external {
        if (positionIds.length == 0) return;
        uint256 positionId = positionIds[positionSeed % positionIds.length];
        OptionPosition memory position = manager.getPosition(positionId);
        if (position.status != OptionStatus.ACTIVE) return;
        if (block.timestamp < position.expiry) vm.warp(position.expiry + 1);

        bytes memory data = _takerData(position.buyer, false, abi.encode(positionId, positionId));
        vm.prank(position.buyer);
        try router.swap(exerciseOrder, address(usdc), address(weth), 0, data) { } catch { }
    }

    function settlePosition(uint256 positionSeed, uint256 priceSeed) external {
        if (positionIds.length == 0) return;
        uint256 positionId = positionIds[positionSeed % positionIds.length];
        OptionPosition memory position = manager.getPosition(positionId);
        if (position.status != OptionStatus.ACTIVE && position.status != OptionStatus.EXERCISED) return;

        oracle.setSettlementPrice(position.expiry, bound(priceSeed, 100e18, 20_000e18));
        if (block.timestamp < position.expiry) vm.warp(position.expiry + 1);

        bytes memory data = _takerData(address(this), false, abi.encode(positionId));
        try router.swap(settleOrder, address(usdc), address(weth), 0, data) { } catch { }
    }

    function expirePosition(uint256 positionSeed, uint256 priceSeed) external {
        if (positionIds.length == 0) return;
        uint256 positionId = positionIds[positionSeed % positionIds.length];
        OptionPosition memory position = manager.getPosition(positionId);
        if (position.status != OptionStatus.ACTIVE) return;

        oracle.setSettlementPrice(position.expiry, bound(priceSeed, 100e18, 20_000e18));
        if (block.timestamp < position.expiry) vm.warp(position.expiry + 1);

        bytes memory data = _takerData(address(this), false, abi.encode(positionId));
        try router.swap(expireOrder, address(usdc), address(weth), 0, data) { } catch { }
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 30 days));
    }

    function setSpot(uint256 priceSeed) external {
        oracle.setSpot(bound(priceSeed, 500e18, 10_000e18));
    }

    function depositCollateral(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e6, 100_000e6);
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.push(lp, address(router), poolId, address(usdc), amount);
        vm.stopPrank();
        manager.syncPool(poolId);
        deposited += amount;
    }

    function withdrawCollateral(uint256 amountSeed) external {
        uint256 before = collateral.getPool(poolId).totalCollateral;
        uint256 reserved = collateral.getPool(poolId).reservedLiability;
        uint256 available = before > reserved ? before - reserved : 0;
        if (available == 0) return;

        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(lp);
        try router.withdrawCollateral(poolId, amount) {
            withdrawn += amount;
        } catch { }
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
}
