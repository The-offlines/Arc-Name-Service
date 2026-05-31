const { upgrades } = require("hardhat");

const PROXY = "0xcF30a71ebC4d2b64Fa5059f2D08c6cb80E048C38";

async function main() {
  const impl = await upgrades.erc1967.getImplementationAddress(PROXY);
  console.log("Proxy:", PROXY);
  console.log("Implementation:", impl);
}

main().catch(console.error);
