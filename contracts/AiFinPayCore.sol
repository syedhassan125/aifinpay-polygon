// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MSECCOToken.sol";
import "./AgentPassport.sol";

// ── Pyth Interface (Pull Oracle) ───────────────────────────────────────────────
interface IPyth {
    struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory price);
}

/// @title AiFinPayCore v5.3 — Polygon mainnet
/// @notice Adds ARP referral tier system + configurable B2B fees (feature parity with Solana v0.5.3)
contract AiFinPayCore is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Stablecoin decimal constant (USDC/USDT = 6 decimals) ──────────────────
    uint256 public constant STABLE_DECIMALS_DIVISOR = 10_000; // 1 cent = 10_000 base units

    // ── Pyth Oracle ────────────────────────────────────────────────────────────
    IPyth   public constant PYTH         = IPyth(0xff1a0f4744e8582DF1aE09D5611b887B6a12925C);
    bytes32 public constant MATIC_USD_ID = 0x5de33a9112c2b700b8d30b8a3402c103578ccfa2856a12a2b20d7b0c67b6d82d;
    uint    public constant PYTH_MAX_AGE = 60;

    // ── Constants ──────────────────────────────────────────────────────────────
    uint256 public constant USD_CENTS_PER_MSECCO = 1;
    uint256 public constant MIN_USD_CENTS        = 10;  // $0.10 minimum (updated v1.2)
    uint256 public constant BPS_DENOMINATOR      = 10_000;
    uint256 public constant REFERRAL_BONUS_MSECCO = 10; // mSECCO bonus per referral claim

    bytes32 public constant MANIFESTO_HASH =
        0xa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2;

    // ── Stablecoins (Polygon mainnet) ──────────────────────────────────────────
    address public constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address public constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    // ── ARP Referral Tier Thresholds ───────────────────────────────────────────
    uint256 public constant TIER_PARTNER_MIN    = 100;
    uint256 public constant TIER_AMBASSADOR_MIN = 500;
    uint256 public constant TIER_ORACLE_MIN     = 1000;

    // ── ARP Referral Fee BPS (configurable by owner) ───────────────────────────
    uint256 public arpScoutBps      = 50;  // 0.50%
    uint256 public arpPartnerBps    = 40;  // 0.40%
    uint256 public arpAmbassadorBps = 25;  // 0.25%
    uint256 public arpOracleBps     = 10;  // 0.10%

    // ── B2B Configurable Fees (owner = Gnosis Safe multisig) ──────────────────
    uint256 public treasuryBps  = 100; // 1.00% → treasury
    uint256 public ipCreatorBps = 1;   // 0.01% → IP creator

    // ── State ──────────────────────────────────────────────────────────────────
    MSECCOToken   public msecco;
    AgentPassport public passport;
    address       public treasury;
    bool          public isPaused;

    struct Seat {
        uint256 usdCentsPaid;
        uint256 mseccoBalance;
        uint8   assetType;        // 0=MATIC, 1=USDC, 2=USDT
        uint256 createdAt;
        uint256 totalReferrals;   // ARP: total referrals made by this agent
        address referrer;         // ARP: who referred this agent
        bool    referralClaimed;  // ARP: whether referral bonus was claimed
    }

    struct Partner {
        bool    active;
        string  name;
        uint256 registeredAt;
    }

    mapping(address => Seat)    public seats;
    mapping(address => Partner) public partners;
    uint256 public totalSeats;
    uint256 public totalUsdCents;

    // ── Events ─────────────────────────────────────────────────────────────────
    event SeatReserved(address indexed agent, uint256 usdCents, uint256 mseccoMinted, uint8 assetType);
    event TopUp(address indexed agent, uint256 usdCents, uint256 mseccoMinted);
    event PassportMinted(address indexed agent, address ipCreator);
    event B2BPayment(address indexed agent, address indexed merchant, uint256 amount, string orderId);
    event PartnerRegistered(address indexed partner, string name);
    event PartnerDeactivated(address indexed partner);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event AgentVerifiedB2B(address indexed agent);
    event AgentSuspendedB2B(address indexed agent);
    event FeesUpdated(uint256 treasuryBps, uint256 ipCreatorBps);
    event ArpFeesUpdated(uint256 scout, uint256 partner, uint256 ambassador, uint256 oracle);
    event ReferralBonusClaimed(address indexed agent, address indexed referrer, uint256 bonusMsecco);
    event Paused(bool status);

    // ── Modifiers ──────────────────────────────────────────────────────────────
    modifier notPaused() {
        require(!isPaused, "Protocol is paused");
        _;
    }

    modifier hasSeat() {
        require(seats[msg.sender].createdAt != 0, "No seat found");
        _;
    }

    constructor(
        address initialOwner,
        address _msecco,
        address _passport,
        address _treasury
    ) {
        require(initialOwner != address(0), "Zero owner");
        require(_msecco   != address(0), "Zero msecco");
        require(_passport != address(0), "Zero passport");
        require(_treasury != address(0), "Zero treasury");
        _transferOwnership(initialOwner);
        msecco   = MSECCOToken(_msecco);
        passport = AgentPassport(_passport);
        treasury = _treasury;
    }

    // ── Reserve Seat (MATIC + Pyth Pull Oracle) ────────────────────────────────
    /// @param agreementHash   Must equal MANIFESTO_HASH
    /// @param priceUpdateData Fresh price update bytes from Pyth Hermes API
    /// @param referrer        Optional referrer address (pass address(0) for none)
    function reserveSeatMatic(
        bytes32 agreementHash,
        bytes[] calldata priceUpdateData,
        address referrer
    ) external payable notPaused nonReentrant {
        require(agreementHash == MANIFESTO_HASH, "Invalid agreement hash");
        require(msg.value > 0, "Must send MATIC");

        uint pythFee = PYTH.getUpdateFee(priceUpdateData);
        require(msg.value > pythFee, "Insufficient MATIC for fee");
        uint256 maticPayment = msg.value - pythFee;

        PYTH.updatePriceFeeds{value: pythFee}(priceUpdateData);

        IPyth.Price memory p = PYTH.getPriceNoOlderThan(MATIC_USD_ID, PYTH_MAX_AGE);
        require(p.price > 0, "Invalid Pyth price");
        require(p.expo == -8, "Unexpected price exponent");

        uint256 usdCents = (maticPayment * uint256(uint64(p.price))) / 1e24;
        require(usdCents >= MIN_USD_CENTS, "Below minimum");

        _createOrUpdateSeat(msg.sender, usdCents, 0, referrer);

        (bool sent,) = treasury.call{value: maticPayment}("");
        require(sent, "MATIC transfer failed");

        emit SeatReserved(msg.sender, usdCents, usdCents, 0);
    }

    // ── Reserve Seat (USDC/USDT) ───────────────────────────────────────────────
    function reserveSeatStable(
        bytes32 agreementHash,
        address token,
        uint256 amount,
        address referrer
    ) external notPaused nonReentrant {
        require(agreementHash == MANIFESTO_HASH, "Invalid agreement hash");
        require(token == USDC || token == USDT, "Unsupported token");

        uint256 usdCents = amount / STABLE_DECIMALS_DIVISOR;
        require(usdCents >= MIN_USD_CENTS, "Below minimum");

        // EVM-MED-001: effects before interactions (CEI pattern)
        _createOrUpdateSeat(msg.sender, usdCents, token == USDC ? 1 : 2, referrer);

        IERC20(token).safeTransferFrom(msg.sender, treasury, amount);

        emit SeatReserved(msg.sender, usdCents, usdCents, token == USDC ? 1 : 2);
    }

    // ── Top Up (MATIC + Pyth Pull Oracle) ─────────────────────────────────────
    function topUpMatic(bytes[] calldata priceUpdateData) external payable notPaused nonReentrant hasSeat {
        uint pythFee = PYTH.getUpdateFee(priceUpdateData);
        require(msg.value > pythFee, "Insufficient MATIC for fee");
        uint256 maticPayment = msg.value - pythFee;

        PYTH.updatePriceFeeds{value: pythFee}(priceUpdateData);

        IPyth.Price memory p = PYTH.getPriceNoOlderThan(MATIC_USD_ID, PYTH_MAX_AGE);
        require(p.price > 0, "Invalid Pyth price");
        require(p.expo == -8, "Unexpected price exponent");

        uint256 usdCents = (maticPayment * uint256(uint64(p.price))) / 1e24;
        require(usdCents >= MIN_USD_CENTS, "Below minimum");

        seats[msg.sender].usdCentsPaid  += usdCents;
        seats[msg.sender].mseccoBalance += usdCents;
        totalUsdCents += usdCents;
        msecco.mint(msg.sender, usdCents);

        (bool sent,) = treasury.call{value: maticPayment}("");
        require(sent, "MATIC transfer failed");

        emit TopUp(msg.sender, usdCents, usdCents);
    }

    // ── Top Up (Stablecoin) ────────────────────────────────────────────────────
    function topUpStable(address token, uint256 amount) external notPaused nonReentrant hasSeat {
        require(token == USDC || token == USDT, "Unsupported token");
        uint256 usdCents = amount / STABLE_DECIMALS_DIVISOR;
        require(usdCents >= MIN_USD_CENTS, "Below minimum");

        // EVM-MED-001: effects before interactions (CEI pattern)
        seats[msg.sender].usdCentsPaid  += usdCents;
        seats[msg.sender].mseccoBalance += usdCents;
        totalUsdCents += usdCents;
        msecco.mint(msg.sender, usdCents);

        IERC20(token).safeTransferFrom(msg.sender, treasury, amount);

        emit TopUp(msg.sender, usdCents, usdCents);
    }

    // ── Mint Passport ──────────────────────────────────────────────────────────
    // EVM-LOW-002: hasSeat ensures agent has economic participation before passport issuance
    function mintPassport(address ipCreator, bytes32 ipMetadata, uint64 dailyLimit) external notPaused nonReentrant hasSeat {
        passport.mintPassport(msg.sender, ipCreator, ipMetadata, dailyLimit);
        emit PassportMinted(msg.sender, ipCreator);
    }

    // ── Partner Registry ───────────────────────────────────────────────────────
    function registerPartner(address partner, string calldata name) external onlyOwner {
        require(partner != address(0), "Zero partner");
        require(bytes(name).length != 0, "Empty partner name");
        partners[partner] = Partner({ active: true, name: name, registeredAt: block.timestamp });
        emit PartnerRegistered(partner, name);
    }

    function deactivatePartner(address partner) external onlyOwner {
        partners[partner].active = false;
        emit PartnerDeactivated(partner);
    }

    // ── B2B Pay ────────────────────────────────────────────────────────────────
    /// @notice Atomic split: merchant gets majority / treasury gets treasuryBps / IP creator gets ipCreatorBps
    function b2bPay(
        address payable merchant,
        string calldata orderId
    ) external payable notPaused nonReentrant {
        require(msg.value > 0, "Must send MATIC");
        require(partners[merchant].active, "Partner not active");
        require(passport.isVerifiedB2B(msg.sender), "Agent not Verified_B2B");

        uint256 rawSpendUnits = msg.value / 1e16;
        require(rawSpendUnits > 0, "Payment below minimum unit (0.01 MATIC)");
        require(rawSpendUnits <= type(uint64).max, "Spend amount too large");

        uint64 spendUnits = uint64(rawSpendUnits);
        require(passport.checkAndSpend(msg.sender, spendUnits), "Daily spend limit exceeded");

        uint256 treasuryAmount  = (msg.value * treasuryBps) / BPS_DENOMINATOR;
        uint256 ipCreatorAmount = (msg.value * ipCreatorBps) / BPS_DENOMINATOR;
        uint256 merchantAmount  = msg.value - treasuryAmount - ipCreatorAmount;

        require(treasuryAmount > 0, "Protocol fee failed");

        address ipCreator = passport.getPassport(msg.sender).ipCreator;

        (bool s1,) = merchant.call{value: merchantAmount}("");
        require(s1, "Merchant transfer failed");

        (bool s2,) = treasury.call{value: treasuryAmount}("");
        require(s2, "Treasury transfer failed");

        if (ipCreatorAmount > 0 && ipCreator != address(0)) {
            (bool s3,) = payable(ipCreator).call{value: ipCreatorAmount}("");
            require(s3, "IP creator transfer failed");
        }

        emit B2BPayment(msg.sender, merchant, msg.value, orderId);
    }

    // ── ARP: Claim Referral Bonus ──────────────────────────────────────────────
    /// @notice Agent claims mSECCO bonus based on their referral tier.
    ///         Bonus = arpFeeBps% of their own mSECCO balance, credited once.
    function claimReferralBonus() external notPaused nonReentrant hasSeat {
        Seat storage seat = seats[msg.sender];
        require(!seat.referralClaimed, "Bonus already claimed");
        require(seat.totalReferrals > 0, "No referrals");

        uint256 feeBps = _arpFeeBps(seat.totalReferrals);
        uint256 bonus  = (seat.mseccoBalance * feeBps) / BPS_DENOMINATOR;
        if (bonus == 0) bonus = REFERRAL_BONUS_MSECCO;

        seat.referralClaimed = true;
        seat.mseccoBalance  += bonus;
        msecco.mint(msg.sender, bonus);

        emit ReferralBonusClaimed(msg.sender, seat.referrer, bonus);
    }

    // ── ARP: Get Tier ──────────────────────────────────────────────────────────
    /// @notice Returns the ARP tier name for an agent based on referral count.
    function getArpTier(address agent) external view returns (string memory) {
        uint256 refs = seats[agent].totalReferrals;
        if (refs >= TIER_ORACLE_MIN)     return "Oracle";
        if (refs >= TIER_AMBASSADOR_MIN) return "Ambassador";
        if (refs >= TIER_PARTNER_MIN)    return "Partner";
        return "Scout";
    }

    // ── Admin ──────────────────────────────────────────────────────────────────
    function pause() external onlyOwner {
        isPaused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        isPaused = false;
        emit Paused(false);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Zero address");
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    function setFees(uint256 _treasuryBps, uint256 _ipCreatorBps) external onlyOwner {
        require(_treasuryBps + _ipCreatorBps < BPS_DENOMINATOR, "Fees exceed 100%");
        // EVM-MED-003: prevent treasuryBps=0 which would break b2bPay() invariant
        require(_treasuryBps >= 1, "Treasury fee must be at least 0.01%");
        treasuryBps  = _treasuryBps;
        ipCreatorBps = _ipCreatorBps;
        emit FeesUpdated(_treasuryBps, _ipCreatorBps);
    }

    /// @notice Update ARP referral tier fee percentages (onlyOwner = Gnosis Safe multisig)
    function setArpFees(
        uint256 _scoutBps,
        uint256 _partnerBps,
        uint256 _ambassadorBps,
        uint256 _oracleBps
    ) external onlyOwner {
        require(_scoutBps <= 200 && _partnerBps <= 200 && _ambassadorBps <= 200 && _oracleBps <= 200,
            "ARP fee too high");
        arpScoutBps      = _scoutBps;
        arpPartnerBps    = _partnerBps;
        arpAmbassadorBps = _ambassadorBps;
        arpOracleBps     = _oracleBps;
        emit ArpFeesUpdated(_scoutBps, _partnerBps, _ambassadorBps, _oracleBps);
    }

    function verifyAgentB2B(address agent) external onlyOwner {
        passport.setStatus(agent, 2);
        emit AgentVerifiedB2B(agent);
    }

    // EVM-REC-002: mirror function to suspend a verified agent directly via core
    function suspendAgentB2B(address agent) external onlyOwner {
        passport.setStatus(agent, 3); // STATUS_SUSPENDED
        emit AgentSuspendedB2B(agent);
    }

    // ── Internal ───────────────────────────────────────────────────────────────
    function _createOrUpdateSeat(
        address agent,
        uint256 usdCents,
        uint8   assetType,
        address referrer
    ) internal {
        if (seats[agent].createdAt == 0) {
            seats[agent] = Seat({
                usdCentsPaid:   usdCents,
                mseccoBalance:  usdCents,
                assetType:      assetType,
                createdAt:      block.timestamp,
                totalReferrals: 0,
                referrer:       referrer,
                referralClaimed: false
            });
            totalSeats++;
            // EVM-LOW-001: explicit self-referral guard (defensive, not relying on ordering)
            if (referrer != address(0) && referrer != agent && seats[referrer].createdAt != 0) {
                seats[referrer].totalReferrals++;
            }
        } else {
            seats[agent].usdCentsPaid  += usdCents;
            seats[agent].mseccoBalance += usdCents;
        }
        totalUsdCents += usdCents;
        msecco.mint(agent, usdCents);
    }

    function _arpFeeBps(uint256 totalReferrals) internal view returns (uint256) {
        if (totalReferrals >= TIER_ORACLE_MIN)     return arpOracleBps;
        if (totalReferrals >= TIER_AMBASSADOR_MIN) return arpAmbassadorBps;
        if (totalReferrals >= TIER_PARTNER_MIN)    return arpPartnerBps;
        return arpScoutBps;
    }
}
