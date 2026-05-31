const { ethers } = require("hardhat");

const MARKETPLACE     = "0xc20A83Fa24b129a16514e0725983088c5A208bFe";
const REGISTRY        = "0xBBE91358c99CB1b78577d9559Ee657C6FE727193";
const REGISTRAR       = "0xd1C027318d606Ed213c605dEe169BcDB215767a9";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Testing with:", deployer.address);

  const marketplace = await ethers.getContractAt("ANSMarketplace", MARKETPLACE);
  const registry    = await ethers.getContractAt("ANSRegistry",    REGISTRY);
  const registrar   = await ethers.getContractAt("ANSRegistrar",   REGISTRAR);

  const DURATION_12M = 365 * 24 * 60 * 60;
  const secret       = ethers.utils.formatBytes32String("marketsecret");
  const name         = "shopname";
  const buyer        = "0x2222222222222222222222222222222222222222";

  // Register a name to list
  console.log("\n--- SETUP: Register shopname.arc ---");
  const commitment = await registrar.makeCommitment(name, deployer.address, secret);
  const txC = await registrar.commit(commitment);
  await txC.wait();
  console.log("Committed. Waiting 65 seconds...");
  await new Promise(r => setTimeout(r, 65000));

  const price = await registrar.calculatePrice(name.length, DURATION_12M);
  const txR = await registrar.register(name, deployer.address, secret, DURATION_12M, { value: price });
  await txR.wait();
  console.log("Registered shopname.arc ?");

  const namehash = await registrar.namehashOf(name);

  // -- TEST 1: isListed before listing --------------------------------------
  console.log("\n--- TEST 1: isListed before listing ---");
  const listed1 = await marketplace.isListed(namehash);
  console.log("Is listed:", listed1);
  if (listed1) throw new Error("TEST 1 FAILED");
  console.log("TEST 1 PASSED ?");

  // -- TEST 2: listName ------------------------------------------------------
  console.log("\n--- TEST 2: listName ---");
  const listPrice = ethers.utils.parseEther("10");
  const tx2 = await marketplace.listName(namehash, listPrice);
  await tx2.wait();
  console.log("TX:", tx2.hash);
  console.log("TEST 2 PASSED ?");

  // -- TEST 3: isListed after listing ---------------------------------------
  console.log("\n--- TEST 3: isListed after listing ---");
  const listed3 = await marketplace.isListed(namehash);
  console.log("Is listed:", listed3);
  if (!listed3) throw new Error("TEST 3 FAILED");
  console.log("TEST 3 PASSED ?");

  // -- TEST 4: getListing ----------------------------------------------------
  console.log("\n--- TEST 4: getListing ---");
  const listing = await marketplace.getListing(namehash);
  console.log("Seller:", listing.seller);
  console.log("Price:", ethers.utils.formatEther(listing.price), "USDC");
  console.log("Active:", listing.active);
  console.log("TEST 4 PASSED ?");

  // -- TEST 5: reject self purchase ------------------------------------------
  console.log("\n--- TEST 5: reject self purchase ---");
  try {
    await marketplace.buyName(namehash, { value: listPrice });
    throw new Error("TEST 5 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 5 FAILED")) throw e;
    console.log("Correctly rejected self purchase");
    console.log("TEST 5 PASSED ?");
  }

  // -- TEST 6: reject wrong payment -----------------------------------------
  console.log("\n--- TEST 6: reject wrong payment ---");
  try {
    await marketplace.buyName(namehash, { value: ethers.utils.parseEther("5") });
    throw new Error("TEST 6 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 6 FAILED")) throw e;
    console.log("Correctly rejected wrong payment");
    console.log("TEST 6 PASSED ?");
  }

  // -- TEST 7: reject zero price listing ------------------------------------
  console.log("\n--- TEST 7: reject zero price listing ---");
  const name2 = "zerotest";
  const secret2 = ethers.utils.formatBytes32String("zerosecret");
  const commitment2 = await registrar.makeCommitment(name2, deployer.address, secret2);
  const txC2 = await registrar.commit(commitment2);
  await txC2.wait();
  console.log("Waiting 65 seconds...");
  await new Promise(r => setTimeout(r, 65000));
  const price2 = await registrar.calculatePrice(name2.length, DURATION_12M);
  const txR2 = await registrar.register(name2, deployer.address, secret2, DURATION_12M, { value: price2 });
  await txR2.wait();
  const namehash2 = await registrar.namehashOf(name2);
  try {
    await marketplace.listName(namehash2, 0);
    throw new Error("TEST 7 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 7 FAILED")) throw e;
    console.log("Correctly rejected zero price");
    console.log("TEST 7 PASSED ?");
  }

  // -- TEST 8: cancelListing -------------------------------------------------
  console.log("\n--- TEST 8: cancelListing ---");
  const tx8 = await marketplace.cancelListing(namehash);
  await tx8.wait();
  const listed8 = await marketplace.isListed(namehash);
  console.log("Is listed after cancel:", listed8);
  if (listed8) throw new Error("TEST 8 FAILED");
  console.log("TEST 8 PASSED ?");

  console.log("\n=============================");
  console.log("ALL 8 TESTS PASSED ?");
  console.log("=============================");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
