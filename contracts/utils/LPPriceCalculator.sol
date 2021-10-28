// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import '../libraries/HomoraMath.sol';
import "./PriceCalculator.sol";

interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract LPPriceCalculator is IPriceFeed {
    using SafeMath for uint256;
    using HomoraMath for uint256;

    address public constant priceCalculatorAddress = 0x3Fa849CBf0d57Fa28F777cF34430858E12532eEe;

    function getData(address pair) external view override returns (uint256) {
        address token0 = IPancakePair(pair).token0();
        address token1 = IPancakePair(pair).token1();
        uint totalSupply = IPancakePair(pair).totalSupply();
        (uint r0, uint r1, ) = IPancakePair(pair).getReserves();

        uint sqrtK = HomoraMath.sqrt(r0.mul(r1)).fdiv(totalSupply);
        uint px0 = PriceCalculator(priceCalculatorAddress).tokenPriceIn1e6USDC(token0, 1e18);
        uint px1 = PriceCalculator(priceCalculatorAddress).tokenPriceIn1e6USDC(token1, 1e18);
        uint fairPriceInBNB = sqrtK.mul(2).mul(HomoraMath.sqrt(px0)).div(2**56).mul(HomoraMath.sqrt(px1)).div(2**56);

        return fairPriceInBNB;
    }
}
