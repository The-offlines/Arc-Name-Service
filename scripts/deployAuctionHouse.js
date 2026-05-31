const { ethers, upgrades } = require("hardhat");

const REGISTRY_ADDRESS = "0xBBE91358c99CB1b78577d9559Ee657C6FE727193";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.utils.formatEther(balance), "USDC");

  const ANSAuctionHouse = await ethers.getContractFactory("ANSAuctionHouse");

  console.log("Deploying ANSAuctionHouse proxy...");
  const proxy = await upgrades.deployProxy(
    ANSAuctionHouse,
    [deployer.address, REGISTRY_ADDRESS],
    { initializer: "initialize", kind: "uups" }
  );

  await proxy.deployed();

  console.log("ANSAuctionHouse proxy deployed to:", proxy.address);
  console.log("Registry:", await proxy.registry());
  console.log("Owner:",    await proxy.owner());

  // Authorize auction house as registrar
  console.log("Authorizing auction house as registrar...");
  const registry = await ethers.getContractAt("ANSRegistry", REGISTRY_ADDRESS);
  const tx = await registry.setRegistrar(proxy.address, true);
  await tx.wait();
  console.log("AuctionHouse authorized:", await registry.isRegistrar(proxy.address));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
