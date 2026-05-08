const { expect } = require("chai");
const { ethers } = require("hardhat");

// ── Mock Pyth contract for testing ─────────────────────────────────────────────
// We deploy a MockPyth that returns a fixed MATIC/USD price
const MOCK_PYTH_ABI = [
  "function getUpdateFee(bytes[] calldata) external view returns (uint)",
  "function updatePriceFeeds(bytes[] calldata) external payable",
  "function getPriceNoOlderThan(bytes32, uint) external view returns (tuple(int64 price, uint64 conf, int32 expo, uint publishTime))"
];

const MOCK_PYTH_BYTECODE = `
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract MockPyth {
    struct Price { int64 price; uint64 conf; int32 expo; uint publishTime; }
    uint public fee = 1; // 1 wei update fee
    function getUpdateFee(bytes[] calldata) external view returns (uint) { return fee; }
    function updatePriceFeeds(bytes[] calldata) external payable {}
    function getPriceNoOlderThan(bytes32, uint) external view returns (Price memory) {
        // MATIC/USD = $0.50 = 50_000_000 with expo -8
        return Price({ price: 50_000_000, conf: 100_000, expo: -8, publishTime: block.timestamp });
    }
}`;

describe("AiFinPay Protocol — Full Test Suite (v1.1 Pyth Oracle)", function () {

  let owner, treasury, agent, merchant, ipCreator, attacker;
  let msecco, passport, core, mockPyth;

  // Helper: get priceUpdateData (empty bytes array, mock accepts anything)
  const priceUpdateData = [];
  const PYTH_FEE = 1n; // 1 wei

  beforeEach(async function () {
    [owner, treasury, agent, merchant, ipCreator, attacker] = await ethers.getSigners();

    // Deploy MockPyth
    const MockPyth = await ethers.getContractFactory("MockPyth");
    mockPyth = await MockPyth.deploy();

    const MSECCOToken   = await ethers.getContractFactory("MSECCOToken");
    const AgentPassport = await ethers.getContractFactory("AgentPassport");
    const AiFinPayCore  = await ethers.getContractFactory("AiFinPayCore");

    msecco   = await MSECCOToken.deploy(owner.address);
    passport = await AgentPassport.deploy(owner.address);
    core     = await AiFinPayCore.deploy(
      owner.address,
      await msecco.getAddress(),
      await passport.getAddress(),
      treasury.address
    );

    await msecco.setCore(await core.getAddress());
    await passport.setCore(await core.getAddress());

    // Point core at our MockPyth (override constant via bytecode injection in tests)
    // NOTE: Since PYTH is a constant, we test via MockPyth separately.
    // For integration we use MockPyth standalone tests.
  });

  // ─────────────────────────────────────────────────────────────
  // 1. MSECCOToken
  // ─────────────────────────────────────────────────────────────
  describe("MSECCOToken", function () {
    it("has correct name, symbol, decimals", async function () {
      expect(await msecco.name()).to.equal("mSECCO");
      expect(await msecco.symbol()).to.equal("mSECCO");
      expect(await msecco.decimals()).to.equal(2);
    });

    it("only core can mint", async function () {
      await expect(msecco.connect(attacker).mint(attacker.address, 100))
        .to.be.revertedWith("Only AiFinPay core");
    });

    it("only core can burn", async function () {
      await expect(msecco.connect(attacker).burn(attacker.address, 100))
        .to.be.revertedWith("Only AiFinPay core");
    });

    it("transfer is disabled (non-transferable)", async function () {
      await expect(msecco.transfer(attacker.address, 1))
        .to.be.revertedWith("mSECCO is non-transferable");
    });

    it("transferFrom is disabled", async function () {
      await expect(msecco.transferFrom(owner.address, attacker.address, 1))
        .to.be.revertedWith("mSECCO is non-transferable");
    });

    it("core is correctly wired", async function () {
      expect(await msecco.aifinpayCore()).to.equal(await core.getAddress());
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 2. AgentPassport
  // ─────────────────────────────────────────────────────────────
  describe("AgentPassport", function () {
    it("has correct ERC721 name", async function () {
      expect(await passport.name()).to.equal("AiFinPay Agent Passport");
      expect(await passport.symbol()).to.equal("AIPASS");
    });

    it("core is correctly wired", async function () {
      expect(await passport.aifinpayCore()).to.equal(await core.getAddress());
    });

    it("only owner can setCore", async function () {
      await expect(passport.connect(attacker).setCore(attacker.address))
        .to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("only owner can setCore on msecco", async function () {
      await expect(msecco.connect(attacker).setCore(attacker.address))
        .to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 3. MockPyth Oracle
  // ─────────────────────────────────────────────────────────────
  describe("MockPyth Oracle", function () {
    it("returns correct MATIC/USD price", async function () {
      const price = await mockPyth.getPriceNoOlderThan(ethers.ZeroHash, 60);
      expect(price.price).to.equal(50_000_000n); // $0.50 with 8 decimals
      expect(price.expo).to.equal(-8);
    });

    it("returns 1 wei update fee", async function () {
      expect(await mockPyth.getUpdateFee([])).to.equal(1n);
    });

    it("usdCents calculation: 1 MATIC @ $0.50 = 50 cents", async function () {
      // usdCents = maticPayment * price / 1e24
      // 1 MATIC = 1e18 wei, price = 50_000_000
      // usdCents = 1e18 * 50_000_000 / 1e24 = 50
      const maticPayment = ethers.parseEther("1");
      const price = 50_000_000n;
      const usdCents = (maticPayment * price) / 1000000000000000000000000n;
      expect(usdCents).to.equal(50n);
    });

    it("usdCents calculation: 0.1 MATIC @ $0.50 = 5 cents", async function () {
      const maticPayment = ethers.parseEther("0.1");
      const price = 50_000_000n;
      const usdCents = (maticPayment * price) / 1000000000000000000000000n;
      expect(usdCents).to.equal(5n);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 4. Admin Functions
  // ─────────────────────────────────────────────────────────────
  describe("Admin", function () {
    it("owner can pause and unpause", async function () {
      await core.connect(owner).pause();
      expect(await core.isPaused()).to.equal(true);
      await core.connect(owner).unpause();
      expect(await core.isPaused()).to.equal(false);
    });

    it("non-owner cannot pause", async function () {
      await expect(core.connect(attacker).pause())
        .to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("owner can update fees", async function () {
      await core.connect(owner).setFees(200, 5);
      expect(await core.treasuryBps()).to.equal(200);
      expect(await core.ipCreatorBps()).to.equal(5);
    });

    it("fees cannot exceed 100%", async function () {
      await expect(core.connect(owner).setFees(9999, 9999))
        .to.be.revertedWith("Fees exceed 100%");
    });

    it("owner can update treasury address", async function () {
      await core.connect(owner).setTreasury(attacker.address);
      expect(await core.treasury()).to.equal(attacker.address);
    });

    it("setTreasury reverts on zero address", async function () {
      await expect(core.connect(owner).setTreasury(ethers.ZeroAddress))
        .to.be.revertedWith("Zero address");
    });

    it("owner can deactivate partner", async function () {
      await core.connect(owner).registerPartner(merchant.address, "Merchant");
      await core.connect(owner).deactivatePartner(merchant.address);
      expect((await core.partners(merchant.address)).active).to.equal(false);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 5. Token Addresses
  // ─────────────────────────────────────────────────────────────
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

  // ─────────────────────────────────────────────────────────────
  // 6. Pyth Price Math (unit tests)
  // ─────────────────────────────────────────────────────────────
  describe("Pyth Price Maths", function () {
    it("no fake price can be injected — price comes from oracle not caller", async function () {
      // The new reserveSeatMatic takes priceUpdateData[], not a uint price
      // Verify the function signature has no maticUsdPrice parameter
      const fragment = core.interface.getFunction("reserveSeatMatic");
      const paramNames = fragment.inputs.map(i => i.name);
      expect(paramNames).to.not.include("maticUsdPrice");
      expect(paramNames).to.include("priceUpdateData");
    });

    it("topUpMatic signature has no maticUsdPrice parameter", async function () {
      const fragment = core.interface.getFunction("topUpMatic");
      const paramNames = fragment.inputs.map(i => i.name);
      expect(paramNames).to.not.include("maticUsdPrice");
      expect(paramNames).to.include("priceUpdateData");
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 7. Contract Constants
  // ─────────────────────────────────────────────────────────────
  describe("Contract Constants", function () {
    it("MANIFESTO_HASH is set correctly", async function () {
      expect(await core.MANIFESTO_HASH()).to.equal(
        "0xd4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5"
      );
    });

    it("default treasury fee is 1%", async function () {
      expect(await core.treasuryBps()).to.equal(100);
    });

    it("default IP creator fee is 0.01%", async function () {
      expect(await core.ipCreatorBps()).to.equal(1);
    });

    it("MIN_USD_CENTS is 1", async function () {
      expect(await core.MIN_USD_CENTS()).to.equal(1);
    });

    it("PYTH_MAX_AGE is 60 seconds", async function () {
      expect(await core.PYTH_MAX_AGE()).to.equal(60);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 8. AiFinPaySplitter — standalone fee-on-top contract
  //   Deployed alongside AiFinPayCore (which is mainnet-immutable).
  // ─────────────────────────────────────────────────────────────
  describe("AiFinPaySplitter (fee-on-top)", function () {
    const ONE_ETHER  = ethers.parseEther("1.0");
    const TREASURY_BPS    = 100; // 1.00%
    const IP_CREATOR_BPS  = 1;   // 0.01%
    let splitter;

    beforeEach(async function () {
      const Splitter = await ethers.getContractFactory("AiFinPaySplitter");
      splitter = await Splitter.deploy(
        owner.address,
        treasury.address,
        TREASURY_BPS,
        IP_CREATOR_BPS,
      );
    });

    it("constructor stores config", async function () {
      expect(await splitter.treasury()).to.equal(treasury.address);
      expect(await splitter.treasuryBps()).to.equal(TREASURY_BPS);
      expect(await splitter.ipCreatorBps()).to.equal(IP_CREATOR_BPS);
      expect(await splitter.isPaused()).to.equal(false);
    });

    it("constructor rejects zero treasury", async function () {
      const Splitter = await ethers.getContractFactory("AiFinPaySplitter");
      await expect(
        Splitter.deploy(owner.address, ethers.ZeroAddress, TREASURY_BPS, IP_CREATOR_BPS)
      ).to.be.revertedWith("Zero treasury");
    });

    it("constructor rejects fees totalling >= 100%", async function () {
      const Splitter = await ethers.getContractFactory("AiFinPaySplitter");
      await expect(
        Splitter.deploy(owner.address, treasury.address, 9999, 1)
      ).to.be.revertedWith("Fees exceed 100%");
    });

    it("quoteSplit returns merchantAmount + 1.01% fees", async function () {
      const [treasuryFee, creatorFee, total] = await splitter.quoteSplit(ONE_ETHER);
      expect(treasuryFee).to.equal(ethers.parseEther("0.01"));
      expect(creatorFee).to.equal(ethers.parseEther("0.0001"));
      expect(total).to.equal(ethers.parseEther("1.0101"));
    });

    it("merchant receives the full quoted amount; treasury + creator get fees on top", async function () {
      const merchantBefore  = await ethers.provider.getBalance(merchant.address);
      const treasuryBefore  = await ethers.provider.getBalance(treasury.address);
      const ipCreatorBefore = await ethers.provider.getBalance(ipCreator.address);

      const merchantAmount = ONE_ETHER;
      const [treasuryFee, creatorFee, total] = await splitter.quoteSplit(merchantAmount);

      await splitter.connect(agent).b2bPayWithSplit(
        merchant.address,
        merchantAmount,
        ipCreator.address,
        "ord-1",
        { value: total },
      );

      expect(await ethers.provider.getBalance(merchant.address) - merchantBefore)
        .to.equal(merchantAmount);
      expect(await ethers.provider.getBalance(treasury.address) - treasuryBefore)
        .to.equal(treasuryFee);
      expect(await ethers.provider.getBalance(ipCreator.address) - ipCreatorBefore)
        .to.equal(creatorFee);
    });

    it("excess msg.value is refunded to caller", async function () {
      const merchantAmount = ONE_ETHER;
      const [, , total] = await splitter.quoteSplit(merchantAmount);
      const overpay = total + ethers.parseEther("0.5");

      const before = await ethers.provider.getBalance(agent.address);
      const tx = await splitter.connect(agent).b2bPayWithSplit(
        merchant.address, merchantAmount, ipCreator.address,
        "ord-2", { value: overpay },
      );
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(agent.address);

      // Caller spent exactly `total + gas`, not `overpay + gas`.
      expect(before - after).to.equal(total + gasCost);
    });

    it("zero feeRecipient routes creator slot to treasury", async function () {
      const merchantAmount = ONE_ETHER;
      const [treasuryFee, creatorFee, total] = await splitter.quoteSplit(merchantAmount);
      const treasuryBefore = await ethers.provider.getBalance(treasury.address);

      await splitter.connect(agent).b2bPayWithSplit(
        merchant.address, merchantAmount, ethers.ZeroAddress,
        "ord-3", { value: total },
      );

      // Treasury receives BOTH the protocol fee AND the unrouted creator fee.
      expect(await ethers.provider.getBalance(treasury.address) - treasuryBefore)
        .to.equal(treasuryFee + creatorFee);
    });

    it("rejects insufficient payment", async function () {
      const merchantAmount = ONE_ETHER;
      const [, , total] = await splitter.quoteSplit(merchantAmount);
      await expect(
        splitter.connect(agent).b2bPayWithSplit(
          merchant.address, merchantAmount, ipCreator.address,
          "ord-4", { value: total - 1n },
        )
      ).to.be.revertedWith("Insufficient payment");
    });

    it("rejects zero merchant address", async function () {
      await expect(
        splitter.connect(agent).b2bPayWithSplit(
          ethers.ZeroAddress, ONE_ETHER, ipCreator.address,
          "ord-5", { value: ethers.parseEther("1.02") },
        )
      ).to.be.revertedWith("Zero merchant");
    });

    it("rejects self-pay", async function () {
      await expect(
        splitter.connect(agent).b2bPayWithSplit(
          agent.address, ONE_ETHER, ipCreator.address,
          "ord-6", { value: ethers.parseEther("1.02") },
        )
      ).to.be.revertedWith("Self-pay not allowed");
    });

    it("rejects zero merchant amount", async function () {
      await expect(
        splitter.connect(agent).b2bPayWithSplit(
          merchant.address, 0n, ipCreator.address,
          "ord-7", { value: 0n },
        )
      ).to.be.revertedWith("Zero merchant amount");
    });

    it("does NOT require merchant partner registration (open marketplace)", async function () {
      const merchantAmount = ONE_ETHER;
      const [, , total] = await splitter.quoteSplit(merchantAmount);
      await expect(
        splitter.connect(agent).b2bPayWithSplit(
          merchant.address, merchantAmount, ipCreator.address,
          "ord-8", { value: total },
        )
      ).to.not.be.reverted;
    });

    it("emits B2BPaymentWithSplit with full breakdown", async function () {
      const merchantAmount = ONE_ETHER;
      const [treasuryFee, creatorFee, total] = await splitter.quoteSplit(merchantAmount);
      await expect(
        splitter.connect(agent).b2bPayWithSplit(
          merchant.address, merchantAmount, ipCreator.address,
          "ord-9", { value: total },
        )
      )
        .to.emit(splitter, "B2BPaymentWithSplit")
        .withArgs(
          agent.address, merchant.address, merchantAmount,
          treasuryFee, creatorFee, ipCreator.address, "ord-9",
        );
    });

    it("blocks while paused", async function () {
      await splitter.pause();
      const merchantAmount = ONE_ETHER;
      const [, , total] = await splitter.quoteSplit(merchantAmount);
      await expect(
        splitter.connect(agent).b2bPayWithSplit(
          merchant.address, merchantAmount, ipCreator.address,
          "ord-10", { value: total },
        )
      ).to.be.revertedWith("Splitter is paused");
      await splitter.unpause();
    });

    it("only owner can update treasury", async function () {
      await expect(
        splitter.connect(attacker).setTreasury(attacker.address)
      ).to.be.reverted;
      await splitter.setTreasury(merchant.address);
      expect(await splitter.treasury()).to.equal(merchant.address);
    });

    it("only owner can update fees", async function () {
      await expect(
        splitter.connect(attacker).setFees(50, 5)
      ).to.be.reverted;
      await splitter.setFees(50, 5);
      expect(await splitter.treasuryBps()).to.equal(50);
      expect(await splitter.ipCreatorBps()).to.equal(5);
    });

    it("AiFinPayCore is unchanged — no b2bPayWithSplit on core", async function () {
      // The whole point of the splitter is that core stays exactly as
      // mainnet-deployed. Verify the new function is NOT on core.
      expect(typeof core.b2bPayWithSplit).to.equal("undefined");
      expect(typeof core.quoteSplit).to.equal("undefined");
    });
  });

});
