// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context, ContextLib } from "@1inch/swap-vm/src/libs/VM.sol";

import { IOptionManager } from "../interfaces/IOptionManager.sol";
import { ICollateralManager } from "../interfaces/ICollateralManager.sol";
import { Pool } from "../interfaces/OptionTypes.sol";
import { AquaAdapter } from "../aqua/AquaAdapter.sol";

/// @title OptionInstructions
/// @notice Custom SwapVM instructions that encode the option lifecycle.
///
/// @dev These are genuine SwapVM instruction handlers: they receive the VM `Context` and the
///      instruction args and are dispatched by the router's opcode table. They are appended to the
///      official `AquaOpcodes` table, so all stock opcodes keep their numbers and the option
///      instructions live in the next free slots.
///
///      Program layouts (built by `SeawallRouter`):
///      - buy:     `[OPTION_OPEN][OPTION_BUY]`            taker args: abi.encode(strike, quantity, expiry)
///      - exercise `[OPTION_EXERCISE][OPTION_SETTLE]`     taker args: abi.encode(positionId, positionId)
///      - settle:  `[OPTION_SETTLE]`                      taker args: abi.encode(positionId)
///      - expire:  `[OPTION_EXPIRE]`                      taker args: abi.encode(positionId)
///
///      `amountIn` carries the premium for the buy program. Because SwapVM requires a strictly
///      positive output amount, every option instruction settles a 1 wei WETH "execution marker"
///      through the regular transfer phase (the LP ships a dust WETH balance for that purpose).
///      Option payouts are moved inside `OPTION_SETTLE` straight from the pool's Aqua balance to the
///      buyer, so the marker never interferes with the economics.
abstract contract OptionInstructions is AquaAdapter {
    using ContextLib for Context;

    /// @dev 1 wei of WETH pulled from the maker as the VM output amount.
    uint256 internal constant EXECUTION_MARKER = 1;

    IOptionManager internal optionManager;
    ICollateralManager internal collateralManager;

    address internal immutable USDC;
    address internal immutable WETH;

    error OptionInstructionInvalidTokens(address tokenIn, address tokenOut);
    error OptionInstructionManagerNotSet();
    error OptionInstructionMakerMismatch(address expected, address actual);

    constructor(address usdc_, address weth_) {
        USDC = usdc_;
        WETH = weth_;
    }

    /// @dev One-time wiring of the option manager and collateral manager.
    function _setOptionManager(address manager_, address collateral_) internal {
        optionManager = IOptionManager(manager_);
        collateralManager = ICollateralManager(collateral_);
    }

    function _requireOptionTokens(Context memory ctx) private view {
        if (ctx.query.tokenIn != USDC || ctx.query.tokenOut != WETH) {
            revert OptionInstructionInvalidTokens(ctx.query.tokenIn, ctx.query.tokenOut);
        }
    }

    function _requireManager() private view returns (IOptionManager) {
        IOptionManager manager = optionManager;
        if (address(manager) == address(0)) revert OptionInstructionManagerNotSet();
        return manager;
    }

    // ---------------------------------------------------------------------
    // OPTION_OPEN
    // ---------------------------------------------------------------------

    /// @dev Validates the option parameters, reserves `strike * quantity` of LP collateral and stages
    ///      a pending option. The position itself is only created by `OPTION_BUY`.
    function _optionOpenXD(Context memory ctx, bytes calldata) internal {
        _requireOptionTokens(ctx);

        bytes calldata args = ctx.tryChopTakerArgs(96);
        (uint256 strike, uint256 quantity, uint256 expiry) = abi.decode(args, (uint256, uint256, uint256));

        _requireManager().open(ctx.query.orderHash, ctx.query.maker, ctx.query.taker, strike, quantity, expiry);

        ctx.swap.amountOut = EXECUTION_MARKER;
    }

    // ---------------------------------------------------------------------
    // OPTION_BUY
    // ---------------------------------------------------------------------

    /// @dev Validates that the premium moved by the VM matches the on-chain quote and creates the
    ///      position. Runs in the same atomic execution as `OPTION_OPEN`.
    function _optionBuyXD(Context memory ctx, bytes calldata) internal {
        _requireOptionTokens(ctx);

        _requireManager().buy(ctx.query.orderHash, ctx.query.taker, ctx.swap.amountIn);

        ctx.swap.amountOut = EXECUTION_MARKER;
    }

    // ---------------------------------------------------------------------
    // OPTION_EXERCISE
    // ---------------------------------------------------------------------

    /// @dev Buyer-only exercise inside the European exercise window, in the money.
    function _optionExerciseXD(Context memory ctx, bytes calldata) internal {
        _requireOptionTokens(ctx);

        uint256 positionId = abi.decode(ctx.tryChopTakerArgs(32), (uint256));

        _requireManager().exercise(positionId, ctx.query.taker);

        ctx.swap.amountOut = EXECUTION_MARKER;
    }

    // ---------------------------------------------------------------------
    // OPTION_SETTLE
    // ---------------------------------------------------------------------

    /// @dev Deterministic settlement: the payout is computed by the manager and pulled from the
    ///      pool's Aqua balance to the buyer. Anyone may trigger it; the caller cannot alter the
    ///      payout, the settlement price or the recipient.
    function _optionSettleXD(Context memory ctx, bytes calldata) internal {
        _requireOptionTokens(ctx);

        uint256 positionId = abi.decode(ctx.tryChopTakerArgs(32), (uint256));

        (address buyer, bytes32 pool, uint256 payout) = _requireManager().settle(positionId);

        if (payout > 0) {
            Pool memory poolData = collateralManager.getPool(pool);
            if (poolData.maker != ctx.query.maker) {
                revert OptionInstructionMakerMismatch(poolData.maker, ctx.query.maker);
            }
            _aquaPull(poolData.maker, pool, USDC, payout, buyer);
        }

        ctx.swap.amountOut = EXECUTION_MARKER;
    }

    // ---------------------------------------------------------------------
    // OPTION_EXPIRE
    // ---------------------------------------------------------------------

    /// @dev Releases the reserved collateral of an OTM position, or of an ITM position whose
    ///      exercise window has closed. Permissionless.
    function _optionExpireXD(Context memory ctx, bytes calldata) internal {
        _requireOptionTokens(ctx);

        uint256 positionId = abi.decode(ctx.tryChopTakerArgs(32), (uint256));

        _requireManager().expire(positionId);

        ctx.swap.amountOut = EXECUTION_MARKER;
    }
}
