// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice ETH/USD price source used for quoting and settlement.
/// @dev All prices are 1e18 fixed point (USD per 1 ETH).
interface IETHPriceOracle {
    /// @notice Current spot price, for model-based quoting.
    function spot() external view returns (uint256);

    /// @notice Settlement price for an option that expired at `expiry`.
    /// @dev MUST revert until a price observed at or after `expiry` is available, and MUST be
    ///      resistant to single-block manipulation (e.g. a decentralised oracle round).
    function settlementPrice(uint256 expiry) external view returns (uint256);
}
