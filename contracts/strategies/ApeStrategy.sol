// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./BaseStrategy.sol";
import "../interfaces/IProxyFactory.sol";
import "../interfaces/IStrategy.sol";

interface IMasterApeV2 {
    function userInfo(uint256 _pid, address _userAddress) external view returns (
        uint256 amount,     // How many LP tokens the user has provided.
        uint256 rewardDebt // Reward debt. See explanation below.
    );

    function poolInfo(uint256 pid) external view returns (
        uint128 accBananaPerShare,
        uint64 lastRewardTime,
        uint64 allocPoint
    );

    function pendingCake(uint256 _pid, address _user) external view returns (uint256);

    function cake() external view returns (address);
    function lpToken(uint256 pid) external view returns (address);

    function totalAllocPoint() external view returns (uint256);
    function deposit(uint256 pid, uint256 amount, address to) external;
    function withdraw(uint256 pid, uint256 amount, address to) external;
    function harvest(uint256 pid, address to) external;
}


contract ApeStrategy is IUpgradeableImplementation, BaseStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 override public constant CONTRACT_IDENTIFIER = keccak256("ApeStrategy");
    address public constant USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    // --------------------------------------------------------------
    // Address
    // --------------------------------------------------------------

    /// @dev MasterChef address, for interactive underlying contract
    address public MASTER_CHEF_LIKE;

    /// @dev Pool ID in MasterChef
    uint256 public MASTER_CHEF_LIKE_POOL_ID;

    /// @dev Underlying reward tokens, pAUTO + WMATIC
    address[] public UNDERLYING_REWARD_TOKENS;
 
    /// @dev Underlying reward tokens swap threshold amount
    mapping(address => uint256) public underlyingRewardTokensSwapThreshold;

    function initialize(
        address _MASTER_CHEF_LIKE,
        uint256 _MASTER_CHEF_LIKE_POOL_ID,
        address[] calldata _UNDERLYING_REWARD_TOKENS
    ) public initializer {
        address _STAKING_TOKEN = IMasterApeV2(_MASTER_CHEF_LIKE).lpToken(_MASTER_CHEF_LIKE_POOL_ID);

        __base_initialize(
            _STAKING_TOKEN
        );

        UNDERLYING_REWARD_TOKENS = _UNDERLYING_REWARD_TOKENS;

        MASTER_CHEF_LIKE = _MASTER_CHEF_LIKE;
        MASTER_CHEF_LIKE_POOL_ID = _MASTER_CHEF_LIKE_POOL_ID;
    }
    // --------------------------------------------------------------
    // Config Interface
    // --------------------------------------------------------------

    function updateRewardTokenThreshold(address token, uint256 _rewardTokenSwapThreshold) external onlyRole(CONFIGURATOR_ROLE) {
        underlyingRewardTokensSwapThreshold[token] = _rewardTokenSwapThreshold;
    }

    // --------------------------------------------------------------
    // Current strategy info in under contract
    // --------------------------------------------------------------

    function _underlyingRewardMature() internal override view returns (bool) {
        uint256 rewardTokenAmount =  IMasterApeV2(MASTER_CHEF_LIKE).pendingCake(MASTER_CHEF_LIKE_POOL_ID, address(this)); 
        if (rewardTokenAmount > underlyingRewardTokensSwapThreshold[IMasterApeV2(MASTER_CHEF_LIKE).cake()]) return true;

        return false;
    }

    function _underlyingWantTokenAmount() public override view returns (uint256) {
        (uint256 amount,) = IMasterApeV2(MASTER_CHEF_LIKE).userInfo(MASTER_CHEF_LIKE_POOL_ID, address(this));
        return amount;
    }

    function _trySwapUnderlyingRewardToRewardToken() internal override {
        for (uint256 i = 0; i < UNDERLYING_REWARD_TOKENS.length; ++i) {
            address UNDERLYING_REWARD_TOKEN = UNDERLYING_REWARD_TOKENS[i];
            // get current reward token amount
            uint256 rewardTokenAmount = IERC20(UNDERLYING_REWARD_TOKEN).balanceOf(address(this));

            // if token amount too small, wait for save gas fee
            if (rewardTokenAmount < underlyingRewardTokensSwapThreshold[UNDERLYING_REWARD_TOKEN]) return;

            // reinvest
            _reinvest(UNDERLYING_REWARD_TOKEN, rewardTokenAmount);
        }
    }

    function _reinvest(address tokenAddress, uint256 tokenAmount) internal {
        // swap token to staking token
        approveToken(tokenAddress, zapAddress, tokenAmount);
        address[] memory tokens = new address[](3);
        tokens[0] = tokenAddress;
        tokens[1] = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174; // USDC
        tokens[2] = STAKING_TOKEN;
        uint256 stakingTokenAmount = IZAP(zapAddress).swap(tokens, tokenAmount, address(this), 0);

        // deposit to underlying
        uint256 wantTokenAdded = _depositUnderlying(stakingTokenAmount);

        emit LogReinvest(wantTokenAdded);
    }

    // --------------------------------------------------------------
    // Interactive with under contract
    // --------------------------------------------------------------
    
    function _depositUnderlying(uint256 amount) internal override returns (uint256) {
        uint256 underlyingWantTokenAmountBefore = _underlyingWantTokenAmount();

        approveToken(STAKING_TOKEN, MASTER_CHEF_LIKE, amount);
        IMasterApeV2(MASTER_CHEF_LIKE).deposit(MASTER_CHEF_LIKE_POOL_ID, amount, address(this));

        return _underlyingWantTokenAmount().sub(underlyingWantTokenAmountBefore);
    }

    function _withdrawUnderlying(uint256 amount) internal override returns (uint256) {
        uint256 _before = IERC20(STAKING_TOKEN).balanceOf(address(this));

        IMasterApeV2(MASTER_CHEF_LIKE).withdraw(MASTER_CHEF_LIKE_POOL_ID, amount, address(this));

        return IERC20(STAKING_TOKEN).balanceOf(address(this)).sub(_before);
    }

    function _harvestFromUnderlying() internal override {
        IMasterApeV2(MASTER_CHEF_LIKE).harvest(MASTER_CHEF_LIKE_POOL_ID, address(this));
    }

    // --------------------------------------------------------------
    // !! Emergency !!
    // --------------------------------------------------------------

    function emergencyExit() external override onlyRole(CONFIGURATOR_ROLE) {
        uint256 underlyingWantTokenAmount = _underlyingWantTokenAmount();
        IMasterApeV2(MASTER_CHEF_LIKE).withdraw(MASTER_CHEF_LIKE_POOL_ID, underlyingWantTokenAmount, owner());
        IS_EMERGENCY_MODE = true;
    }

}