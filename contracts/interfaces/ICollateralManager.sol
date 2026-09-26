// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Pool } from "./OptionTypes.sol";

/// @notice Collateral accounting surface used by the option lifecycle.
interface ICollateralManager {
    function createPool(bytes32 poolId, address maker, uint256 maxNotionalPerOption, uint256 maxTenor) external;

    function syncCollateral(bytes32 poolId, uint256 liveBalance) external;

    function reserve(bytes32 poolId, uint256 amount) external;

    function release(bytes32 poolId, uint256 amount) external;

    function recordPremium(bytes32 poolId, uint256 amount) external;

    function recordPayout(bytes32 poolId, uint256 amount) external;

    function recordWithdrawal(bytes32 poolId, uint256 amount) external;

    function getPool(bytes32 poolId) external view returns (Pool memory);

    function available(bytes32 poolId) external view returns (uint256);
}
