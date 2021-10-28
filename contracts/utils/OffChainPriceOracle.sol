// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PriceCalculator.sol";

contract OffChainPriceOracle is Ownable, IPriceFeed {

    mapping(address => uint256) tokenPriceIn1e6USDC;

    function update(address[] memory token, uint256[] memory price) external onlyOwner {
        require(token.length == price.length);
        uint256 len = token.length;

        for (uint256 i = 0; i < len; ++i) {
            tokenPriceIn1e6USDC[token[i]] = price[i];
        }
    }

    function getData(address token) external view override returns(uint256) {
        return tokenPriceIn1e6USDC[token];
    }

}