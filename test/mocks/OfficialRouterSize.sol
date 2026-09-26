// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";

/// @dev Size probe: measures the official router under this project's optimizer settings.
contract OfficialRouterSize is AquaSwapVMRouter {
    constructor() AquaSwapVMRouter(address(0xA9A), address(0xE7), address(this), "probe", "1") { }
}
