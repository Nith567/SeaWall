// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IOptionManager } from "../../contracts/interfaces/IOptionManager.sol";

/// @notice Test double for the SwapVM router: forwards calls to the option manager so lifecycle
///         unit tests can run without deploying the full Aqua/SwapVM stack.
contract MockRouter {
    IOptionManager public manager;

    constructor() { }

    function setManager(IOptionManager manager_) external {
        manager = manager_;
    }

    function open(
        bytes32 orderHash,
        address maker,
        address buyer,
        uint256 strike,
        uint256 quantity,
        uint256 expiry
    )
        external
        returns (uint256)
    {
        return manager.open(orderHash, maker, buyer, strike, quantity, expiry);
    }

    function buy(bytes32 orderHash, address buyer, uint256 premiumPaid) external returns (uint256) {
        return manager.buy(orderHash, buyer, premiumPaid);
    }

    function exercise(uint256 positionId, address caller) external {
        manager.exercise(positionId, caller);
    }

    function settle(uint256 positionId) external returns (address, bytes32, uint256) {
        return manager.settle(positionId);
    }

    function expire(uint256 positionId) external {
        manager.expire(positionId);
    }
}
