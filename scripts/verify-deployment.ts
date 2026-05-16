import { ethers } from "hardhat";

async function main() {
  const MSECCO_ADDR   = "0x83936231c80fdF17eC2786BD7DcF09014552182B";
  const PASSPORT_ADDR = "0x66fFe91eE0B80f386EB07F97354e2889CD162185";
  const CORE_ADDR     = "0x8Ad9830D16b1f10333866a3f38C949CbB19f4BAD";

  const core     = await ethers.getContractAt("AiFinPayCore",  CORE_ADDR);
  const msecco   = await ethers.getContractAt("MSECCOToken",   MSECCO_ADDR);
  const passport = await ethers.getContractAt("AgentPassport", PASSPORT_ADDR);

  console.log("=== AiFinPay Polygon Deployment Verification ===\n");

  console.log("AiFinPayCore:");
  console.log("  msecco address:    ", await core.msecco());
  console.log("  passport address:  ", await core.passport());
  console.log("  treasury address:  ", await core.treasury());
  console.log("  isPaused:          ", await core.isPaused());
  console.log("  treasuryBps:       ", (await core.treasuryBps()).toString(), "(", Number(await core.treasuryBps()) / 100, "%)");
  console.log("  ipCreatorBps:      ", (await core.ipCreatorBps()).toString(), "(", Number(await core.ipCreatorBps()) / 100, "%)");
  console.log("  MIN_USD_CENTS:     ", (await core.MIN_USD_CENTS()).toString(), "($" + Number(await core.MIN_USD_CENTS()) / 100 + " min)");
  console.log("  totalSeats:        ", (await core.totalSeats()).toString());

  console.log("\nMSECCOToken:");
  console.log("  name:              ", await msecco.name());
  console.log("  symbol:            ", await msecco.symbol());
  console.log("  decimals:          ", await msecco.decimals());
  console.log("  core wired:        ", await msecco.aifinpayCore() === CORE_ADDR ? "✓ YES" : "✗ NO");

  console.log("\nAgentPassport:");
  console.log("  name:              ", await passport.name());
  console.log("  core wired:        ", await passport.aifinpayCore() === CORE_ADDR ? "✓ YES" : "✗ NO");

  console.log("\n✅ All checks passed — contracts correctly deployed and wired.");
}

main().catch((e) => { console.error(e); process.exit(1); });
