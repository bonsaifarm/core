// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IProxyFactory.sol";

interface IPriceFeed {
    function getData(address tokenAddress) external view returns (uint256);
}

// ALL decimal will scale to 1e18
contract PriceCalculator is IUpgradeableImplementation, Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 override public constant CONTRACT_IDENTIFIER = keccak256("PriceCalculator");

    struct PriceFeed {
        address oracleAddress;
        address onChainFetcher;
    }

    mapping(address => PriceFeed) public tokenPriceFeed;

    function initialize() external initializer {
        __Ownable_init();
    }

    function addFeeds(address[] memory args) external onlyOwner {
        uint256 len = args.length;
        require(len % 3 == 0, "bad_args");

        for (uint256 i = 0; i < len; i += 3) {
            tokenPriceFeed[args[i]] = PriceFeed(args[i + 1], args[i + 2]);
        }
    }

    function oracleValueOf(address oracleAddress, address tokenAddress, uint amount) internal view returns (uint256 valueInUSD) {
        uint256 price = IPriceFeed(oracleAddress).getData(tokenAddress);
        valueInUSD = price.mul(amount).div(10 ** IERC20Metadata(tokenAddress).decimals());
    }

    function tokenPriceIn1e6USDC(address tokenAddress, uint amount) view external returns (uint256 price) {
        PriceFeed storage feed = tokenPriceFeed[tokenAddress];

        require(feed.oracleAddress != address(0) || feed.onChainFetcher != address(0), "no_price_feed");
        uint256 pairPrice = 0;
        uint256 oraclePrice = 0;

        if (feed.onChainFetcher != address(0)) {
            pairPrice = oracleValueOf(feed.onChainFetcher, tokenAddress, amount);
        }

        if (feed.oracleAddress != address(0)) {
            oraclePrice = oracleValueOf(feed.oracleAddress, tokenAddress, amount);
        }

        if (feed.onChainFetcher == address(0)) {
            return oraclePrice;
        }

        if (feed.oracleAddress == address(0)) {
            return pairPrice;
        }

        return Math.min(oraclePrice, pairPrice);
    }

}

