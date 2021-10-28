// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./PriceCalculator.sol";

interface IZap {
    function tokenPriceIn1e6USDC(address fromToken) external view returns(uint);
}

contract OnChainPriceFetcher is IPriceFeed {
    function getData(address token) external view override returns(uint256) {
        return IZap(0x092b9E2cCf536C93aE5896A0f308D03Cc56D5394).tokenPriceIn1e6USDC(token);
    }
}