// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.6;

import '@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol';

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IStrategy.sol";

abstract contract FarmRegistry is ERC721Upgradeable {
    struct StrategyTemplate {
        address masterCopy;
        uint256 deployFee;
    }

    StrategyTemplate[] public strategyTemplate;

    uint256 nextId;

    string private _contractURI;
    address public governance; // governance contract

    // -- Events --
    event StrategyTemplateAdded(uint256 sid, address masterCopy, uint256 deployFee);
    event StrategyTemplateUpdated(uint256 sid, address masterCopy, uint256 deployFee);

    modifier onlyGov() {
        require(msg.sender == governance, "!gov");
        _;
    }

    function _initialize(
        string memory name_,
        string memory symbol_,
        string memory contractURI_
    )  internal {
        __ERC721_init(name_, symbol_);
        _contractURI = contractURI_;
        governance = msg.sender;
    }

    function _setContractURI(string memory uri_) internal {
        _contractURI = uri_;
    }

    function contractURI() public view returns (string memory) {
        return _contractURI;
    }

    function addStrategyTemplate(StrategyTemplate calldata _strategyTemplate) public onlyGov {
        strategyTemplate.push(_strategyTemplate);
        emit StrategyTemplateAdded(strategyTemplate.length - 1, _strategyTemplate.masterCopy, _strategyTemplate.deployFee);
    }

    function updateStrategyTemplate(uint256 sid, address masterCopy, uint256 deployFee) public onlyGov {
        strategyTemplate[sid].masterCopy = masterCopy;
        strategyTemplate[sid].deployFee = deployFee;
        emit StrategyTemplateUpdated(sid, masterCopy, deployFee);
    }

    function newBonsai(uint256 sid, bytes calldata initData) public returns(IStrategy) {
        bytes32 salt = bytes32(nextId++);
        StrategyTemplate memory strategy = strategyTemplate[sid];
        require(strategy.masterCopy != address(0), "!strategyTemplate");
        
        IStrategy bonsaiStrategy = IStrategy(Clones.cloneDeterministic(address(strategy.masterCopy), salt));

        (bool success, bytes memory errData) = address(bonsaiStrategy).call(initData);

		if (!success) revert(string(errData));
  
        return bonsaiStrategy;
    }
}