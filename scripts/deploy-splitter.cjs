/**
 * Deploy AiFinPaySplitter — standalone fee-on-top atomic split contract.
 *
 * Designed to coexist with the mainnet-deployed AiFinPayCore. Does NOT
 * touch core; can be redeployed/upgraded by deploying a new splitter
 * without affecting seats / mSECCO / passport state.
 *
 * Usage:
 *   TREASURY=0x... TREASURY_BPS=100 IP_CREATOR_BPS=1 \
 *     npx hardhat run scripts/deploy-splitter.cjs --network polygon
 *
 * Env:
 *   TREASURY        — required. Recipient of protocol fee. Should equal
 *                     the canonical Squads multisig.
 *   TREASURY_BPS    — default 100  (1.00%).
 *   IP_CREATOR_BPS  — default 1    (0.01%).
 *   OWNER           — optional. Defaults to deployer. Should be set to
 *                     the multisig address before going live.
 */
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer:        ", deployer.address);
  console.log("Balance:         ", ethers.formatEther(balance), "MATIC");

  const treasury     = process.env.TREASURY;
  const owner        = process.env.OWNER || deployer.address;
  const treasuryBps  = process.env.TREASURY_BPS   ? Number(process.env.TREASURY_BPS)   : 100;
  const ipCreatorBps = process.env.IP_CREATOR_BPS ? Number(process.env.IP_CREATOR_BPS) : 1;

  if (!treasury || !ethers.isAddress(treasury)) {
    throw new Error("Set TREASURY env to the canonical multisig address.");
  }
  console.log("Treasury:        ", treasury);
  console.log("Owner:           ", owner);
  console.log("treasuryBps:     ", treasuryBps);
  console.log("ipCreatorBps:    ", ipCreatorBps);

  const Splitter = await ethers.getContractFactory("AiFinPaySplitter");
  const splitter = await Splitter.deploy(owner, treasury, treasuryBps, ipCreatorBps);
  await splitter.waitForDeployment();
  const addr = await splitter.getAddress();

  console.log("\n=== AiFinPaySplitter DEPLOYED ===");
  console.log("Address:         ", addr);
  console.log("\nVerify on Polygonscan:");
  console.log(
    `npx hardhat verify --network polygon ${addr} ${owner} ${treasury} ${treasuryBps} ${ipCreatorBps}`
  );
}

main().catch((e) => { console.error(e); process.exit(1); });
