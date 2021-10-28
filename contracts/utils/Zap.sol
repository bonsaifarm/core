// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IUniv2LikePair.sol";
import "../interfaces/IUniv2LikeRouter02.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IZAP.sol";

import "../interfaces/IProxyFactory.sol";

import "../utils/CurveAdapter.sol";

interface IWETH {
    function deposit() external payable;
}

interface IWNativeRelayer {
    function withdraw(uint256 _amount, address _to) external;
}

interface ICurveStrategy {
    function CURVE_ADAPTER() external view returns(address);
    function depositToByOriginToken(address originTokenAddress, uint256 originTokenAmount, uint minReceive) external;
}

contract Zap is IZAP, IUpgradeableImplementation, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 override public constant CONTRACT_IDENTIFIER = keccak256("Zap");

    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");
    address public constant WRAPPED_NATIVE_TOKEN = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // Wrapped Matic (WMATIC)
    address public constant USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public constant wNativeRelayer = 0x1a285c7b4BD4A665dbE37A08a09C1ed5F3537317;

    struct TokenPairInfo {
        // ROUTER
        address ROUTER;

        // swap path
        address[] path;
    }

    /// @notice Info of each TokenPair
    mapping(uint => TokenPairInfo) public pairRouter;

    /// @notice accepted token, value is token ROUTER or token address
    mapping(address => address) public tokenRouter;

    function initialize() external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(CONFIGURATOR_ROLE, msg.sender);
    }

    // --------------------------------------------------------------
    // ROUTER Manage
    // --------------------------------------------------------------

    function updatePairRouter(address ROUTER, address[] calldata path) external onlyRole(CONFIGURATOR_ROLE) {
        uint pairKey = uint(uint160(path[0])) + uint(uint160(path[path.length - 1]));
        TokenPairInfo storage pairInfo = pairRouter[pairKey];

        pairInfo.ROUTER = ROUTER;
        pairInfo.path = path;
    }

    function updateTokenRouter(address token, address ROUTER) external onlyRole(CONFIGURATOR_ROLE) {
        tokenRouter[token] = ROUTER;
    }

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    function approveToken(address token, address to, uint amount) internal {
        if (IERC20(token).allowance(address(this), to) < amount) {
            IERC20(token).safeApprove(to, 0);
            IERC20(token).safeApprove(to, amount);
        }
    }

    modifier receiveToken(address token, uint amount) {
        if (token == WRAPPED_NATIVE_TOKEN) {
            if (msg.value != 0) {
                require(amount == msg.value, "value != msg.value");
                IWETH(WRAPPED_NATIVE_TOKEN).deposit{value: msg.value}();
            } else {
                IERC20(WRAPPED_NATIVE_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
            }
        } else {
            require(msg.value == 0, "Not MATIC");
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        _;
    }

    modifier onlyHuman {
        require(tx.origin == msg.sender, "!human");
        _;
    }

    /// @dev Fallback function to accept ETH.
    receive() external payable {}

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function zapAndDepositTo(address fromToken, uint amount, address poolAddress, uint minReceive) external payable onlyHuman receiveToken(fromToken, amount) {
        address wantToken = IStrategy(poolAddress).STAKING_TOKEN();
        uint wantTokenAmount = amount;

        if (
            fromToken != wantToken && (
                IUpgradeableImplementation(poolAddress).CONTRACT_IDENTIFIER() == keccak256("CurveStrategy")
            )
        ) {
            address curveAdapter = ICurveStrategy(poolAddress).CURVE_ADAPTER();
            // if fromToken not in ORIGINAL_TOKENS
            if (CurveAdapter(curveAdapter).getTokenIndexFromOriginalTokens(wantToken, fromToken) == type(uint256).max) {
                // USDC must in OriginalTokens
                require(CurveAdapter(curveAdapter).getTokenIndexFromOriginalTokens(wantToken, USDC_TOKEN) < type(uint256).max, "pool invalid");
                wantToken = USDC_TOKEN;
                wantTokenAmount = _swap(fromToken, USDC_TOKEN, amount, address(this));
            } else {
                wantToken = fromToken;
            }
            approveToken(wantToken, poolAddress, wantTokenAmount);
            ICurveStrategy(poolAddress).depositToByOriginToken(wantToken, wantTokenAmount, minReceive);
        } else {
            if (fromToken != wantToken) {
                require(tokenRouter[fromToken] == fromToken , "fromToken invalid");
                require(tokenRouter[wantToken] != address(0) , "wantToken invalid");

                if (tokenRouter[wantToken] == wantToken) {
                    // wantToken is normal token
                    wantTokenAmount = _swap(fromToken, wantToken, amount, address(this), minReceive);
                } else {
                    // wantToken is lp token
                    wantTokenAmount = _zapTokenToLP(fromToken, amount, wantToken, address(this), minReceive);
                }
            }

            approveToken(wantToken, poolAddress, wantTokenAmount);
            IStrategy(poolAddress).deposit(wantTokenAmount);
        }
    }

    function zapOut(address fromToken, address toToken, uint amount, address receiver, uint minReceive) override external payable receiveToken(fromToken, amount) {
        require(tokenRouter[fromToken] != address(0) , "fromToken invalid");

        bool withdarwAsNative = toToken == address(0);
        if (withdarwAsNative) toToken = WRAPPED_NATIVE_TOKEN;

        uint toTokenBefore = IERC20(toToken).balanceOf(address(this));
        uint toTokenAmount = 0;

        if (fromToken != toToken) {
            require(tokenRouter[toToken] == toToken, "toToken invalid");
            if (tokenRouter[fromToken] == fromToken) {
                // fromToken is normal token
                _swap(fromToken, toToken, amount, address(this), minReceive);
            } else {
                // fromToken is lp token
                _zapOutLpToToken(fromToken, amount, toToken, address(this), minReceive);
            }
            toTokenAmount = IERC20(toToken).balanceOf(address(this)) - toTokenBefore;
        } else {
            toTokenAmount = amount;
        }

        if (withdarwAsNative) {
            IERC20(toToken).safeApprove(wNativeRelayer, toTokenAmount);
            IWNativeRelayer(wNativeRelayer).withdraw(toTokenAmount, receiver);
        } else {
            IERC20(toToken).safeTransfer(receiver, toTokenAmount);
        }
    }

    // --------------------------------------------------------------
    // User View Interface
    // --------------------------------------------------------------

    function getZapAmountOut(address fromToken, uint amount, address poolAddress) external view returns (uint wantTokenAmount) {
        wantTokenAmount = amount;

        if (IUpgradeableImplementation(poolAddress).CONTRACT_IDENTIFIER() == keccak256("CurveStrategy")) {
            address pairToken = IStrategy(poolAddress).STAKING_TOKEN();
            address curveAdapter = ICurveStrategy(poolAddress).CURVE_ADAPTER();
            address originToken = fromToken;
            uint256 originTokenAmount = amount;
            // if fromToken not in ORIGINAL_TOKENS
            if (CurveAdapter(curveAdapter).getTokenIndexFromOriginalTokens(pairToken, fromToken) == type(uint256).max) {
                // USDC must in OriginalTokens
                require(CurveAdapter(curveAdapter).getTokenIndexFromOriginalTokens(pairToken, USDC_TOKEN) < type(uint256).max, "pool invalid");
                originToken = USDC_TOKEN;
                originTokenAmount = _getSwapAmountOut(fromToken, USDC_TOKEN, amount);
            }
            wantTokenAmount = CurveAdapter(curveAdapter).getTokenAmountOut(pairToken, originToken, originTokenAmount);
        } else {
            address wantToken = IStrategy(poolAddress).STAKING_TOKEN();
            if (fromToken != wantToken) {
                require(tokenRouter[fromToken] == fromToken , "fromToken invalid");
                require(tokenRouter[wantToken] != address(0) , "wantToken invalid");

                if (tokenRouter[wantToken] == wantToken) {
                    // wantToken is normal token
                    wantTokenAmount = _getSwapAmountOut(fromToken, wantToken, amount);
                } else {
                    // wantToken is lp token
                    wantTokenAmount = _getZapLpAmountOut(fromToken, amount, wantToken);
                }
            }
        }
        return wantTokenAmount;
    }


    function getZapOutAmountOut(address wantToken, uint amount, address poolAddress) external view returns (uint wantTokenAmount) {
        wantTokenAmount = amount;

        if (IUpgradeableImplementation(poolAddress).CONTRACT_IDENTIFIER() == keccak256("CurveStrategy")) {
            address pairToken = IStrategy(poolAddress).STAKING_TOKEN();
            address curveAdapter = ICurveStrategy(poolAddress).CURVE_ADAPTER();
            if (CurveAdapter(curveAdapter).getTokenIndexFromOriginalTokens(pairToken, wantToken) < type(uint256).max) {
                wantTokenAmount = CurveAdapter(curveAdapter).getOriginTokenAmountOut(pairToken, wantToken, amount);
            } else {
                uint256 usdcTokenAmount = CurveAdapter(curveAdapter).getOriginTokenAmountOut(pairToken, USDC_TOKEN, amount);
                wantTokenAmount = _getSwapAmountOut(USDC_TOKEN, wantToken, usdcTokenAmount);
            }
        } else {
            address fromToken = IStrategy(poolAddress).STAKING_TOKEN();
            if (fromToken != wantToken) {
                require(tokenRouter[fromToken] != address(0) , "fromToken invalid");
                if (tokenRouter[fromToken] == fromToken) {
                    // fromToken is normal token
                    wantTokenAmount = _getSwapAmountOut(fromToken, wantToken, amount);
                } else {
                    // fromToken is lp token
                    IUniv2LikePair pair = IUniv2LikePair(fromToken);
                    address token0 = pair.token0();
                    address token1 = pair.token1();
                    (uint amount0, uint amount1) = _getBurnLiquidityAmountOut(fromToken, amount);
                    uint wantTokenAmount0 = _getSwapAmountOut(token0, wantToken, amount0);
                    uint wantTokenAmount1 = _getSwapAmountOut(token1, wantToken, amount1);
                    wantTokenAmount = wantTokenAmount0 + wantTokenAmount1;
                }
            }
        }
    }

    // --------------------------------------------------------------
    // Utils for contract
    // --------------------------------------------------------------

    function swap(address fromToken, address wantToken, uint amount, address receiver) external payable receiveToken(fromToken, amount) returns (uint) {
        require(tokenRouter[fromToken] == fromToken, "fromToken invalid");

        return _swap(fromToken, wantToken, amount, receiver);
    }

    function swap(address fromToken, address wantToken, uint amount, address receiver, uint minTokenReceive) external payable receiveToken(fromToken, amount) returns (uint) {
        require(tokenRouter[fromToken] == fromToken, "fromToken invalid");

        return _swap(fromToken, wantToken, amount, receiver, minTokenReceive);
    }

    function swap(address[] memory tokens, uint amount, address receiver, uint minTokenReceive) override external payable receiveToken(tokens[0], amount) returns (uint) {
        uint len = tokens.length;
        uint swapAmount = amount;
        for (uint i = 0; i < len - 1; ++i) {
            if (tokens[i] != tokens[i + 1]) {
                uint amountBefore = IERC20(tokens[i + 1]).balanceOf(address(this));

                if (tokenRouter[tokens[i]] == tokens[i]) {
                    // fromToken is normal token
                    if (tokenRouter[tokens[i+1]] == tokens[i+1]) {
                        // toToken is normal token
                        _swap(tokens[i], tokens[i + 1], swapAmount, address(this));
                    } else {
                        // toToken is lp token
                       _zapTokenToLP(tokens[i], swapAmount, tokens[i + 1], address(this), 0);
                    }
                } else {
                    // fromToken is lp token
                    _zapOutLpToToken(tokens[i], swapAmount, tokens[i + 1], address(this), 0);
                }

                swapAmount = IERC20(tokens[i + 1]).balanceOf(address(this)) - amountBefore;
            }
        }
        require(swapAmount >= minTokenReceive);
        IERC20(tokens[len - 1]).safeTransfer(receiver, swapAmount);

        return swapAmount;
    }

    function zapTokenToLP(address fromToken, uint amount, address lpToken, address receiver) override external payable receiveToken(fromToken, amount) returns (uint) {
        require(tokenRouter[fromToken] == fromToken, "fromToken invalid");

        return _zapTokenToLP(fromToken, amount, lpToken, receiver);
    }

    function zapTokenToLP(address fromToken, uint amount, address lpToken, address receiver, uint minLPReceive) override external payable receiveToken(fromToken, amount) returns (uint) {
        require(tokenRouter[fromToken] == fromToken, "fromToken invalid");

        return _zapTokenToLP(fromToken, amount, lpToken, receiver, minLPReceive);
    }

    function tokenPriceIn1e6USDC(address fromToken) external view returns(uint) {
        return tokenPriceIn1e6USDC(fromToken, 10 ** IERC20Metadata(fromToken).decimals());
    }

    function tokenPriceIn1e6USDC(address fromToken, uint amount) public view returns(uint) {
        require(tokenRouter[fromToken] == fromToken, "fromToken invalid");

        (address router, address[] memory path) = getRouterAndPath(fromToken, USDC_TOKEN);

        uint[] memory amounts = IUniv2LikeRouter01(router).getAmountsOut(amount, path);

        return amounts[amounts.length - 1];
    }

    // --------------------------------------------------------------
    // Internal
    // --------------------------------------------------------------

    function getRouterAndPath(address fromToken, address toToken) private view returns (address router, address[] memory path) {
        uint pairKey = uint(uint160(fromToken)) + uint(uint160(toToken));
        TokenPairInfo storage pairInfo = pairRouter[pairKey];

        require(pairInfo.ROUTER != address(0), "router not set");

        router = pairInfo.ROUTER;

        path = new address[](pairInfo.path.length);
        if (pairInfo.path[0] == fromToken) {
            path = pairInfo.path;
        } else {
            for (uint index = 0; index < pairInfo.path.length; index++) {
                path[index] = (pairInfo.path[pairInfo.path.length - 1 - index]);
            }
        }
    }

    function _swap(address fromToken, address wantToken, uint amount, address receiver) private returns (uint) {
        return _swap(fromToken, wantToken, amount, receiver, 0);
    }

    function _swap(address fromToken, address wantToken, uint amount, address receiver, uint minTokenReceive) private returns (uint) {
        if (fromToken == wantToken) {
            if (receiver !=  address(this)) {
                IERC20(wantToken).transfer(receiver, amount);
            }
            return amount;
        }

        (address router, address[] memory path) = getRouterAndPath(fromToken, wantToken);

        approveToken(fromToken, router, amount);
        uint wantTokenAmountBefore = IERC20(wantToken).balanceOf(address(this));
        IUniv2LikeRouter02(router).swapExactTokensForTokens(amount, minTokenReceive, path, receiver, block.timestamp);
        uint wantTokenAmountAfter = IERC20(wantToken).balanceOf(address(this));

        require(wantTokenAmountAfter - wantTokenAmountBefore >= minTokenReceive, "out of range");

        return wantTokenAmountAfter - wantTokenAmountBefore;
    }

    function _getSwapAmountOut(address fromToken, address wantToken, uint amount) private view returns (uint) {
        if (fromToken == wantToken) {
            return amount;
        }
        (address router, address[] memory path) = getRouterAndPath(fromToken, wantToken);

        uint[] memory amounts =  IUniv2LikeRouter02(router).getAmountsOut(amount, path);
        return amounts[amounts.length - 1];
    }

    function _zapTokenToLP(address fromToken, uint amount, address lpToken, address receiver) private returns (uint liquidity) {
        return _zapTokenToLP(fromToken, amount, lpToken, receiver, 0);
    }

    function _zapTokenToLP(address fromToken, uint amount, address lpToken, address receiver, uint minLPReceive) private returns (uint liquidity) {
        require(tokenRouter[fromToken] == fromToken, "fromToken invalid");

        IUniv2LikePair pair = IUniv2LikePair(lpToken);
        address token0 = pair.token0();
        address token1 = pair.token1();

        uint lpTokenAmountBefore = IERC20(lpToken).balanceOf(address(this));

        // swap fromToken to token0 & token1
        uint token0Amount = _swap(fromToken, token0, amount / 2, address(this));
        uint token1Amount = _swap(fromToken, token1, amount / 2, address(this));

        approveToken(token0, tokenRouter[lpToken], token0Amount);
        approveToken(token1, tokenRouter[lpToken], token1Amount);

        (,,liquidity) = IUniv2LikeRouter02(tokenRouter[lpToken]).addLiquidity(token0, token1, token0Amount, token1Amount, 0, 0, address(this), block.timestamp);

        liquidity = IERC20(lpToken).balanceOf(address(this)) - lpTokenAmountBefore;

        require(liquidity >= minLPReceive, "out of range");

        uint token0AmountDust = IERC20(token0).balanceOf(address(this));
        uint token1AmountDust = IERC20(token1).balanceOf(address(this));

        // send rest token back to user
        if (token0AmountDust > 0) IERC20(token0).safeTransfer(msg.sender, token0AmountDust);
        if (token1AmountDust > 0) IERC20(token1).safeTransfer(msg.sender, token1AmountDust);

        if (receiver != address(this)) {
            IERC20(lpToken).safeTransfer(receiver, liquidity);
        }
    }

    function _getZapLpAmountOut(address fromToken, uint amount, address lpToken) private view returns (uint liquidity) {
        require(tokenRouter[fromToken] == fromToken, "fromToken invalid");

        IUniv2LikePair pair = IUniv2LikePair(lpToken);
        address token0 = pair.token0();
        address token1 = pair.token1();

        uint amount0 = _getSwapAmountOut(fromToken, token0, amount / 2);
        uint amount1 = _getSwapAmountOut(fromToken, token1, amount / 2);
        liquidity = _getMintLiquidityAmountOut(amount0, amount1, lpToken);
    }

    function _getMintLiquidityAmountOut(uint amount0, uint amount1, address lpToken) private view returns (uint liquidity) {
        uint _totalSupply = IUniv2LikePair(lpToken).totalSupply();
        (uint112 _reserve0, uint112 _reserve1,) = IUniv2LikePair(lpToken).getReserves();

        liquidity = Math.min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
    }

    function _getBurnLiquidityAmountOut(address lpToken, uint liquidity) private view returns (uint amount0, uint amount1) {
        IUniv2LikePair pair = IUniv2LikePair(lpToken);
        address token0 = pair.token0();
        address token1 = pair.token1();

        uint balance0 = IERC20(token0).balanceOf(lpToken);
        uint balance1 = IERC20(token1).balanceOf(lpToken);

        uint _totalSupply = IUniv2LikePair(lpToken).totalSupply();
        amount0 = liquidity * balance0 / _totalSupply;
        amount1 = liquidity * balance1 / _totalSupply;
    }


    function _zapOutLpToToken(address lpToken, uint amount, address toToken, address receiver, uint minReceive) private {
        IUniv2LikePair pair = IUniv2LikePair(lpToken);
        address token0 = pair.token0();
        address token1 = pair.token1();

        approveToken(lpToken, tokenRouter[lpToken], amount);

        (uint amount0, uint amount1) = IUniv2LikeRouter02(tokenRouter[lpToken]).removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);

        uint toTokenAmount0 = _swap(token0, toToken, amount0, address(this));
        uint toTokenAmount1 = _swap(token1, toToken, amount1, address(this));

        require(toTokenAmount0 + toTokenAmount1 >= minReceive, "out of range");
        if (receiver != address(this)) {
            IERC20(toToken).safeTransfer(receiver, toTokenAmount0 + toTokenAmount1);
        }
    }
}
