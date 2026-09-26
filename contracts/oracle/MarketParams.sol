// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MarketParams
/// @notice Model parameters (implied volatility, risk-free rate) used by the pricing engine.
///
/// @dev For the MVP these are explicitly defined market parameters, not market-implied values.
///      The frontend must label quotes as model-based. Both parameters are bounded so that a
///      misconfiguration cannot produce absurd quotes.
contract MarketParams is Ownable {
    uint256 public constant MAX_VOLATILITY = 5e18; // 500%
    uint256 public constant MAX_RISK_FREE_RATE = 0.5e18; // 50%

    uint256 public volatility;
    uint256 public riskFreeRate;

    error MarketParamsInvalidVolatility(uint256 volatility);
    error MarketParamsInvalidRiskFreeRate(uint256 riskFreeRate);

    event VolatilityUpdated(uint256 oldValue, uint256 newValue);
    event RiskFreeRateUpdated(uint256 oldValue, uint256 newValue);

    constructor(address owner_, uint256 volatility_, uint256 riskFreeRate_) Ownable(owner_) {
        _setVolatility(volatility_);
        _setRiskFreeRate(riskFreeRate_);
    }

    function setVolatility(uint256 volatility_) external onlyOwner {
        _setVolatility(volatility_);
    }

    function setRiskFreeRate(uint256 riskFreeRate_) external onlyOwner {
        _setRiskFreeRate(riskFreeRate_);
    }

    function _setVolatility(uint256 volatility_) internal {
        if (volatility_ == 0 || volatility_ > MAX_VOLATILITY) revert MarketParamsInvalidVolatility(volatility_);
        emit VolatilityUpdated(volatility, volatility_);
        volatility = volatility_;
    }

    function _setRiskFreeRate(uint256 riskFreeRate_) internal {
        if (riskFreeRate_ > MAX_RISK_FREE_RATE) revert MarketParamsInvalidRiskFreeRate(riskFreeRate_);
        emit RiskFreeRateUpdated(riskFreeRate, riskFreeRate_);
        riskFreeRate = riskFreeRate_;
    }
}
