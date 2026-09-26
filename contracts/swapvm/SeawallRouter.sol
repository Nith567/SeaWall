// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { AquaOpcodes } from "@1inch/swap-vm/src/opcodes/AquaOpcodes.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { OptionInstructions } from "./OptionInstructions.sol";

/// @title SeawallRouter
/// @notice The Aqua app and SwapVM router that executes the Seawall lifecycle.
///
/// @dev The router extends the official SwapVM with five custom instructions appended after the
///      official `AquaOpcodes` table (all stock opcode numbers are preserved):
///
///      | index | instruction      | purpose                                      |
///      |-------|------------------|----------------------------------------------|
///      | +0    | OPTION_OPEN      | validate terms, reserve collateral, stage    |
///      | +1    | OPTION_BUY       | validate premium, create position            |
///      | +2    | OPTION_EXERCISE  | buyer-only exercise in the European window   |
///      | +3    | OPTION_SETTLE    | deterministic payout via Aqua pull           |
///      | +4    | OPTION_EXPIRE    | release collateral for OTM / late positions  |
///
///      The router is the Aqua `app`: makers `ship()` their strategies to `address(this)`, the VM
///      reads balances with `safeBalances`, premiums are settled with `push` and payouts with `pull`.
///      It also exposes the LP collateral helpers (register/sync/withdraw) and canonical order
///      builders so the frontend never has to re-implement program encoding.
contract SeawallRouter is SwapVM, AquaOpcodes, OptionInstructions, ReentrancyGuard {
    /// @dev Offsets of the custom instructions relative to the end of the official opcode table.
    uint256 internal constant OPTION_OPEN_OFFSET = 0;
    uint256 internal constant OPTION_BUY_OFFSET = 1;
    uint256 internal constant OPTION_EXERCISE_OFFSET = 2;
    uint256 internal constant OPTION_SETTLE_OFFSET = 3;
    uint256 internal constant OPTION_EXPIRE_OFFSET = 4;
    uint256 internal constant OPTION_INSTRUCTION_COUNT = 5;

    error RouterManagerAlreadySet();

    constructor(
        address aqua_,
        address weth_,
        address owner_,
        address usdc_
    )
        SwapVM(aqua_, weth_, owner_, "Seawall", "1.0.0")
        AquaOpcodes(aqua_)
        OptionInstructions(usdc_, weth_)
    { }

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------

    /// @notice One-time wiring of the option manager and collateral manager.
    function setOptionManager(address manager_, address collateral_) external onlyOwner {
        if (address(optionManager) != address(0)) revert RouterManagerAlreadySet();
        _setOptionManager(manager_, collateral_);
    }

    /// @dev SwapVM dispatch: the router's instruction table = official AquaOpcodes + 5 custom ones.
    function _instructions()
        internal
        pure
        override
        returns (function(Context memory, bytes calldata) internal[] memory result)
    {
        function(Context memory, bytes calldata) internal[] memory base = _opcodes();
        result = new function(Context memory, bytes calldata) internal[](base.length + OPTION_INSTRUCTION_COUNT);
        for (uint256 i = 0; i < base.length; ++i) {
            result[i] = base[i];
        }
        result[base.length + OPTION_OPEN_OFFSET] = _optionOpenXD;
        result[base.length + OPTION_BUY_OFFSET] = _optionBuyXD;
        result[base.length + OPTION_EXERCISE_OFFSET] = _optionExerciseXD;
        result[base.length + OPTION_SETTLE_OFFSET] = _optionSettleXD;
        result[base.length + OPTION_EXPIRE_OFFSET] = _optionExpireXD;
    }

    /// @dev Aqua registry reference (from SwapVM).
    function _aqua() internal view override returns (IAqua) {
        return AQUA;
    }

    // ---------------------------------------------------------------------
    // Canonical order builders
    // ---------------------------------------------------------------------

    /// @notice Program for the atomic OPEN + BUY execution.
    function buildBuyProgram() public pure returns (bytes memory) {
        uint256 base = _opcodes().length;
        return bytes.concat(_encode(base + OPTION_OPEN_OFFSET, ""), _encode(base + OPTION_BUY_OFFSET, ""));
    }

    /// @notice Program for EXERCISE + SETTLE (buyer gets paid atomically).
    function buildExerciseProgram() public pure returns (bytes memory) {
        uint256 base = _opcodes().length;
        return bytes.concat(_encode(base + OPTION_EXERCISE_OFFSET, ""), _encode(base + OPTION_SETTLE_OFFSET, ""));
    }

    /// @notice Program for a standalone SETTLE (keeper or auto-settlement).
    function buildSettleProgram() public pure returns (bytes memory) {
        return _encode(_opcodes().length + OPTION_SETTLE_OFFSET, "");
    }

    /// @notice Program for OPTION_EXPIRE.
    function buildExpireProgram() public pure returns (bytes memory) {
        return _encode(_opcodes().length + OPTION_EXPIRE_OFFSET, "");
    }

    /// @notice Builds a canonical Aqua order for a maker from one of the programs above.
    /// @dev `allowZeroAmountIn` is always enabled: option instructions never move a positive
    ///      `amountIn` except for the buy program, where the premium check enforces `amountIn > 0`.
    function buildOrder(address maker, bytes calldata program) external pure returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                receiver: address(0),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: true,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: program
            })
        );
    }

    function _encode(uint256 opcode, bytes memory args) internal pure returns (bytes memory) {
        require(args.length < 256, "SeawallRouter: args too long");
        return abi.encodePacked(uint8(opcode), uint8(args.length), args);
    }

    // ---------------------------------------------------------------------
    // LP collateral helpers (Aqua-native)
    // ---------------------------------------------------------------------

    /// @notice Withdraws available collateral back to the maker. Reserved liability stays locked.
    /// @dev Aqua-native withdrawal: the router (the app) pulls from the maker's own strategy balance
    ///      back to the maker, so no tokens ever leave the maker's control beyond the reservation.
    function withdrawCollateral(bytes32 poolId, uint256 amount) external nonReentrant {
        optionManager.withdrawCollateral(poolId, msg.sender, amount);
        _aquaPull(msg.sender, poolId, USDC, amount, msg.sender);
    }
}
