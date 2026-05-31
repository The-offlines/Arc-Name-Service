const { ethers, upgrades } = require("hardhat");

const REGISTRY_ADDRESS = "0xBBE91358c99CB1b78577d9559Ee657C6FE727193";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.utils.formatEther(balance), "USDC");

  const ANSMarketplace = await ethers.getContractFactory("ANSMarketplace");

  console.log("Deploying ANSMarketplace proxy...");
  const proxy = await upgrades.deployProxy(
    ANSMarketplace,
    [deployer.address, REGISTRY_ADDRESS],
    { initializer: "initialize", kind: "uups" }
  );

  await proxy.deployed();

  console.log("ANSMarketplace proxy deployed to:", proxy.address);
  console.log("Registry:", await proxy.registry());
  console.log("Owner:",    await proxy.owner());

  // Authorize marketplace in registry
  console.log("Authorizing marketplace as registrar...");
  const registry = await ethers.getContractAt("ANSRegistry", REGISTRY_ADDRESS);
  const tx = await registry.setRegistrar(proxy.address, true);
  await tx.wait();
  console.log("Marketplace authorized:", await registry.isRegistrar(proxy.address));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
