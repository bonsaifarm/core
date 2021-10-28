// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface ICurveCryptoSwap{
    function token() external view returns (address);
    function coins(uint256 i) external view returns (address);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

interface ICurveCryptoSwap3 is ICurveCryptoSwap{
    function calc_token_amount(uint256[3] calldata amounts, bool is_deposit) external view returns (uint256);
    function add_liquidity(uint256[3] calldata amounts, uint256 min_mint_amount, bool _use_underlying) external returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount, bool _use_underlying) external returns (uint256);
    function calc_withdraw_one_coin(uint256 token_amount, int128 i) external view returns (uint256);
}

interface ICurveCryptoSwap5 is ICurveCryptoSwap{
    function calc_token_amount(uint256[5] calldata amounts, bool is_deposit) external view returns (uint256);
    function add_liquidity(uint256[5] calldata amounts, uint256 min_mint_amount) external;
    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount) external;
    function remove_liquidity(uint256 amount, uint256[5] calldata min_amounts) external;
    function calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view returns (uint256);
}

contract CurveAdapter is Initializable {
    using SafeERC20 for IERC20;

    struct CurveConfig {
        address pair;
        address minter;
        address[] tokens;
        mapping(address => uint256) tokenIndex;
    }

    address public constant USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public constant USD_BTC_ETH = 0x8096ac61db23291252574D49f036f0f9ed8ab390;
    address public constant DAI_USDC_USDT = 0xE7a24EF0C5e95Ffb0f6684b813A78F2a3AD7D171;
    address public constant USD_BTC_ETH_V3 = 0xdAD97F7713Ae9437fa9249920eC8507e5FbB23d3;

    mapping(address => CurveConfig) public config;

    function initialize() public initializer {
        config[USD_BTC_ETH].pair = USD_BTC_ETH;
        config[USD_BTC_ETH].minter = 0x3FCD5De6A9fC8A99995c406c77DDa3eD7E406f81;
        config[USD_BTC_ETH].tokens = [
            0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174,
            0xc2132D05D31c914a87C6611C10748AEb04B58e8F,
            0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6,
            0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619
        ];

        uint i;
        for (i = 0; i < config[USD_BTC_ETH].tokens.length; ++i) {
            config[USD_BTC_ETH].tokenIndex[config[USD_BTC_ETH].tokens[i]] = i;
        }

        config[USD_BTC_ETH_V3].pair = USD_BTC_ETH_V3;
        config[USD_BTC_ETH_V3].minter = 0x1d8b86e3D88cDb2d34688e87E72F388Cb541B7C8;
        config[USD_BTC_ETH_V3].tokens = [
            0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174,
            0xc2132D05D31c914a87C6611C10748AEb04B58e8F,
            0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6,
            0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619
        ];

        for (i = 0; i < config[USD_BTC_ETH_V3].tokens.length; ++i) {
            config[USD_BTC_ETH_V3].tokenIndex[config[USD_BTC_ETH_V3].tokens[i]] = i;
        }

        config[DAI_USDC_USDT].pair = DAI_USDC_USDT;
        config[DAI_USDC_USDT].minter = 0x445FE580eF8d70FF569aB36e80c647af338db351;
        config[DAI_USDC_USDT].tokens = [
            0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174,
            0xc2132D05D31c914a87C6611C10748AEb04B58e8F
        ];

        for (i = 0; i < config[DAI_USDC_USDT].tokens.length; ++i) {
            config[DAI_USDC_USDT].tokenIndex[config[DAI_USDC_USDT].tokens[i]] = i;
        }
    }

    // --------------------------------------------------------------
    // User Read Interface
    // --------------------------------------------------------------

    function getTokenIndexFromOriginalTokens(address pair, address token) public view returns (uint256) {
        uint256 index = config[pair].tokenIndex[token];
        if (config[pair].tokens[index] == token) {
            return index;
        }
        return type(uint256).max;
    }

    function getTokenAmountOut(address pair, address token, uint256 amount) public view returns (uint256) {
        uint256 tokenIndex = getTokenIndexFromOriginalTokens(pair, token);

        if (pair == DAI_USDC_USDT) {
            uint256[3] memory amounts;
            amounts[tokenIndex] = amount;
            return ICurveCryptoSwap3(config[pair].minter).calc_token_amount(amounts, true);
        }

        if (pair == USD_BTC_ETH || pair == USD_BTC_ETH_V3) {
            uint256[5] memory amounts;
            amounts[tokenIndex] = amount;
            return ICurveCryptoSwap5(config[pair].minter).calc_token_amount(amounts, true);
        }

        revert("pair unsupport");
    }

    function getOriginTokenAmountOut(address pair, address token, uint256 amount) public view returns (uint256) {
        uint256 tokenIndex = getTokenIndexFromOriginalTokens(pair, token);

        if (pair == DAI_USDC_USDT) {
            return ICurveCryptoSwap3(config[pair].minter).calc_withdraw_one_coin(amount, int128(uint128(tokenIndex)));
        }

        if (pair == USD_BTC_ETH || pair == USD_BTC_ETH_V3) {
            return ICurveCryptoSwap5(config[pair].minter).calc_withdraw_one_coin(amount, tokenIndex);
        }

        revert("pair unsupport");
    }

    function _wantTokenPriceIn1e6USDC(address pair, uint256 amount) public view returns (uint256) {
        return getOriginTokenAmountOut(pair, USDC_TOKEN, amount);
    }

    function deposit(address pair, address fromToken, uint256 fromTokenAmount, uint256 minReceive) external returns (uint256) {
        require(config[pair].pair == pair, "pair unsupport");

        uint256 tokenIndex = getTokenIndexFromOriginalTokens(pair, fromToken);
        require(tokenIndex != type(uint256).max, "token unsupport");

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), fromTokenAmount);
        IERC20(fromToken).safeIncreaseAllowance(config[pair].minter, fromTokenAmount);

        uint256 wantTokenBefore = IERC20(pair).balanceOf(address(this));

        if (pair == DAI_USDC_USDT) {
            uint256[3] memory amounts;
            amounts[tokenIndex] = fromTokenAmount;
            ICurveCryptoSwap3(config[pair].minter).add_liquidity(amounts, minReceive, true);
        } else if (pair == USD_BTC_ETH || pair == USD_BTC_ETH_V3) {
            uint256[5] memory amounts;
            amounts[tokenIndex] = fromTokenAmount;
            ICurveCryptoSwap5(config[pair].minter).add_liquidity(amounts, minReceive);
        } else {
            revert("pair unsupport");
        }

        uint256 receivedAmount = IERC20(pair).balanceOf(address(this)) - wantTokenBefore;
        IERC20(pair).safeTransfer(msg.sender, receivedAmount);

        return receivedAmount;
    }

    function withdraw(address pair, uint256 withdrawAmount, address toToken, uint256 minReceive) external returns (uint256) {
        require(config[pair].pair == pair, "pair unsupport");

        uint256 tokenIndex = getTokenIndexFromOriginalTokens(pair, toToken);
        require(tokenIndex != type(uint256).max, "token unsupport");

        IERC20(pair).safeTransferFrom(msg.sender, address(this), withdrawAmount);

        uint256 wantTokenBefore = IERC20(toToken).balanceOf(address(this));

        IERC20(pair).safeIncreaseAllowance(config[pair].minter, withdrawAmount);
        if (pair == DAI_USDC_USDT) {
            ICurveCryptoSwap3(config[pair].minter).remove_liquidity_one_coin(withdrawAmount, int128(uint128(tokenIndex)), minReceive, true);
        } else if (pair == USD_BTC_ETH || pair == USD_BTC_ETH_V3) {
            ICurveCryptoSwap5(config[pair].minter).remove_liquidity_one_coin(withdrawAmount, tokenIndex, minReceive);
        } else {
            revert("pair unsupport");
        }

        uint256 receivedAmount = IERC20(toToken).balanceOf(address(this)) - wantTokenBefore;
        IERC20(toToken).safeTransfer(msg.sender, receivedAmount);

        return receivedAmount;
    }

    // USD_BTC_ETH -> USD_BTC_ETH_V3
    function migrate(address fromPair, address toPair, uint256 amount, uint256 minReceive) external returns (uint256) {
        require(config[fromPair].pair == fromPair, "pair unsupport");
        require(config[toPair].pair == toPair, "pair unsupport");
       
        IERC20(fromPair).safeTransferFrom(msg.sender, address(this), amount);

        uint256 wantTokenBefore = IERC20(toPair).balanceOf(address(this));

        IERC20(fromPair).safeIncreaseAllowance(config[fromPair].minter, amount);
        if (fromPair == USD_BTC_ETH) {
            ICurveCryptoSwap5(config[fromPair].minter).remove_liquidity(amount, [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)]);
        } else {
            revert("pair unsupport");
        }
   
        uint256[5] memory coin_balances;

        for (uint256 i = 0; i < 5; ++i) {
            coin_balances[i] = IERC20(config[fromPair].tokens[i]).balanceOf(address(this));
        }

        ICurveCryptoSwap5(toPair).add_liquidity(coin_balances, 0);
        
        uint256 receivedAmount = IERC20(toPair).balanceOf(address(this)) - wantTokenBefore;

        require(receivedAmount > minReceive, "minReceive");

        IERC20(toPair).safeTransfer(msg.sender, receivedAmount);

        return receivedAmount;
    }

}