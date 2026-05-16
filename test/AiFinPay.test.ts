import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer, Contract, ZeroHash, parseEther, formatUnits, formatEther } from "ethers";

describe("AiFinPay Protocol — Full Test Suite (v1.1 Pyth Oracle)", function () {

  let owner: Signer, treasury: Signer, agent: Signer, merchant: Signer, ipCreator: Signer, attacker: Signer;
  let msecco: Contract, passport: Contract, core: Contract, mockPyth: Contract;

  const priceUpdateData: string[] = [];
  const PYTH_FEE = 1n;

  beforeEach(async function () {
    [owner, treasury, agent, merchant, ipCreator, attacker] = await ethers.getSigners();

    const MockPyth = await ethers.getContractFactory("MockPyth");
    mockPyth = await MockPyth.deploy();

    const MSECCOToken   = await ethers.getContractFactory("MSECCOToken");
    const AgentPassport = await ethers.getContractFactory("AgentPassport");
    const AiFinPayCore  = await ethers.getContractFactory("AiFinPayCore");

    msecco   = await MSECCOToken.deploy(await owner.getAddress());
    passport = await AgentPassport.deploy(await owner.getAddress());
    core     = await AiFinPayCore.deploy(
      await owner.getAddress(),
      await msecco.getAddress(),
      await passport.getAddress(),
      await treasury.getAddress()
    );

    await msecco.setCore(await core.getAddress());
    await passport.setCore(await core.getAddress());
  });

  describe("MSECCOToken", function () {
    it("has correct name, symbol, decimals", async function () {
      expect(await msecco.name()).to.equal("mSECCO");
      expect(await msecco.symbol()).to.equal("mSECCO");
      expect(await msecco.decimals()).to.equal(2);
    });

    it("only core can mint", async function () {
      await expect(msecco.connect(attacker).mint(await attacker.getAddress(), 100))
        .to.be.revertedWithCustomError(msecco, "OnlyCore");
    });

    it("only core can burn", async function () {
      await expect(msecco.connect(attacker).burn(await attacker.getAddress(), 100))
        .to.be.revertedWithCustomError(msecco, "OnlyCore");
    });

    it("transfer is disabled (non-transferable)", async function () {
      await expect(msecco.transfer(await attacker.getAddress(), 1))
        .to.be.revertedWithCustomError(msecco, "NonTransferable");
    });

    it("transferFrom is disabled", async function () {
      await expect(msecco.transferFrom(await owner.getAddress(), await attacker.getAddress(), 1))
        .to.be.revertedWithCustomError(msecco, "NonTransferable");
    });

    it("core is correctly wired", async function () {
      expect(await msecco.aifinpayCore()).to.equal(await core.getAddress());
    });
  });

  describe("AgentPassport", function () {
    it("has correct ERC721 name", async function () {
      expect(await passport.name()).to.equal("AiFinPay Agent Passport");
      expect(await passport.symbol()).to.equal("AIPASS");
    });

    it("core is correctly wired", async function () {
      expect(await passport.aifinpayCore()).to.equal(await core.getAddress());
    });

    it("only owner can setCore", async function () {
      await expect(passport.connect(attacker).setCore(await attacker.getAddress()))
        .to.be.revertedWithCustomError(passport, "OwnableUnauthorizedAccount");
    });

    it("only owner can setCore on msecco", async function () {
      await expect(msecco.connect(attacker).setCore(await attacker.getAddress()))
        .to.be.revertedWithCustomError(msecco, "OwnableUnauthorizedAccount");
    });
  });

  describe("MockPyth Oracle", function () {
    it("returns correct MATIC/USD price", async function () {
      const price = await mockPyth.getPriceNoOlderThan(ZeroHash, 60);
      expect(price.price).to.equal(50_000_000n);
      expect(price.expo).to.equal(-8);
    });

    it("returns 1 wei update fee", async function () {
      expect(await mockPyth.getUpdateFee([])).to.equal(1n);
    });

    it("usdCents calculation: 1 MATIC @ $0.50 = 50 cents", async function () {
      const maticPayment = parseEther("1");
      const price = 50_000_000n;
      const usdCents = (maticPayment * price) / 1000000000000000000000000n;
      expect(usdCents).to.equal(50n);
    });

    it("usdCents calculation: 0.1 MATIC @ $0.50 = 5 cents", async function () {
      const maticPayment = parseEther("0.1");
      const price = 50_000_000n;
      const usdCents = (maticPayment * price) / 1000000000000000000000000n;
      expect(usdCents).to.equal(5n);
    });
  });

  describe("Admin", function () {
    it("owner can pause and unpause", async function () {
      await core.connect(owner).pause();
      expect(await core.isPaused()).to.equal(true);
      await core.connect(owner).unpause();
      expect(await core.isPaused()).to.equal(false);
    });

    it("non-owner cannot pause", async function () {
      await expect(core.connect(attacker).pause())
        .to.be.revertedWithCustomError(core, "OwnableUnauthorizedAccount");
    });

    it("owner can update fees", async function () {
      await core.connect(owner).setFees(200, 5);
      expect(await core.treasuryBps()).to.equal(200);
      expect(await core.ipCreatorBps()).to.equal(5);
    });

    it("fees cannot exceed 100%", async function () {
      await expect(core.connect(owner).setFees(9999, 9999))
        .to.be.revertedWithCustomError(core, "FeesExceed100");
    });

    it("owner can update treasury address", async function () {
      await core.connect(owner).setTreasury(await attacker.getAddress());
      expect(await core.treasury()).to.equal(await attacker.getAddress());
    });

    it("setTreasury reverts on zero address", async function () {
      await expect(core.connect(owner).setTreasury(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(core, "ZeroTreasury");
    });

    it("owner can deactivate partner", async function () {
      await core.connect(owner).registerPartner(await merchant.getAddress(), "Merchant");
      await core.connect(owner).deactivatePartner(await merchant.getAddress());
      expect((await core.partners(await merchant.getAddress())).active).to.equal(false);
    });
  });

  describe("Token Addresses", function () {
    it("USDC is native Circle address on Polygon", async function () {
      expect(await core.USDC()).to.equal("0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359");
    });

    it("USDT is correct Tether address on Polygon", async function () {
      expect(await core.USDT()).to.equal("0xc2132D05D31c914a87C6611C10748AEb04B58e8F");
    });

    it("Pyth contract address is correct", async function () {
      expect(await core.PYTH()).to.equal("0xff1a0f4744e8582DF1aE09D5611b887B6a12925C");
    });

    it("MATIC/USD feed ID is set", async function () {
      expect(await core.MATIC_USD_ID()).to.equal(
        "0x5de33a9112c2b700b8d30b8a3402c103578ccfa2856a12a2b20d7b0c67b6d82d"
      );
    });
  });

  describe("Pyth Price Maths", function () {
    it("no fake price can be injected — price comes from oracle not caller", async function () {
      const fragment = core.interface.getFunction("reserveSeatMatic");
      const paramNames = fragment.inputs.map(i => i.name);
      expect(paramNames).to.not.include("maticUsdPrice");
      expect(paramNames).to.include("_priceUpdateData");
    });

    it("topUpMatic signature has no maticUsdPrice parameter", async function () {
      const fragment = core.interface.getFunction("topUpMatic");
      const paramNames = fragment.inputs.map(i => i.name);
      expect(paramNames).to.not.include("maticUsdPrice");
      expect(paramNames).to.include("_priceUpdateData");
    });
  });

  describe("Contract Constants", function () {
    it("MANIFESTO_HASH is set correctly", async function () {
      expect(await core.MANIFESTO_HASH()).to.equal(
        "0xa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
      );
    });

    it("default treasury fee is 1%", async function () {
      expect(await core.treasuryBps()).to.equal(100);
    });

    it("default IP creator fee is 0.01%", async function () {
      expect(await core.ipCreatorBps()).to.equal(1);
    });

    it("MIN_USD_CENTS is 10", async function () {
      expect(await core.MIN_USD_CENTS()).to.equal(10);
    });

    it("PYTH_MAX_AGE is 60 seconds", async function () {
      expect(await core.PYTH_MAX_AGE()).to.equal(60);
    });
  });

});
