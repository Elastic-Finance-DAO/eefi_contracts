const hre = require("hardhat");
import { Authorizer } from "../typechain/Authorizer";
import { Vault } from "../typechain/Vault";
import { StablePool } from "../typechain/StablePool";
import { deployTokens } from "./utils/deploy_tokens";

export async function deployBalancer() {
  let tokens = await deployTokens();
  const ampl = tokens.ampl;
  const eefi = tokens.eefi;
  const usdc = tokens.usdc;
  const weth = tokens.weth;
  const accounts = await hre.ethers.getSigners();

  const vaultFactory = await hre.ethers.getContractFactory("Vault");
  const authorizerFactory = await hre.ethers.getContractFactory("Authorizer");
  const poolFactory = await hre.ethers.getContractFactory("StablePool");
  
  const authorizer = await authorizerFactory.deploy(accounts[0].address) as Authorizer;
  const vault = await vaultFactory.deploy(authorizer.address, weth.address, 100, 100) as Vault;
  const pool_ampl_usdc = await poolFactory.deploy(vault.address, "amplusdc", "amplusdc", [ampl.address,usdc.address], "1000000000000000000", 1e12, 10, 10, accounts[0].address) as StablePool;
  const pool_eefi_usdc = await poolFactory.deploy(vault.address, "usdceefi", "usdceefi", [usdc.address,eefi.address], "1000000000000000000", 1e12, 10, 10, accounts[0].address) as StablePool;
  const pool_usdc_weth = await poolFactory.deploy(vault.address, "usdcweth", "usdcweth", [usdc.address,weth.address], "1000000000000000000", 1e12, 10, 10, accounts[0].address) as StablePool;

  const pool_ampl_usdc_poolId = await pool_ampl_usdc.getPoolId();
  const pool_eefi_usdc_poolId = await pool_eefi_usdc.getPoolId();
  const pool_usdc_weth_poolId = await pool_usdc_weth.getPoolId();

  let amount1 = hre.ethers.BigNumber.from(10000 * 1e9);
  let amount2 = hre.ethers.BigNumber.from(10000 * 1e6);
  await ampl.increaseAllowance(vault.address, amount1);
  await usdc.increaseAllowance(vault.address, amount2);
  let userData = hre.ethers.utils.defaultAbiCoder.encode(['uint256','uint256[]'], [hre.ethers.BigNumber.from(0), [amount1, amount2]])
  await vault.joinPool(pool_ampl_usdc_poolId, accounts[0].address,accounts[0].address, { assets: [ampl.address, usdc.address], maxAmountsIn : [amount1, amount2], userData : userData, fromInternalBalance : false })

  amount1 = hre.ethers.BigNumber.from(10000 * 1e6);
  amount2 = hre.ethers.BigNumber.from(10000 * 1e9);
  await usdc.increaseAllowance(vault.address, amount1);
  await eefi.increaseAllowance(vault.address, amount2);
  userData = hre.ethers.utils.defaultAbiCoder.encode(['uint256','uint256[]'], [hre.ethers.BigNumber.from(0), [amount1, amount2]])
  await vault.joinPool(pool_eefi_usdc_poolId, accounts[0].address,accounts[0].address, { assets: [usdc.address, eefi.address], maxAmountsIn : [amount1, amount2], userData : userData, fromInternalBalance : false })

  amount1 = hre.ethers.BigNumber.from(100000 * 1e6);
  amount2 = hre.ethers.BigNumber.from(hre.ethers.utils.parseUnits("10", "ether"));
  await usdc.increaseAllowance(vault.address, amount1);
  await weth.increaseAllowance(vault.address, amount2);
  userData = hre.ethers.utils.defaultAbiCoder.encode(['uint256','uint256[]'], [hre.ethers.BigNumber.from(0), [amount1, amount2]])
  await vault.joinPool(pool_usdc_weth_poolId, accounts[0].address,accounts[0].address, { assets: [usdc.address, weth.address], maxAmountsIn : [amount1, amount2], userData : userData, fromInternalBalance : false })

  return {vault, pool_ampl_usdc_poolId, pool_eefi_usdc_poolId, pool_usdc_weth_poolId}
}

async function main() {
  let pools = await deployBalancer();
  console.log("Vault deployed to:", pools.vault.address);
  console.log("Pool AMPL/USDC id:", pools.pool_ampl_usdc_poolId);
  console.log("Pool USDC/EEFI id:", pools.pool_eefi_usdc_poolId);
  console.log("Pool USDC/WETH id:", pools.pool_usdc_weth_poolId);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
