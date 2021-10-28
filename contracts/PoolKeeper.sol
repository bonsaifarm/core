//SPDX-License-Identifier: CC-BY-NC-ND-4.0
pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IStrategy.sol";


/// @title The manager contract for multiple markets and the pools in them
contract PoolKeeper is Ownable {
    uint256 public gasPrice = 30 gwei; // polygon base gasPrice
    uint256 constant DUST = 1000;

    /**
     * @notice Creates a notification when a keeper is paid for doing upkeep for a pool
     * @param _pool Address of pool being upkept
     * @param keeper Keeper to be rewarded for upkeeping
     * @param reward Keeper's reward (in settlement tokens)
     */
    event KeeperPaid(address indexed _pool, address indexed keeper, uint256 reward);

    /**
     * @notice Creates a notification when a keeper's payment for upkeeping a pool failed
     * @param _pool Address of pool being upkept
     * @param keeper Keeper to be rewarded for upkeeping
     * @param expectedReward Keeper's expected reward (in settlement tokens); not actually transferred
     */
    event KeeperPaymentError(address indexed _pool, address indexed keeper, uint256 expectedReward);

    /**
     * @notice Creates a notification of a failed pool update
     * @param pool The pool that failed to update
     * @param reason The reason for the error
     */
    event PoolUpkeepError(address indexed pool, string reason);

    /**
     * @notice Called by keepers to perform an update on a single pool
     * @param _pool The pool code to perform the update for
     */
    function performUpkeepSinglePool(address _pool) public {
        uint256 startGas = gasleft();

        IStrategy pool = IStrategy(_pool);
        // validate the pool, check that the pool need upkeep
        if (pool.keeperUpkeepBonus() < DUST) {
            return;
        }
        
        // This allows us to still batch multiple calls to executePriceChange, even if some are invalid
        // Without reverting the entire transaction
        try pool.poolUpkeep() {
            // If poolUpkeep is successful, refund the keeper for their gas costs
            uint256 gasSpent = startGas - gasleft();

            payKeeper(_pool, gasPrice, gasSpent);
        } catch Error(string memory reason) {
            // If poolUpkeep fails for any other reason, emit event
            emit PoolUpkeepError(_pool, reason);
        }
    }

    /**
     * @notice Called by keepers to perform an update on multiple pools
     * @param pools pool codes to perform the update for
     */
    function performUpkeepMultiplePools(address[] calldata pools) external {
        for (uint256 i = 0; i < pools.length; i++) {
            performUpkeepSinglePool(pools[i]);
        }
    }

    /**
     * @notice Pay keeper for upkeep
     * @param _pool Address of the given pool
     * @param _gasPrice Price of a single gas unit (in ETH)
     * @param _gasSpent Number of gas units spent
     */
    function payKeeper(
        address _pool,
        uint256 _gasPrice,
        uint256 _gasSpent
    ) internal {
        uint256 reward = keeperReward(_pool, _gasPrice, _gasSpent);
        try IStrategy(_pool).payKeeper(msg.sender, reward) {
            emit KeeperPaid(_pool, msg.sender, reward);
        } catch Error(string memory reason) {
            // Usually occurs if pool just started and does not have any funds
            emit KeeperPaymentError(_pool, msg.sender, reward);
        }
    }

    /**
     * @notice Payment keeper receives for performing upkeep on a given pool
     * @param _pool Address of the given pool
     * @param _gasPrice Price of a single gas unit (in ETH)
     * @param _gasSpent Number of gas units spent
     * @return Number of settlement tokens to give to the keeper for work performed
     */
    function keeperReward(
        address _pool,
        uint256 _gasPrice,
        uint256 _gasSpent
    ) public view returns (uint256) {
        return IStrategy(_pool).keeperGas(_gasPrice, _gasSpent);
    }
 
    /**
     * @notice Sets the gas price to be used in compensating keepers for successful upkeep
     * @param _price Price (in ETH) per unit gas
     * @dev Only owner
     */
    function setGasPrice(uint256 _price) external onlyOwner {
        gasPrice = _price;
    }
}