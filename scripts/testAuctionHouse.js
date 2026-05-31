const { ethers } = require("hardhat");

const AUCTION   = "0xc37E06A70e4D6357391a99E526C0Ba47cd823980";
const REGISTRY  = "0xBBE91358c99CB1b78577d9559Ee657C6FE727193";
const REGISTRAR = "0xd1C027318d606Ed213c605dEe169BcDB215767a9";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Testing with:", deployer.address);

  const auctionHouse = await ethers.getContractAt("ANSAuctionHouse", AUCTION);
  const registrar    = await ethers.getContractAt("ANSRegistrar",    REGISTRAR);

  const DURATION_12M = 365 * 24 * 60 * 60;
  const DURATION_1D  = 1 * 24 * 60 * 60;
  const secret       = ethers.utils.formatBytes32String("auctionsecret");
  const name         = "auctiontest";

  // Register a name for auction testing
  console.log("\n--- SETUP: Register auctiontest.arc ---");
  const commitment = await registrar.makeCommitment(name, deployer.address, secret);
  const txC = await registrar.commit(commitment);
  await txC.wait();
  console.log("Committed. Waiting 65 seconds...");
  await new Promise(r => setTimeout(r, 65000));

  const price = await registrar.calculatePrice(name.length, DURATION_12M);
  const txR = await registrar.register(name, deployer.address, secret, DURATION_12M, { value: price });
  await txR.wait();
  console.log("Registered auctiontest.arc ?");

  const namehash     = await registrar.namehashOf(name);
  const startingBid  = ethers.utils.parseEther("10");

  // -- TEST 1: createAuction -------------------------------------------------
  console.log("\n--- TEST 1: createAuction ---");
  const tx1 = await auctionHouse.createAuction(namehash, startingBid, DURATION_1D);
  await tx1.wait();
  const totalAuctions = await auctionHouse.totalAuctions();
  console.log("Total auctions:", totalAuctions.toString());
  console.log("TEST 1 PASSED ?");

  // -- TEST 2: getAuction ----------------------------------------------------
  console.log("\n--- TEST 2: getAuction ---");
  const auction = await auctionHouse.getAuction(1);
  console.log("Seller:", auction.seller);
  console.log("Starting bid:", ethers.utils.formatEther(auction.startingBid), "USDC");
  console.log("Settled:", auction.settled);
  console.log("TEST 2 PASSED ?");

  // -- TEST 3: isActive ------------------------------------------------------
  console.log("\n--- TEST 3: isActive ---");
  const active = await auctionHouse.isActive(1);
  console.log("Is active:", active);
  if (!active) throw new Error("TEST 3 FAILED");
  console.log("TEST 3 PASSED ?");

  // -- TEST 4: reject self bid -----------------------------------------------
  console.log("\n--- TEST 4: reject self bid ---");
  try {
    await auctionHouse.placeBid(1, { value: startingBid });
    throw new Error("TEST 4 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 4 FAILED")) throw e;
    console.log("Correctly rejected self bid");
    console.log("TEST 4 PASSED ?");
  }

  // -- TEST 5: reject low bid ------------------------------------------------
  console.log("\n--- TEST 5: reject low bid ---");
  try {
    await auctionHouse.placeBid(1, { value: ethers.utils.parseEther("1") });
    throw new Error("TEST 5 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 5 FAILED")) throw e;
    console.log("Correctly rejected low bid");
    console.log("TEST 5 PASSED ?");
  }

  // -- TEST 6: reject zero starting bid -------------------------------------
  console.log("\n--- TEST 6: reject zero starting bid ---");
  try {
    await auctionHouse.createAuction(namehash, 0, DURATION_1D);
    throw new Error("TEST 6 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 6 FAILED")) throw e;
    console.log("Correctly rejected zero starting bid");
    console.log("TEST 6 PASSED ?");
  }

  // -- TEST 7: reject invalid duration --------------------------------------
  console.log("\n--- TEST 7: reject invalid duration ---");
  try {
    await auctionHouse.createAuction(namehash, startingBid, 12345);
    throw new Error("TEST 7 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 7 FAILED")) throw e;
    console.log("Correctly rejected invalid duration");
    console.log("TEST 7 PASSED ?");
  }

  // -- TEST 8: cancelAuction before bids ------------------------------------
  console.log("\n--- TEST 8: cancelAuction ---");
  const tx8 = await auctionHouse.cancelAuction(1);
  await tx8.wait();
  const auctionAfter = await auctionHouse.getAuction(1);
  console.log("Cancelled:", auctionAfter.cancelled);
  if (!auctionAfter.cancelled) throw new Error("TEST 8 FAILED");
  console.log("TEST 8 PASSED ?");

  // -- TEST 9: reject settle before end -------------------------------------
  console.log("\n--- TEST 9: reject settle before auction ends ---");
  const tx9a = await auctionHouse.createAuction(namehash, startingBid, DURATION_1D);
  await tx9a.wait();
  try {
    await auctionHouse.settleAuction(2);
    throw new Error("TEST 9 FAILED");
  } catch(e) {
    if (e.message.includes("TEST 9 FAILED")) throw e;
    console.log("Correctly rejected early settlement");
    console.log("TEST 9 PASSED ?");
  }

  console.log("\n=============================");
  console.log("ALL 9 TESTS PASSED ?");
  console.log("=============================");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
