// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

interface IZAP {
    function swap(address[] memory tokens, uint amount, address receiver, uint) external payable returns (uint);
    function zapOut(address fromToken, address toToken, uint amount, address receiver, uint minReceive) external payable;
    function zapTokenToLP(address fromToken, uint amount, address lpToken, address receiver) external payable returns (uint);
    function zapTokenToLP(address fromToken, uint amount, address lpToken, address receiver, uint minLPReceive) external payable returns (uint);
}
