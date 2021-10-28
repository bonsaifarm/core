// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./BaseStrategy.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IProxyFactory.sol";

import "../utils/CurveAdapter.sol";

interface IGauge {
    function balanceOf(address) external view returns (uint256);
    function claim_rewards() external;
    function deposit(uint256 _amount) external;
    function withdraw(uint256 _amount) external;
    function lp_token() external view returns (address);
    function reward_tokens(uint256 index) external view returns (address);

    function claimable_reward(address, address) external view returns (uint256);
}

contract CurveStrategy is IUpgradeableImplementation, BaseStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 override public constant CONTRACT_IDENTIFIER = keccak256("CurveStrategy");
    address public constant USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    // --------------------------------------------------------------
    // Address
    // --------------------------------------------------------------

    /// @dev GAUGE address, for interactive underlying contract
    address public GAUGE;

    /// @dev Underlying reward tokens, pAUTO + WMATIC
    address[] public UNDERLYING_REWARD_TOKENS;

    /// @dev Underlying reward tokens amount
    mapping(address => uint256) public underlyingRewardTokensAmount;

    /// @dev Underlying reward tokens swap threshold amount
    mapping(address => uint256) public underlyingRewardTokensSwapThreshold;

    address public CURVE_ADAPTER;

    function initialize(
        address _GAUGE,
        address _CURVE_ADAPTER
    ) public initializer {
        GAUGE = _GAUGE;

        // most reward_tokens.length is 2 
        for (uint256 i = 0; i < 2; ++i) {
            address token = IGauge(_GAUGE).reward_tokens(i);
            if (token != address(0)) {
                UNDERLYING_REWARD_TOKENS.push(token);
            }
        }

        address _STAKING_TOKEN = IGauge(_GAUGE).lp_token();

        __base_initialize(
            _STAKING_TOKEN
        );

        CURVE_ADAPTER = _CURVE_ADAPTER;
    }

    // --------------------------------------------------------------
    // Config Interface
    // --------------------------------------------------------------

    function updateCurveAdapter(address _CURVE_ADAPTER) external onlyRole(CONFIGURATOR_ROLE) {
        CURVE_ADAPTER = _CURVE_ADAPTER;
    }

    function updateRewardTokenThreshold(address token, uint256 _rewardTokenSwapThreshold) external onlyRole(CONFIGURATOR_ROLE) {
        underlyingRewardTokensSwapThreshold[token] = _rewardTokenSwapThreshold;
    }

    // --------------------------------------------------------------
    // Current strategy info in under contract
    // --------------------------------------------------------------

    function _underlyingWantTokenAmount() public override view returns (uint256) {
        return IGauge(GAUGE).balanceOf(address(this));
    }

   function _trySwapUnderlyingRewardToRewardToken() internal override {
        for (uint256 i = 0; i < UNDERLYING_REWARD_TOKENS.length; ++i) {
            address underlyingRewardToken = UNDERLYING_REWARD_TOKENS[i];
            // get current reward token amount
            uint256 rewardTokenAmount = IERC20(underlyingRewardToken).balanceOf(address(this));

            // if token amount too small, wait for save gas fee
            if (rewardTokenAmount < underlyingRewardTokensSwapThreshold[underlyingRewardToken]) return;
           
            // reinvest
            _reinvest(underlyingRewardToken, rewardTokenAmount);
        }
    }

    function _reinvest(address tokenAddress, uint256 tokenAmount) internal {
        // swap token to USDC
        approveToken(tokenAddress, zapAddress, tokenAmount);

        address[] memory tokens = new address[](2);
        tokens[0] = tokenAddress;
        tokens[1] = USDC_TOKEN;
        uint256 usdcTokenAmount = IZAP(zapAddress).swap(tokens, tokenAmount, address(this), 0);

        // swap USDC to stakingToken
        uint256 tokenIndex = CurveAdapter(CURVE_ADAPTER).getTokenIndexFromOriginalTokens(STAKING_TOKEN, USDC_TOKEN);
        require(tokenIndex < type(uint256).max, "not originToken");

        approveToken(USDC_TOKEN, CURVE_ADAPTER, usdcTokenAmount);

        uint256 stakingTokenAmount = CurveAdapter(CURVE_ADAPTER).deposit(STAKING_TOKEN, USDC_TOKEN, usdcTokenAmount, 0);

        // deposit to underlying
        uint256 wantTokenAdded = _depositUnderlying(stakingTokenAmount);

        emit LogReinvest(wantTokenAdded);
    }

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function _withdrawAs(uint256 wantTokenAmount, address tokenAddress, uint minReceive) override virtual internal {
        uint256 withdrawnWantTokenAmount = _withdraw(wantTokenAmount);

        if (tokenAddress == STAKING_TOKEN) {
            IERC20(tokenAddress).safeTransfer(msg.sender, withdrawnWantTokenAmount);
            return;
        }

        uint256 tokenIndex = CurveAdapter(CURVE_ADAPTER).getTokenIndexFromOriginalTokens(STAKING_TOKEN, tokenAddress);
        approveToken(STAKING_TOKEN, CURVE_ADAPTER, withdrawnWantTokenAmount);

        if (tokenIndex < type(uint256).max) {
            // get OriginToken and transfer
            uint256 tokenAmount = CurveAdapter(CURVE_ADAPTER).withdraw(STAKING_TOKEN, withdrawnWantTokenAmount, tokenAddress, minReceive);
            IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
        } else {
            // covert to USDC and zap out
            uint256 tokenAmount = CurveAdapter(CURVE_ADAPTER).withdraw(STAKING_TOKEN, withdrawnWantTokenAmount, USDC_TOKEN, 0);
            approveToken(USDC_TOKEN, zapAddress, tokenAmount);
            IZAP(zapAddress).zapOut(USDC_TOKEN, tokenAddress, tokenAmount, msg.sender, minReceive);
        }
    }

    function depositToByOriginToken(address originTokenAddress, uint256 originTokenAmount, uint minReceive) external onlyRole(CONTROLLER_ROLE) {

        uint256 tokenIndex = CurveAdapter(CURVE_ADAPTER).getTokenIndexFromOriginalTokens(STAKING_TOKEN, originTokenAddress);
        require(tokenIndex < type(uint256).max, "not originToken");

        IERC20(originTokenAddress).safeTransferFrom(msg.sender, address(this), originTokenAmount);
        approveToken(originTokenAddress, CURVE_ADAPTER, originTokenAmount);

        uint256 wantTokenAmount = CurveAdapter(CURVE_ADAPTER).deposit(STAKING_TOKEN, originTokenAddress, originTokenAmount, minReceive);

        _deposit(wantTokenAmount);
    }

    // --------------------------------------------------------------
    // Interactive with under contract
    // --------------------------------------------------------------

    function _underlyingRewardMature() internal override view returns (bool mature) {
        mature = false;
        for (uint256 i = 0; i < UNDERLYING_REWARD_TOKENS.length; ++i) {
            address underlyingRewardToken = UNDERLYING_REWARD_TOKENS[i];
            uint256 rewardTokenAmount = IGauge(GAUGE).claimable_reward(address(this), underlyingRewardToken); 
            if (rewardTokenAmount > underlyingRewardTokensSwapThreshold[underlyingRewardToken]) {
                mature = true;
                break;
            }
        }
    }
    
    function _depositUnderlying(uint256 amount) internal override returns (uint256) {
        uint256 underlyingWantTokenAmountBefore = _underlyingWantTokenAmount();

        approveToken(STAKING_TOKEN, GAUGE, amount);
        IGauge(GAUGE).deposit(amount);

        return _underlyingWantTokenAmount().sub(underlyingWantTokenAmountBefore);
    }

    // user _withdrawUnderlying MUST after _harvest
    function _withdrawUnderlying(uint256 amount) internal override returns (uint256) {
        uint256 _before = IERC20(STAKING_TOKEN).balanceOf(address(this));

        IGauge(GAUGE).withdraw(amount);

        return IERC20(STAKING_TOKEN).balanceOf(address(this)).sub(_before);
    }

    function wantTokenPriceIn1e6USDC(uint256 amount) public view returns (uint256) {
        return CurveAdapter(CURVE_ADAPTER)._wantTokenPriceIn1e6USDC(STAKING_TOKEN, amount);
    }

    function _harvestFromUnderlying() internal override {
        IGauge(GAUGE).claim_rewards();
    }

    // --------------------------------------------------------------
    // !! Emergency !!
    // --------------------------------------------------------------

    function emergencyExit() external override onlyRole(CONFIGURATOR_ROLE) {
        uint256 underlyingWantTokenAmount = _underlyingWantTokenAmount();
        IGauge(GAUGE).withdraw(underlyingWantTokenAmount);
        // send all token to owner
        IERC20(STAKING_TOKEN).safeTransfer(owner(), IERC20(STAKING_TOKEN).balanceOf(address(this)));
        IS_EMERGENCY_MODE = true;
    }

}