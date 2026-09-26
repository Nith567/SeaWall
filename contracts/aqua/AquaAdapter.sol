// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

/// @title AquaAdapter
/// @notice Thin, safe wrapper around the official Aqua registry used by the options router.
///
/// @dev Aqua balances are maker allowances, not escrow: the maker keeps custody and the app can
///      only move tokens the maker actually made available for the `(maker, app, strategyHash)`
///      tuple. Every pull is therefore checked against the live Aqua balance before it is attempted,
///      and the system fails safely (reverts) if the balance is unavailable.
abstract contract AquaAdapter {
    /// @dev Aqua marks docked strategies with tokensCount == 0xff.
    uint8 internal constant AQUA_DOCKED = 0xff;

    error AquaStrategyNotActive(address maker, bytes32 strategyHash, address token, uint8 tokensCount);
    error AquaBalanceInsufficient(
        address maker, bytes32 strategyHash, address token, uint256 available, uint256 required
    );

    /// @dev Implemented by the router (which inherits SwapVM and holds the immutable Aqua reference).
    function _aqua() internal view virtual returns (IAqua);

    /// @notice Raw Aqua balance plus token count for a maker strategy.
    function _aquaRaw(
        address maker,
        bytes32 strategyHash,
        address token
    )
        internal
        view
        returns (uint256 balance, uint8 tokensCount)
    {
        (uint248 rawBalance, uint8 count) = _aqua().rawBalances(maker, address(this), strategyHash, token);
        return (uint256(rawBalance), count);
    }

    /// @notice Pulls `amount` of `token` from the maker's Aqua balance to `to`, after checking it.
    function _aquaPull(address maker, bytes32 strategyHash, address token, uint256 amount, address to) internal {
        (uint256 available, uint8 tokensCount) = _aquaRaw(maker, strategyHash, token);
        if (tokensCount == 0 || tokensCount == AQUA_DOCKED) {
            revert AquaStrategyNotActive(maker, strategyHash, token, tokensCount);
        }
        if (available < amount) {
            revert AquaBalanceInsufficient(maker, strategyHash, token, available, amount);
        }
        _aqua().pull(maker, strategyHash, token, amount, to);
    }
}
