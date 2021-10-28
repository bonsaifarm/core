// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH {
    function withdraw(uint256) external;
}

contract WNativeRelayer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant WRAPPED_NATIVE_TOKEN = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // Wrapped Matic (WMATIC)

    function withdraw(uint256 _amount, address _to) external nonReentrant {
        IERC20(WRAPPED_NATIVE_TOKEN).safeTransferFrom(msg.sender, address(this), _amount);
        IWETH(WRAPPED_NATIVE_TOKEN).withdraw(_amount);
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "WNativeRelayer:: can't withdraw");
    }

    receive() external payable {}
}
