// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IETHPriceOracle } from "../interfaces/IETHPriceOracle.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkETHOracle
/// @notice ETH/USD oracle adapter for quoting and settlement.
///
/// @dev Manipulation awareness:
///      - `spot()` requires a fresh round (configurable staleness bound) and a positive answer.
///      - `settlementPrice(expiry)` only accepts a round observed at or after `expiry`, and within
///        a configurable delay. A single instantaneous DEX price is never used, and no centralised
///        backend is involved.
///
///      Production deployments should additionally consider a TWAP / exchange-rate feed for the
///      settlement leg; this adapter is intentionally small and swappable behind `IETHPriceOracle`.
contract ChainlinkETHOracle is IETHPriceOracle, Ownable {
    AggregatorV3Interface public immutable feed;
    uint8 public immutable feedDecimals;

    /// @notice Maximum age of the spot round, in seconds.
    uint256 public immutable maxSpotStaleness;
    /// @notice Maximum delay between expiry and the first accepted settlement round, in seconds.
    uint256 public immutable maxSettlementDelay;

    error ChainlinkPriceNotPositive(int256 answer);
    error ChainlinkStaleSpotPrice(uint256 updatedAt, uint256 timestamp, uint256 maxStaleness);
    error ChainlinkSettlementNotExpired(uint256 expiry, uint256 timestamp);
    error ChainlinkSettlementNotAvailable(uint256 expiry, uint256 updatedAt);
    error ChainlinkSettlementTooStale(uint256 expiry, uint256 updatedAt, uint256 maxDelay);

    constructor(address owner_, address feed_, uint256 maxSpotStaleness_, uint256 maxSettlementDelay_) Ownable(owner_) {
        feed = AggregatorV3Interface(feed_);
        feedDecimals = AggregatorV3Interface(feed_).decimals();
        maxSpotStaleness = maxSpotStaleness_;
        maxSettlementDelay = maxSettlementDelay_;
    }

    function spot() external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert ChainlinkPriceNotPositive(answer);
        if (updatedAt == 0 || block.timestamp < updatedAt || block.timestamp - updatedAt > maxSpotStaleness) {
            revert ChainlinkStaleSpotPrice(updatedAt, block.timestamp, maxSpotStaleness);
        }
        return _scale(uint256(answer));
    }

    function settlementPrice(uint256 expiry) external view returns (uint256) {
        if (block.timestamp < expiry) revert ChainlinkSettlementNotExpired(expiry, block.timestamp);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert ChainlinkPriceNotPositive(answer);
        if (updatedAt < expiry) revert ChainlinkSettlementNotAvailable(expiry, updatedAt);
        if (updatedAt - expiry > maxSettlementDelay) {
            revert ChainlinkSettlementTooStale(expiry, updatedAt, maxSettlementDelay);
        }
        return _scale(uint256(answer));
    }

    function _scale(uint256 price) internal view returns (uint256) {
        uint8 decimals = feedDecimals;
        if (decimals == 18) return price;
        if (decimals < 18) return price * (10 ** (18 - decimals));
        return price / (10 ** (decimals - 18));
    }
}
