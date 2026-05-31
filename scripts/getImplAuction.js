const { upgrades } = require("hardhat");
const PROXY = "0xc37E06A70e4D6357391a99E526C0Ba47cd823980";
async function main() {
  const impl = await upgrades.erc1967.getImplementationAddress(PROXY);
  console.log("Proxy:", PROXY);
  console.log("Implementation:", impl);
}
main().catch(console.error);
