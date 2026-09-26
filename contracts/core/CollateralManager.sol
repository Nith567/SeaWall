// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Pool } from "../interfaces/OptionTypes.sol";
import { ICollateralManager } from "../interfaces/ICollateralManager.sol";

/// @title CollateralManager
/// @notice Tracks LP collateral and option liabilities per pool.
///
/// @dev Accounting model:
///      - `totalCollateral` mirrors the USDC balance the maker actually made available through Aqua
///        for the pool's strategy. It is synced from Aqua before every lifecycle operation and is
///        cached here for accounting and invariant checks.
///      - `reservedLiability` is the sum of `maximumPayout` (strike * quantity) of all live options.
///        A put is fully collateralised against the worst case (ETH -> 0), never against current
///        intrinsic value.
///      - `availableCollateral = totalCollateral - reservedLiability`.
///      - `premiumEarned` and `payoutsPaid` are cumulative PnL counters for the LP dashboard.
///
///      The only way `totalCollateral` can fall below `reservedLiability` is a maker docking the
///      Aqua strategy unilaterally (Aqua is an allowance layer, not escrow). In that case new
///      reservations revert and settlement fails safely on the Aqua balance check.
contract CollateralManager is Ownable, ICollateralManager {
    error CollateralOnlyManager(address caller);
    error CollateralManagerAlreadySet();
    error CollateralPoolExists(bytes32 poolId);
    error CollateralPoolNotRegistered(bytes32 poolId);
    error CollateralZeroMaker();
    error CollateralInsufficient(bytes32 poolId, uint256 total, uint256 reserved, uint256 requested);
    error CollateralReservedUnderflow(bytes32 poolId, uint256 reserved, uint256 requested);
    error CollateralTotalUnderflow(bytes32 poolId, uint256 total, uint256 requested);

    /// @notice The option manager allowed to mutate accounting.
    address public manager;

    mapping(bytes32 poolId => Pool) private _pools;

    modifier onlyManager() {
        if (msg.sender != manager) revert CollateralOnlyManager(msg.sender);
        _;
    }

    constructor(address owner_) Ownable(owner_) { }

    /// @notice One-time wiring of the option manager.
    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert CollateralManagerAlreadySet();
        manager = manager_;
    }

    // ---------------------------------------------------------------------
    // Mutating accounting (manager only)
    // ---------------------------------------------------------------------

    function createPool(
        bytes32 poolId,
        address maker,
        uint256 maxNotionalPerOption,
        uint256 maxTenor
    )
        external
        onlyManager
    {
        if (maker == address(0)) revert CollateralZeroMaker();
        if (_pools[poolId].active) revert CollateralPoolExists(poolId);
        _pools[poolId] = Pool({
            maker: maker,
            totalCollateral: 0,
            reservedLiability: 0,
            premiumEarned: 0,
            payoutsPaid: 0,
            maxNotionalPerOption: maxNotionalPerOption,
            maxTenor: maxTenor,
            active: true
        });
    }

    function syncCollateral(bytes32 poolId, uint256 liveBalance) external onlyManager {
        Pool storage pool = _pool(poolId);
        pool.totalCollateral = liveBalance;
    }

    function reserve(bytes32 poolId, uint256 amount) external onlyManager {
        Pool storage pool = _pool(poolId);
        if (pool.totalCollateral < pool.reservedLiability + amount) {
            revert CollateralInsufficient(poolId, pool.totalCollateral, pool.reservedLiability, amount);
        }
        pool.reservedLiability += amount;
    }

    function release(bytes32 poolId, uint256 amount) external onlyManager {
        Pool storage pool = _pool(poolId);
        if (amount > pool.reservedLiability) {
            revert CollateralReservedUnderflow(poolId, pool.reservedLiability, amount);
        }
        unchecked {
            pool.reservedLiability -= amount;
        }
    }

    function recordPremium(bytes32 poolId, uint256 amount) external onlyManager {
        Pool storage pool = _pool(poolId);
        pool.premiumEarned += amount;
        pool.totalCollateral += amount;
    }

    function recordPayout(bytes32 poolId, uint256 amount) external onlyManager {
        Pool storage pool = _pool(poolId);
        if (amount > pool.totalCollateral) {
            revert CollateralTotalUnderflow(poolId, pool.totalCollateral, amount);
        }
        pool.payoutsPaid += amount;
        unchecked {
            pool.totalCollateral -= amount;
        }
    }

    function recordWithdrawal(bytes32 poolId, uint256 amount) external onlyManager {
        Pool storage pool = _pool(poolId);
        if (amount > pool.totalCollateral) {
            revert CollateralTotalUnderflow(poolId, pool.totalCollateral, amount);
        }
        unchecked {
            pool.totalCollateral -= amount;
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getPool(bytes32 poolId) external view returns (Pool memory) {
        return _pools[poolId];
    }

    function available(bytes32 poolId) external view returns (uint256) {
        Pool storage pool = _pools[poolId];
        return pool.totalCollateral > pool.reservedLiability ? pool.totalCollateral - pool.reservedLiability : 0;
    }

    function _pool(bytes32 poolId) private view returns (Pool storage pool) {
        pool = _pools[poolId];
        if (!pool.active) revert CollateralPoolNotRegistered(poolId);
    }
}
