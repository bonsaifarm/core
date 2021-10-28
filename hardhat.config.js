require("dotenv").config();
require("@nomiclabs/hardhat-etherscan");
require("@nomiclabs/hardhat-waffle");

const accounts = {
  mnemonic:
    process.env.MNEMONIC ||
    "test test test test test test test test test test test junk",
};

// You have to export an object to set up your config
// This object can have the following optional entries:
// defaultNetwork, networks, solc, and paths.
// Go to https://buidler.dev/config/ to learn more
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  //defaultNetwork: "goerli",
  networks: {
    hardhat: {
      live: false,
      saveDeployments: true,
      tags: ["test", "local"],
      accounts: {
        accountsBalance: '1000000000000000000000000'
      }
    },
    bsc: {
      url: "https://bsc-dataseed1.ninicoin.io/",
      accounts,
      chainId: 56,
      live: true,
      saveDeployments: true,
    },
    "bsc-testnet": {
      url: "https://data-seed-prebsc-2-s2.binance.org:8545/",
      accounts,
      chainId: 97,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      // gasMultiplier: 2,
    },
    heco: {
      url: "https://http-mainnet.hecochain.com",
      accounts,
      chainId: 128,
      live: true,
      saveDeployments: true,
    },
    polygon: {
      url: "https://polygon-rpc.com",
      accounts,
      chainId: 137,
      live: true,
      saveDeployments: true,
      gasPrice: 30000000000,
      gasMultiplier: 2,
    }
  },
  solc: {
    version: "0.6.12",
  },
  paths: {
    //tests: "./test/doge",
  },
  etherscan: {
    apiKey: process.env.BSCSCAN_KEY,
  },
};
