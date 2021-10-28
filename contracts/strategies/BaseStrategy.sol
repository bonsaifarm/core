// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IUniv2LikePair.sol";
import "../interfaces/IUniv2LikeRouter02.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IZAP.sol";

abstract contract BaseStrategy is IStrategy, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant _DECIMAL = 1e18;

    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    // --------------------------------------------------------------
    // State variables
    // --------------------------------------------------------------

    /// @dev For reduce amount which is toooooooo small
    uint256 constant DUST = 1000;

    /// @dev bonus base;
    uint256 public constant BASE_BONUS = 1e6;

    /// @dev Mark is emergency mode
    bool override public IS_EMERGENCY_MODE;

    /// @dev Staking token
    address override public STAKING_TOKEN;

    /// @dev contract paused status
    bool public _paused;

    /// @dev contract paused until timestamp
    uint256 public _pauseUntil;

    /// @dev contract gas tip for keeper in base point;
    uint256 public gasTip = 500;

    /// @dev zap
    address public zapAddress;
    
    // --------------------------------------------------------------
    // State variables upgrade
    // --------------------------------------------------------------

    // Reserved storage space to allow for layout changes in the future.
    uint256[50] private ______gap;

    // --------------------------------------------------------------
    // Initialize
    // --------------------------------------------------------------

    function __base_initialize(
        address _STAKING_TOKEN
    ) internal initializer {
        __Ownable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(CONFIGURATOR_ROLE, msg.sender);

        STAKING_TOKEN = _STAKING_TOKEN;
    }

    // --------------------------------------------------------------
    // Config Interface
    // --------------------------------------------------------------
    function setStakingToken(address _STAKING_TOKEN) external onlyRole(CONFIGURATOR_ROLE) {
        STAKING_TOKEN = _STAKING_TOKEN;
    }

    function setGasTip(uint256 _gasTip) external onlyRole(CONFIGURATOR_ROLE) {
        require(_gasTip < 50000, "!maxTip");
        gasTip = _gasTip;
    }

    function setZapAddress(address _zapAddress) external onlyRole(CONFIGURATOR_ROLE) {
        zapAddress = _zapAddress;
    }

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------
    function approveToken(address token, address to, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), to) < amount) {
            IERC20(token).safeApprove(to, 0);
            IERC20(token).safeIncreaseAllowance(to, amount);
        }
    }

    function _receiveToken(address sender, uint256 amount) internal {
        IERC20(STAKING_TOKEN).safeTransferFrom(sender, address(this), amount);
    }

    function _sendToken(address receiver, uint256 amount) internal {
        IERC20(STAKING_TOKEN).safeTransfer(receiver, amount);
    }

    modifier whenNotPaused() {
        require(!paused(), "paused");
        _;
    }

    // --------------------------------------------------------------
    // User Read interface
    // --------------------------------------------------------------
    function totalBalance() public view returns(uint256) {
        return _underlyingWantTokenAmount();
    }

    // --------------------------------------------------------------
    // Keeper Interface
    // --------------------------------------------------------------

    function poolUpkeep() external override whenNotPaused onlyRole(KEEPER_ROLE) {
        _harvestFromUnderlying();
    }

    function payKeeper(address keeper, uint256 reward) external override whenNotPaused onlyRole(KEEPER_ROLE) {
        require(address(this).balance >= reward, "Address: insufficient balance");
        (bool success, ) = keeper.call{value: reward}("");
        require(
            success,
            "unable to send value, recipient may have reverted"
        );
    }

    function keeperGas(uint256 _gasPrice, uint256 _gasSpent) public override view returns (uint256) {
        uint256 _keeperGas = _gasPrice * _gasSpent;
        return _keeperGas + (_keeperGas * gasTip / 10000) + keeperUpkeepBonus();
    }

    function keeperUpkeepBonus() public override view returns (uint256) {
        if (_underlyingRewardMature()) {
            return BASE_BONUS;
        }
        return 0;
    }
    

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function withdraw(uint256 wantTokenAmount) external virtual onlyOwner whenNotPaused nonEmergency nonReentrant {
        uint256 withdrawnWantTokenAmount = _withdraw(wantTokenAmount);
        _sendToken(msg.sender, withdrawnWantTokenAmount);
    }

    function withdrawAs(uint256 wantTokenAmount, address tokenAddress, uint minReceive) external virtual onlyOwner whenNotPaused nonEmergency nonReentrant {
        _withdrawAs(wantTokenAmount, tokenAddress, minReceive);
    }

    function withdrawAll() external virtual onlyOwner whenNotPaused nonEmergency nonReentrant {
        uint256 withdrawnWantTokenAmount = _withdraw(totalBalance());
        _sendToken(msg.sender, withdrawnWantTokenAmount);
    }

    function withdrawAllAs(address tokenAddress, uint minReceive) external virtual onlyOwner whenNotPaused nonEmergency nonReentrant {
        _withdrawAs(totalBalance(), tokenAddress, minReceive);
    }

    function deposit(uint256 wantTokenAmount) external override virtual whenNotPaused nonEmergency nonReentrant {
        // get wantTokenAmount from msg sender
        _receiveToken(msg.sender, wantTokenAmount);

        _deposit(wantTokenAmount);
    }

    // --------------------------------------------------------------
    // Deposit and withdraw
    // --------------------------------------------------------------

    function _deposit(uint256 wantTokenAmount) internal {
        require(wantTokenAmount > DUST, "amount toooooo small");

        // receive token and deposit into underlying contract
        uint256 wantTokenAdded = _depositUnderlying(wantTokenAmount);

        emit LogDeposit(wantTokenAmount, wantTokenAdded);
    }

    function _withdraw(uint256 wantTokenAmount) internal returns (uint256) {
        require(msg.sender == owner(), "!onlyOwner");
        require(totalBalance() > wantTokenAmount, "!totalBalance");
        // withdraw from under contract
        uint256 withdrawnWantTokenAmount = _withdrawUnderlying(wantTokenAmount);

        emit LogWithdraw(wantTokenAmount, withdrawnWantTokenAmount);
        return withdrawnWantTokenAmount;
    }

    function _withdrawAs(uint256 wantTokenAmount, address tokenAddress, uint minReceive) internal virtual {
        uint256 withdrawnWantTokenAmount = _withdraw(wantTokenAmount);

        uint256 balanceBefore = IERC20(tokenAddress).balanceOf(msg.sender);

        approveToken(STAKING_TOKEN, zapAddress, withdrawnWantTokenAmount);

        IZAP(zapAddress).zapOut(STAKING_TOKEN, tokenAddress, withdrawnWantTokenAmount, msg.sender, minReceive);

        // Prevent Zap mistakes
        require(IERC20(tokenAddress).balanceOf(msg.sender) - balanceBefore > minReceive, "!minReceive");
    }
    

    // --------------------------------------------------------------
    // Interactive with under contract
    // --------------------------------------------------------------

    function _underlyingWantTokenAmount() public virtual view returns (uint256);
    function _underlyingRewardMature() internal virtual view returns (bool);
    function _harvestFromUnderlying() internal virtual;
    function _depositUnderlying(uint256 wantTokenAmount) internal virtual returns (uint256);
    function _withdrawUnderlying(uint256 wantTokenAmount) internal virtual returns (uint256);
    function _trySwapUnderlyingRewardToRewardToken() internal virtual;
    
    function recoverToken(address token, uint amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
        emit LogRecovered(token, amount);
    }

    // --------------------------------------------------------------
    // !! Pause !!
    // --------------------------------------------------------------

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused && _pauseUntil > block.timestamp;
    }

    function setPaused(bool _pausedStatus, uint256 _pauseUntilTimestamp) external onlyOwner {
        _paused = _pausedStatus;
        if (_paused) {
            _pauseUntil = _pauseUntilTimestamp;
        }

        emit LogPaused(_paused, msg.sender, _pauseUntil);
    }

    function pause() external whenNotPaused onlyRole(CONTROLLER_ROLE) {
        _paused = true;
        _pauseUntil = block.timestamp + 10 minutes;
        emit LogPaused(_paused, msg.sender, _pauseUntil);
    }

    // --------------------------------------------------------------
    // !! Emergency !!
    // --------------------------------------------------------------

    modifier nonEmergency() {
        require(IS_EMERGENCY_MODE == false, "emergency mode.");
        _;
    }

    modifier onlyEmergency() {
        require(IS_EMERGENCY_MODE == true, "!emergency mode.");
        _;
    }

    function emergencyExit() external virtual;

    /** @dev After emergency, the owner can perform ANY call. This is to rescue any funds that didn't
        get released during exit or got earned afterwards due to vesting or airdrops, etc. */
    function afterEmergency(
        address to,
        uint256 value,
        bytes memory data
    ) public onlyOwner onlyEmergency returns (bool success) {
        (success, ) = to.call{value: value}(data);
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogDeposit(uint256 wantTokenAmount, uint wantTokenAdded);
    event LogWithdraw(uint256 wantTokenAmount, uint withdrawWantTokenAmount);
    event LogReinvest(uint256 amount);
    event LogPaused(bool paused, address account, uint256 pauseUntil);
    event LogRewardAdded(uint256 amount);
    event LogRecovered(address token, uint256 amount);
    event LogPerformanceFee(uint256 amount, uint256 rewardFeeAmount);

}