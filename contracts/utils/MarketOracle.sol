// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '../libraries/FixedPoint.sol';
import "@openzeppelin/contracts/access/AccessControl.sol";

import "../interfaces/IUniv2LikePair.sol";

interface IMarketOracle {
    function getData(address tokenAddress) external view returns (uint256);
}

// library with helper methods for oracles that are concerned with computing average prices
library UniswapV2OracleLibrary {
    using FixedPoint for *;

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(
        address pair
    ) internal view returns (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IUniv2LikePair(pair).price0CumulativeLast();
        price1Cumulative = IUniv2LikePair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IUniv2LikePair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative += uint(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            // counterfactual
            price1Cumulative += uint(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
}

contract MarketOracle is IMarketOracle, AccessControl {
    using FixedPoint for *;

    struct TokenPrice {
        uint    tokenNativePrice0CumulativeLast;
        uint    tokenNativePrice1CumulativeLast;
        uint    tokenValueInNativeAverage;
        uint32  tokenNativeBlockTimestampLast;
    }

    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // wMATIC
    address public constant WRAPPED_NATIVE_TOKEN = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    mapping(address => TokenPrice) public priceList;
    mapping(address => IUniv2LikePair) public tokenLP;

    address public controller;

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(CONFIGURATOR_ROLE, msg.sender);
        _setupRole(KEEPER_ROLE, msg.sender);
    }

    function _setTokenLP(address _token, address _tokenLP) private {
        tokenLP[_token] = IUniv2LikePair(_tokenLP);
        require(tokenLP[_token].token0() == WRAPPED_NATIVE_TOKEN || tokenLP[_token].token1() == WRAPPED_NATIVE_TOKEN, "no_native_token");

        uint tokenNativePrice0CumulativeLast = tokenLP[_token].price0CumulativeLast();
        uint tokenNativePrice1CumulativeLast = tokenLP[_token].price1CumulativeLast();

        (,,uint32 tokenNativeBlockTimestampLast) = tokenLP[_token].getReserves();

        delete priceList[_token]; // reset
        TokenPrice storage tokenPriceInfo = priceList[_token];

        tokenPriceInfo.tokenNativeBlockTimestampLast = tokenNativeBlockTimestampLast;
        tokenPriceInfo.tokenNativePrice0CumulativeLast = tokenNativePrice0CumulativeLast;
        tokenPriceInfo.tokenNativePrice1CumulativeLast = tokenNativePrice1CumulativeLast;
        tokenPriceInfo.tokenValueInNativeAverage = 0;

        _update(_token);
    }

    function setTokenLP(address[] memory tokenLPPairs) external onlyRole(CONFIGURATOR_ROLE) {
        require(tokenLPPairs.length % 2 == 0);
        uint length = tokenLPPairs.length;
        for (uint i = 0; i < length; i = i + 2) {
            _setTokenLP(tokenLPPairs[i], tokenLPPairs[i + 1]);
        }
    }

    function getTokenNativeRate(address tokenAddress) public view returns (uint256, uint256, uint32, uint256) {
        (uint price0Cumulative, uint price1Cumulative, uint32 _blockTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(tokenLP[tokenAddress]));
        if (_blockTimestamp == priceList[tokenAddress].tokenNativeBlockTimestampLast) {
            return (
                priceList[tokenAddress].tokenNativePrice0CumulativeLast,
                priceList[tokenAddress].tokenNativePrice1CumulativeLast,
                priceList[tokenAddress].tokenNativeBlockTimestampLast,
                priceList[tokenAddress].tokenValueInNativeAverage
            );
        }

        uint32 timeElapsed = (_blockTimestamp - priceList[tokenAddress].tokenNativeBlockTimestampLast);

        FixedPoint.uq112x112 memory tokenValueInNativeAverage =
            tokenLP[tokenAddress].token1() == WRAPPED_NATIVE_TOKEN
            ? FixedPoint.uq112x112(uint224(1e18 * (price0Cumulative - priceList[tokenAddress].tokenNativePrice0CumulativeLast) / timeElapsed))
            : FixedPoint.uq112x112(uint224(1e18 * (price1Cumulative - priceList[tokenAddress].tokenNativePrice1CumulativeLast) / timeElapsed));

        return (price0Cumulative, price1Cumulative, _blockTimestamp, tokenValueInNativeAverage.mul(1).decode144());
    }

    function _update(address tokenAddress) private {
        (uint tokenNativePrice0CumulativeLast, uint tokenNativePrice1CumulativeLast, uint32 tokenNativeBlockTimestampLast, uint256 tokenValueInNativeAverage) = getTokenNativeRate(tokenAddress);

        TokenPrice storage tokenPriceInfo = priceList[tokenAddress];

        tokenPriceInfo.tokenNativeBlockTimestampLast = tokenNativeBlockTimestampLast;
        tokenPriceInfo.tokenNativePrice0CumulativeLast = tokenNativePrice0CumulativeLast;
        tokenPriceInfo.tokenNativePrice1CumulativeLast = tokenNativePrice1CumulativeLast;
        tokenPriceInfo.tokenValueInNativeAverage = tokenValueInNativeAverage;
    }

    // Update "last" state variables to current values
    function update(address[] memory tokenAddress) external onlyRole(KEEPER_ROLE) {
        uint length = tokenAddress.length;
        for (uint i = 0; i < length; ++i) {
            _update(tokenAddress[i]);
        }
    }

    // Return the average price since last update
    function getData(address tokenAddress) external override view returns (uint256) {
        (,,, uint tokenValueInNativeAverage) = getTokenNativeRate(tokenAddress);
        return (tokenValueInNativeAverage);
    }

}