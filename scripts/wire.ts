import { ethers } from "hardhat";

const MSECCO   = "0x83936231c80fdF17eC2786BD7DcF09014552182B";
const PASSPORT = "0x66fFe91eE0B80f386EB07F97354e2889CD162185";
const CORE     = "0x8Ad9830D16b1f10333866a3f38C949CbB19f4BAD";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Wiring with:", deployer.address);

  const feeData = await ethers.provider.getFeeData();
  const gasPrice = feeData.gasPrice! * 2n;
  console.log("Gas price:", ethers.formatUnits(gasPrice, "gwei"), "gwei");

  const MSECCOToken   = await ethers.getContractFactory("MSECCOToken");
  const AgentPassport = await ethers.getContractFactory("AgentPassport");

  const msecco   = MSECCOToken.attach(MSECCO);
  const passport = AgentPassport.attach(PASSPORT);

  console.log("\nSetting core on MSECCOToken...");
  const tx1 = await msecco.setCore(CORE, { gasPrice });
  await tx1.wait();
  console.log("   Done. Tx:", tx1.hash);

  console.log("Setting core on AgentPassport...");
  const tx2 = await passport.setCore(CORE, { gasPrice });
  await tx2.wait();
  console.log("   Done. Tx:", tx2.hash);

  const coreFromMsecco   = await msecco.aifinpayCore();
  const coreFromPassport = await passport.aifinpayCore();
  console.log("\n=== VERIFICATION ===");
  console.log("msecco.aifinpayCore:  ", coreFromMsecco,   coreFromMsecco === CORE ? "✅" : "❌");
  console.log("passport.aifinpayCore:", coreFromPassport, coreFromPassport === CORE ? "✅" : "❌");

  console.log("\n=== ALL DONE ===");
  console.log("MSECCOToken:  ", MSECCO);
  console.log("AgentPassport:", PASSPORT);
  console.log("AiFinPayCore: ", CORE);
}

main().catch((e) => { console.error(e); process.exit(1); });
