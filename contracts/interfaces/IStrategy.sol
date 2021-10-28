// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategy {
    function STAKING_TOKEN() view external returns (address);

    function poolUpkeep() external;
    
    function deposit(uint256 wantTokenAmount) external;

    function payKeeper(address keeper, uint256 reward) external;
    
    function keeperGas(uint256 _gasPrice, uint256 _gasSpent) external view returns (uint256);

    function keeperUpkeepBonus() external view returns (uint256);

    function IS_EMERGENCY_MODE() external returns (bool);
}