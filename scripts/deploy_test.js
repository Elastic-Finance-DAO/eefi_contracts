const hre = require("hardhat");

async function main() {
    const accounts = await hre.ethers.getSigners();
    const erc20Factory = await hre.ethers.getContractFactory("FakeERC20");
    const ampl = await erc20Factory.deploy();

    const uniswapRouterFactory = await hre.ethers.getContractFactory("FakeUniswapV2Router02");
    const router = await uniswapRouterFactory.deploy();

    const vaultFactory = await hre.ethers.getContractFactory("AmplesenseVault");
    const vault = await vaultFactory.deploy(router.address, ampl.address, accounts[1].address, accounts[2].address, accounts[3].address);

    console.log("Vault deployed to:", vault.address);
    console.log("AMPL deployed to:", ampl.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
