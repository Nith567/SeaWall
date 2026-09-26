// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IETHPriceOracle } from "../../contracts/interfaces/IETHPriceOracle.sol";

contract MockOracle is IETHPriceOracle {
    uint256 public spotPrice;
    mapping(uint256 expiry => uint256 price) public settlementPrices;

    function setSpot(uint256 price) external {
        spotPrice = price;
    }

    function setSettlementPrice(uint256 expiry, uint256 price) external {
        settlementPrices[expiry] = price;
    }

    function spot() external view returns (uint256) {
        return spotPrice;
    }

    function settlementPrice(uint256 expiry) external view returns (uint256) {
        return settlementPrices[expiry];
    }
}
