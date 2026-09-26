// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraits, MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";

import { SeawallRouter } from "../../contracts/swapvm/SeawallRouter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Verifies that the custom instructions are appended to the official opcode table with
///         stable encoding, and that the canonical order builder is well formed.
contract RouterProgramsTest is Test {
    using MakerTraitsLib for MakerTraits;

    /// @dev The official AquaOpcodes table exposes 34 dispatchable instructions (index 0..33).
    uint256 internal constant BASE_OPCODE_COUNT = 34;

    SeawallRouter internal router;

    function setUp() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        router = new SeawallRouter(address(0xA9A), address(weth), address(this), address(usdc));
    }

    function testCustomOpcodesAreAppended() public view {
        // buy = [OPTION_OPEN][OPTION_BUY] = [34, 0][35, 0]
        assertEq(router.buildBuyProgram(), hex"22002300", "buy program");
        // exercise = [OPTION_EXERCISE][OPTION_SETTLE] = [36, 0][37, 0]
        assertEq(router.buildExerciseProgram(), hex"24002500", "exercise program");
        // settle = [OPTION_SETTLE] = [37, 0]
        assertEq(router.buildSettleProgram(), hex"2500", "settle program");
        // expire = [OPTION_EXPIRE] = [38, 0]
        assertEq(router.buildExpireProgram(), hex"2600", "expire program");
        assertEq(BASE_OPCODE_COUNT, 34, "official AquaOpcodes table size");
    }

    function testOrderTraits() public view {
        address maker = address(0xB0B);
        ISwapVM.Order memory order = router.buildOrder(maker, router.buildBuyProgram());

        assertEq(order.maker, maker);
        assertTrue(order.traits.useAquaInsteadOfSignature(), "aqua mode");
        assertTrue(order.traits.allowZeroAmountIn(), "premium check enforces amountIn > 0");
        assertFalse(order.traits.shouldUnwrapWeth());
        assertEq(order.traits.receiver(maker), maker);
    }

    function testOrderHashIsStrategyHash() public view {
        address maker = address(0xB0B);
        ISwapVM.Order memory order = router.buildOrder(maker, router.buildBuyProgram());
        assertEq(router.hash(order), keccak256(abi.encode(order)), "aqua order hash");
    }

    function testDistinctProgramsHaveDistinctHashes() public view {
        address maker = address(0xB0B);
        bytes32 buy = router.hash(router.buildOrder(maker, router.buildBuyProgram()));
        bytes32 exercise = router.hash(router.buildOrder(maker, router.buildExerciseProgram()));
        bytes32 settle = router.hash(router.buildOrder(maker, router.buildSettleProgram()));
        bytes32 expire = router.hash(router.buildOrder(maker, router.buildExpireProgram()));
        assertTrue(buy != exercise && buy != settle && buy != expire);
        assertTrue(exercise != settle && exercise != expire && settle != expire);
    }
}
