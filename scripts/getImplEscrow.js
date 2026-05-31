const { upgrades } = require("hardhat");

const PROXY = "0x2c2824318d40bc1774cDaef0D04AD336b07b5A09";

async function main() {
  const impl = await upgrades.erc1967.getImplementationAddress(PROXY);
  console.log("Proxy:", PROXY);
  console.log("Implementation:", impl);
}

main().catch(console.error);
