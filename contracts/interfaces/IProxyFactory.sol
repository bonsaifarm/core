// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

interface IUpgradeableImplementation {
    function CONTRACT_IDENTIFIER() external view returns (bytes32);
}