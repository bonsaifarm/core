// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PreSalePool is ReentrancyGuard, Ownable, AccessControl {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant DECIMAL = 1e18;
    uint256 constant DUST = 1000;

    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    struct ParticipatorInfo {
        uint256 raisingTokenLocked;
        uint256 raisingTokenUsed;
        uint256 raisingTokenRefunded;
        uint256 offeringTokenSent;
        bool claimed;
    }

    mapping(address => ParticipatorInfo) public participatorInfos;
    address[] public participators;

    // Offering Token
    address public offeringToken;

    // Platform Treasure Address
    address public immutable platformTreasureAddress;

    address public immutable raisingToken;

    // start block height
    uint256 public immutable startTimestamp;

    // end block height, calculated when init
    uint256 public immutable endTimestamp;

    // if offering token won't send until this block height, will failed and participator can take their raising token back
    uint256 public immutable offeringTokenSentNotLaterThanTimestamp;

    // raising token target, if below target it will send by price, otherwise will send by shares
    uint256 public raisingTokenTarget;

    // max raising token amount
    uint256 public raisingTokenMax;

    // max offering token amount
    uint256 public offeringTokenMax;

    // is whitelist only
    bool public isWhitelistOnly;

    // raising token send to Platform Treasure Address
    bool public directlyToTreasure;

    // price per token, DECIMAL based, calculated when init
    uint256 public offeringTokenPricePerRaisingToken;

    // raising token locked in current phase, use to calc shares when target reached
    uint256 public raisingTokenLockedTotal;

    bool public offeringTokenSent;
    bool public raisingTokenTaken;

    /// @dev contract paused status
    bool public _paused;

    /// @dev contract paused until timestamp
    uint256 public _pauseUntil;

    /// @notice Whitelist
    mapping(address => bool) public _whitelist;

    constructor(
        address _platformTreasureAddress,

        address _raisingToken,
        address _offeringToken,

        uint256 _startTimestamp,
        uint256 _endTimestamp,
        uint256 _offeringTokenSentNotLaterThanTimestamp,

        uint256 _raisingTokenTarget,
        uint256 _raisingTokenMax,
        uint256 _offeringTokenMax,

        bool _isWhitelistOnly,
        bool _directlyToTreasure
    ) public {
        raisingToken = _raisingToken;
        offeringToken = _offeringToken;

        startTimestamp = _startTimestamp;
        endTimestamp = _endTimestamp;
        offeringTokenSentNotLaterThanTimestamp = _offeringTokenSentNotLaterThanTimestamp;

        raisingTokenTarget = _raisingTokenTarget;
        raisingTokenMax = _raisingTokenMax;
        offeringTokenMax = _offeringTokenMax;

        isWhitelistOnly = _isWhitelistOnly;
        directlyToTreasure = _directlyToTreasure;
        
        platformTreasureAddress = _platformTreasureAddress;

        offeringTokenPricePerRaisingToken = offeringTokenMax.mul(DECIMAL).div(raisingTokenTarget);

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // --------------------------------------------------------------
    // Guards
    // --------------------------------------------------------------

    modifier onlyOnAvailable() {
        require(block.timestamp < endTimestamp, "end");
        require(block.timestamp >= startTimestamp, "not start");
        if (isWhitelistOnly) require(isWhitelist(msg.sender), "Whitelist only");
        _;
    }

    modifier onlyOnEnd {
        require(block.timestamp >= endTimestamp, "not end");
        _;
    }

    modifier onlyOnSuccess() {
        require(offeringTokenSent, "offering token not sent");
        _;
    }

    modifier onlyOnFailed() {
        require(offeringTokenSent == false, "already success");
        require(block.timestamp > offeringTokenSentNotLaterThanTimestamp, "not reach the exit time");
        _;
    }

    modifier whenNotPaused() {
        require(!paused(), "paused");
        _;
    }

    // --------------------------------------------------------------
    // User Read Interface
    // --------------------------------------------------------------

    function isWhitelist(address userAddress) public view returns (bool) {
      return _whitelist[userAddress];
    }

    function getTokenPending(address userAddress) public view returns (uint256 offeringTokenAmount, uint256 raisingTokenRefundAmount, uint256 raisingTokenUsedAmount) {
        if (participatorInfos[userAddress].claimed || participatorInfos[userAddress].raisingTokenLocked == 0) return (0, 0, 0);

        if (raisingTokenLockedTotal > raisingTokenTarget) {
            // Overraise, by shares
            // 1. calc how many raising token will use in base point
            uint256 raisingTokenUsedInBp = raisingTokenTarget.mul(10000).div(raisingTokenLockedTotal);

            // amount that use to buy offering token
            raisingTokenUsedAmount = participatorInfos[userAddress].raisingTokenLocked.mul(raisingTokenUsedInBp).div(10000);

            // refund = raisingTokenLocked - raisingTokenUsedAmount
            raisingTokenRefundAmount = participatorInfos[userAddress].raisingTokenLocked.sub(raisingTokenUsedAmount);

            offeringTokenAmount = raisingTokenUsedAmount.mul(offeringTokenPricePerRaisingToken).div(DECIMAL);
        } else {
            // by price
            // multiply price directly
            offeringTokenAmount = participatorInfos[userAddress].raisingTokenLocked.mul(offeringTokenPricePerRaisingToken).div(DECIMAL);

            // actually used all raising token
            raisingTokenUsedAmount = participatorInfos[userAddress].raisingTokenLocked;
        }
    }

    function totalParticipants() public view returns (uint256) {
        return participators.length;
    }

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------
    function deposit(uint256 amount) external whenNotPaused nonReentrant nonEmergency onlyOnAvailable {
        require(amount > DUST, "toooooo small");
        require(amount + raisingTokenLockedTotal <= raisingTokenMax, "over raisingTokenMax");

        if (directlyToTreasure) {
            IERC20(raisingToken).safeTransferFrom(msg.sender, platformTreasureAddress, amount);
        } else {
            IERC20(raisingToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        raisingTokenLockedTotal = raisingTokenLockedTotal.add(amount);

        ParticipatorInfo storage participator = participatorInfos[msg.sender];

        if (participator.raisingTokenLocked == 0) {
            participators.push(msg.sender);
        }

        participator.raisingTokenLocked = participator.raisingTokenLocked.add(amount);
    }

    function claimOnSuccess() external whenNotPaused nonReentrant nonEmergency onlyOnEnd onlyOnSuccess {
        ParticipatorInfo storage participator = participatorInfos[msg.sender];
        require(participator.claimed == false, "already claimed");

        (uint256 offeringTokenAmount, uint256 raisingTokenRefundAmount, uint256 raisingTokenUsedAmount) = getTokenPending(msg.sender);

        participator.claimed = true;
        participator.raisingTokenUsed = raisingTokenUsedAmount;
        participator.raisingTokenRefunded = raisingTokenRefundAmount;
        participator.offeringTokenSent = offeringTokenAmount;

        if (offeringTokenAmount > 0) {
            IERC20(offeringToken).safeTransfer(msg.sender, offeringTokenAmount);
        }

        if (raisingTokenRefundAmount > 0) {
            IERC20(raisingToken).safeTransfer(msg.sender, raisingTokenRefundAmount);
        }
    }

    function withdrawOnFailed() external whenNotPaused nonReentrant nonEmergency onlyOnEnd onlyOnFailed {
        ParticipatorInfo storage participator = participatorInfos[msg.sender];
        require(participator.claimed == false, "already claimed");

        participator.claimed = true;
        uint256 raisingTokenRefundAmount = participator.raisingTokenLocked
            .sub(participator.raisingTokenUsed)
            .sub(participator.raisingTokenRefunded);
        participator.raisingTokenRefunded = participator.raisingTokenRefunded.add(raisingTokenRefundAmount);

        if (raisingTokenRefundAmount > 0) {
            IERC20(raisingToken).safeTransfer(msg.sender, raisingTokenRefundAmount);
        }
    }

    // --------------------------------------------------------------
    // Owner Write Interface
    // --------------------------------------------------------------
    function setWhitelist(address[] memory userAddresses, bool isActive) external onlyOwner {
      uint length = userAddresses.length;
      for (uint i = 0; i < length; ++i) {
        _whitelist[userAddresses[i]] = isActive;
      }
    }

    function setOfferingToken(address _offeringToken) external onlyOwner {
        require(offeringTokenSent == false, "already set");
        offeringToken = _offeringToken;
    }

    function notifyOfferingTokenSent() external nonReentrant nonEmergency onlyOwner onlyOnEnd {
        require(offeringTokenSent == false, "already set");
        require(IERC20(offeringToken).balanceOf(address(this)) >= offeringTokenMax, "not reach wanted");
        require(block.timestamp < offeringTokenSentNotLaterThanTimestamp, "timeout, already in exit mode");

        offeringTokenSent = true;
    }

    function takeRaisingTokenOnSuccess() external whenNotPaused nonReentrant nonEmergency onlyOwner onlyOnSuccess {
        require(raisingTokenTaken == false, "already taken");

        raisingTokenTaken = true;
        IERC20(raisingToken).safeTransfer(msg.sender, IERC20(raisingToken).balanceOf(address(this)));
    }

    function recoveryOfferingTokenOnFailed() external whenNotPaused nonReentrant nonEmergency onlyOwner onlyOnFailed {
        IERC20(offeringToken).safeTransfer(msg.sender, IERC20(offeringToken).balanceOf(address(this)));
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

    bool public IS_EMERGENCY_MODE = false;

    modifier nonEmergency() {
        require(IS_EMERGENCY_MODE == false, "emergency mode.");
        _;
    }

    modifier onlyEmergency() {
        require(IS_EMERGENCY_MODE == true, "not emergency mode.");
        _;
    }

    function emergencyExit() external onlyOwner {
        IS_EMERGENCY_MODE = true;
    }

    function emergencyWithdraw() external onlyEmergency nonReentrant {
        ParticipatorInfo storage participator = participatorInfos[msg.sender];

        uint256 raisingTokenRefundAmount = participator.raisingTokenLocked
            .sub(participator.raisingTokenUsed)
            .sub(participator.raisingTokenRefunded);
        participator.raisingTokenRefunded = participator.raisingTokenRefunded.add(raisingTokenRefundAmount);

        if (raisingTokenRefundAmount > 0) {
            IERC20(raisingToken).safeTransfer(msg.sender, raisingTokenRefundAmount);
        }
    }

    function recoveryEmergency() external onlyOwner onlyEmergency {
        IERC20(offeringToken).safeTransfer(msg.sender, IERC20(offeringToken).balanceOf(address(this)));
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogPaused(bool paused, address account, uint256 pauseUntil);
}