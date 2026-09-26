// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { OptionPosition, PendingOption, PoolState } from "./OptionTypes.sol";

/// @notice Option lifecycle surface. State-changing entry points are restricted to the router
///         (the Aqua app that executes the SwapVM programs).
interface IOptionManager {
    function registerPool(bytes32 poolId, uint256 maxNotionalPerOption, uint256 maxTenor) external;

    function syncPool(bytes32 poolId) external;

    function open(
        bytes32 orderHash,
        address maker,
        address buyer,
        uint256 strike,
        uint256 quantity,
        uint256 expiry
    )
        external
        returns (uint256 notional);

    function buy(bytes32 orderHash, address buyer, uint256 premiumPaid) external returns (uint256 positionId);

    function exercise(uint256 positionId, address caller) external;

    function settle(uint256 positionId) external returns (address buyer, bytes32 pool, uint256 payout);

    function expire(uint256 positionId) external;

    function cancelPending(bytes32 orderHash) external;

    function withdrawCollateral(bytes32 poolId, address caller, uint256 amount) external;

    function getPosition(uint256 positionId) external view returns (OptionPosition memory);

    function getPending(bytes32 orderHash) external view returns (PendingOption memory);

    function poolState(bytes32 poolId) external view returns (PoolState memory);

    function quotePremium(uint256 strike, uint256 quantity, uint256 expiry) external view returns (uint256);

    function nextPositionId() external view returns (uint256);
}
