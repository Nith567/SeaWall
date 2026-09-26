// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SeawallRouter } from "../contracts/swapvm/SeawallRouter.sol";

/// @notice Deploys the SeawallRouter from inside a call.
/// @dev Some forge versions fail to decode the router's constructor arguments when the CREATE is a
///      top-level script transaction; creating it inside this call avoids that path.
contract RouterDeployer {
    function deploy(address aqua, address weth, address owner, address usdc) external returns (address) {
        return address(new SeawallRouter(aqua, weth, owner, usdc));
    }
}
