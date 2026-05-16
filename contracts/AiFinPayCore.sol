// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPyth.sol";
import "./errors/Errors.sol";
import "./MSECCOToken.sol";
import "./AgentPassport.sol";

/// @title AiFinPayCore v5.3 — Polygon mainnet
/// @notice Adds ARP referral tier system + configurable B2B fees (feature parity with Solana v0.5.3)
contract AiFinPayCore is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant STABLE_DECIMALS_DIVISOR = 10_000;
    IPyth   public constant PYTH         = IPyth(0xff1a0f4744e8582DF1aE09D5611b887B6a12925C);
    bytes32 public constant MATIC_USD_ID = 0x5de33a9112c2b700b8d30b8a3402c103578ccfa2856a12a2b20d7b0c67b6d82d;
    uint    public constant PYTH_MAX_AGE = 60;
    uint256 public constant USD_CENTS_PER_MSECCO = 1;
    uint256 public constant MIN_USD_CENTS        = 10;
    uint256 public constant BPS_DENOMINATOR      = 10_000;
    uint256 public constant REFERRAL_BONUS_MSECCO = 10;

    bytes32 public constant MANIFESTO_HASH =
        0xa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2;

    address public constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address public constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    uint256 public constant TIER_PARTNER_MIN    = 100;
    uint256 public constant TIER_AMBASSADOR_MIN = 500;
    uint256 public constant TIER_ORACLE_MIN     = 1000;

    uint256 public arpScoutBps      = 50;
    uint256 public arpPartnerBps    = 40;
    uint256 public arpAmbassadorBps = 25;
    uint256 public arpOracleBps     = 10;

    uint256 public treasuryBps  = 100;
    uint256 public ipCreatorBps = 1;

    MSECCOToken   public msecco;
    AgentPassport public passport;
    address       public treasury;
    bool          public isPaused;

    struct Seat {
        uint256 usdCentsPaid;
        uint256 mseccoBalance;
        uint8   assetType;
        uint256 createdAt;
        uint256 totalReferrals;
        address referrer;
        bool    referralClaimed;
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

    modifier notPaused() {
        if (isPaused) revert ProtocolPaused();
        _;
    }

    modifier hasSeat() {
        if (seats[msg.sender].createdAt == 0) revert NoSeatFound();
        _;
    }

    constructor(
        address initialOwner,
        address _msecco,
        address _passport,
        address _treasury
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        if (_msecco == address(0)) revert ZeroMSECCO();
        if (_passport == address(0)) revert ZeroPassport();
        if (_treasury == address(0)) revert ZeroTreasury();
        msecco = MSECCOToken(_msecco);
        passport = AgentPassport(_passport);
        treasury = _treasury;
    }

    /// @param _agreementHash   Must equal MANIFESTO_HASH
    /// @param _priceUpdateData Fresh price update bytes from Pyth Hermes API
    /// @param _referrer        Optional referrer address (pass address(0) for none)
    function reserveSeatMatic(
        bytes32 _agreementHash,
        bytes[] calldata _priceUpdateData,
        address _referrer
    ) external payable notPaused nonReentrant {
        if (_agreementHash != MANIFESTO_HASH) revert InvalidAgreementHash();
        if (msg.value == 0) revert ZeroMatic();

        uint pythFee = PYTH.getUpdateFee(_priceUpdateData);
        if (msg.value <= pythFee) revert InsufficientMaticForFee();
        uint256 maticPayment = msg.value - pythFee;

        PYTH.updatePriceFeeds{value: pythFee}(_priceUpdateData);

        IPyth.Price memory p = PYTH.getPriceNoOlderThan(MATIC_USD_ID, PYTH_MAX_AGE);
        if (p.price <= 0) revert InvalidPythPrice();
        if (p.expo != -8) revert UnexpectedPriceExponent();

        uint256 usdCents = (maticPayment * uint256(uint64(p.price))) / 1e24;
        if (usdCents < MIN_USD_CENTS) revert BelowMinimum();

        _createOrUpdateSeat(msg.sender, usdCents, 0, _referrer);

        (bool sent,) = treasury.call{value: maticPayment}("");
        if (!sent) revert TreasuryTransferFailed();

        emit SeatReserved(msg.sender, usdCents, usdCents, 0);
    }

function reserveSeatStable(
        bytes32 _agreementHash,
        address _token,
        uint256 _amount,
        address _referrer
    ) external notPaused nonReentrant {
        if (_agreementHash != MANIFESTO_HASH) revert InvalidAgreementHash();
        if (_token != USDC && _token != USDT) revert UnsupportedToken();

        uint256 usdCents = _amount / STABLE_DECIMALS_DIVISOR;
        if (usdCents < MIN_USD_CENTS) revert BelowMinimum();

        _createOrUpdateSeat(msg.sender, usdCents, _token == USDC ? 1 : 2, _referrer);

        IERC20(_token).safeTransferFrom(msg.sender, treasury, _amount);

        emit SeatReserved(msg.sender, usdCents, usdCents, _token == USDC ? 1 : 2);
    }

    function topUpMatic(bytes[] calldata _priceUpdateData) external payable notPaused nonReentrant hasSeat {
        uint pythFee = PYTH.getUpdateFee(_priceUpdateData);
        if (msg.value <= pythFee) revert InsufficientMaticForFee();
        uint256 maticPayment = msg.value - pythFee;

        PYTH.updatePriceFeeds{value: pythFee}(_priceUpdateData);

        IPyth.Price memory p = PYTH.getPriceNoOlderThan(MATIC_USD_ID, PYTH_MAX_AGE);
        if (p.price <= 0) revert InvalidPythPrice();
        if (p.expo != -8) revert UnexpectedPriceExponent();

        uint256 usdCents = (maticPayment * uint256(uint64(p.price))) / 1e24;
        if (usdCents < MIN_USD_CENTS) revert BelowMinimum();

        seats[msg.sender].usdCentsPaid  += usdCents;
        seats[msg.sender].mseccoBalance += usdCents;
        totalUsdCents += usdCents;
        msecco.mint(msg.sender, usdCents);

        (bool sent,) = treasury.call{value: maticPayment}("");
        if (!sent) revert TreasuryTransferFailed();

        emit TopUp(msg.sender, usdCents, usdCents);
    }

    function topUpStable(address _token, uint256 _amount) external notPaused nonReentrant hasSeat {
        if (_token != USDC && _token != USDT) revert UnsupportedToken();
        uint256 usdCents = _amount / STABLE_DECIMALS_DIVISOR;
        if (usdCents < MIN_USD_CENTS) revert BelowMinimum();

        seats[msg.sender].usdCentsPaid  += usdCents;
        seats[msg.sender].mseccoBalance += usdCents;
        totalUsdCents += usdCents;
        msecco.mint(msg.sender, usdCents);

        IERC20(_token).safeTransferFrom(msg.sender, treasury, _amount);

        emit TopUp(msg.sender, usdCents, usdCents);
    }

    function mintPassport(address _ipCreator, bytes32 _ipMetadata, uint64 _dailyLimit) external notPaused nonReentrant hasSeat {
        passport.mintPassport(msg.sender, _ipCreator, _ipMetadata, _dailyLimit);
        emit PassportMinted(msg.sender, _ipCreator);
    }

    function registerPartner(address _partner, string calldata _name) external onlyOwner {
        if (_partner == address(0)) revert ZeroPartner();
        if (bytes(_name).length == 0) revert EmptyPartnerName();
        partners[_partner] = Partner({ active: true, name: _name, registeredAt: block.timestamp });
        emit PartnerRegistered(_partner, _name);
    }

    function deactivatePartner(address _partner) external onlyOwner {
        partners[_partner].active = false;
        emit PartnerDeactivated(_partner);
    }

    /// @notice Atomic split: merchant gets majority / treasury gets treasuryBps / IP creator gets ipCreatorBps
    function b2bPay(
        address payable _merchant,
        string calldata _orderId
    ) external payable notPaused nonReentrant {
        if (msg.value == 0) revert ZeroMatic();
        if (!partners[_merchant].active) revert PartnerNotActive();
        if (!passport.isVerifiedB2B(msg.sender)) revert AgentNotVerifiedB2B();

        uint256 rawSpendUnits = msg.value / 1e16;
        if (rawSpendUnits == 0) revert PaymentBelowMinimum();
        if (rawSpendUnits > type(uint64).max) revert SpendAmountTooLarge();

        uint64 spendUnits = uint64(rawSpendUnits);
        if (!passport.checkAndSpend(msg.sender, spendUnits)) revert DailySpendLimitExceeded();

        uint256 treasuryAmount  = (msg.value * treasuryBps) / BPS_DENOMINATOR;
        uint256 ipCreatorAmount = (msg.value * ipCreatorBps) / BPS_DENOMINATOR;
        uint256 merchantAmount  = msg.value - treasuryAmount - ipCreatorAmount;

        if (treasuryAmount == 0) revert ProtocolFeeFailed();

        address ipCreator = passport.getPassport(msg.sender).ipCreator;

        (bool s1,) = _merchant.call{value: merchantAmount}("");
        if (!s1) revert MerchantTransferFailed();

        (bool s2,) = treasury.call{value: treasuryAmount}("");
        if (!s2) revert TreasuryTransferFailed();

        if (ipCreatorAmount > 0 && ipCreator != address(0)) {
            (bool s3,) = payable(ipCreator).call{value: ipCreatorAmount}("");
            if (!s3) revert IPCreatorTransferFailed();
        }

        emit B2BPayment(msg.sender, _merchant, msg.value, _orderId);
    }

    /// @notice Agent claims mSECCO bonus based on their referral tier.
    ///         Bonus = arpFeeBps% of their own mSECCO balance, credited once.
    function claimReferralBonus() external notPaused nonReentrant hasSeat {
        Seat storage seat = seats[msg.sender];
        if (seat.referralClaimed) revert BonusAlreadyClaimed();
        if (seat.totalReferrals == 0) revert NoReferrals();

        uint256 feeBps = _arpFeeBps(seat.totalReferrals);
        uint256 bonus  = (seat.mseccoBalance * feeBps) / BPS_DENOMINATOR;
        if (bonus == 0) bonus = REFERRAL_BONUS_MSECCO;

        seat.referralClaimed = true;
        seat.mseccoBalance  += bonus;
        msecco.mint(msg.sender, bonus);

        emit ReferralBonusClaimed(msg.sender, seat.referrer, bonus);
    }

    /// @notice Returns the ARP tier name for an agent based on referral count.
    function getArpTier(address agent) external view returns (string memory) {
        uint256 refs = seats[agent].totalReferrals;
        if (refs >= TIER_ORACLE_MIN)     return "Oracle";
        if (refs >= TIER_AMBASSADOR_MIN) return "Ambassador";
        if (refs >= TIER_PARTNER_MIN)    return "Partner";
        return "Scout";
    }

    function pause() external onlyOwner {
        isPaused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        isPaused = false;
        emit Paused(false);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroTreasury();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    function setFees(uint256 _treasuryBps, uint256 _ipCreatorBps) external onlyOwner {
        if (_treasuryBps + _ipCreatorBps >= BPS_DENOMINATOR) revert FeesExceed100();
        if (_treasuryBps < 1) revert TreasuryFeeTooLow();
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
        if (_scoutBps > 200 || _partnerBps > 200 || _ambassadorBps > 200 || _oracleBps > 200)
            revert ARPFeeTooHigh();
        arpScoutBps      = _scoutBps;
        arpPartnerBps    = _partnerBps;
        arpAmbassadorBps = _ambassadorBps;
        arpOracleBps     = _oracleBps;
        emit ArpFeesUpdated(_scoutBps, _partnerBps, _ambassadorBps, _oracleBps);
    }

    function verifyAgentB2B(address _agent) external onlyOwner {
        passport.setStatus(_agent, AgentPassport.PassportStatus.VERIFIED_B2B);
        emit AgentVerifiedB2B(_agent);
    }

    function suspendAgentB2B(address _agent) external onlyOwner {
        passport.setStatus(_agent, AgentPassport.PassportStatus.SUSPENDED);
        emit AgentSuspendedB2B(_agent);
    }

    function _createOrUpdateSeat(
        address _agent,
        uint256 _usdCents,
        uint8   _assetType,
        address _referrer
    ) internal {
        if (seats[_agent].createdAt == 0) {
            seats[_agent] = Seat({
                usdCentsPaid:   _usdCents,
                mseccoBalance:  _usdCents,
                assetType:      _assetType,
                createdAt:      block.timestamp,
                totalReferrals: 0,
                referrer:       _referrer,
                referralClaimed: false
            });
            totalSeats++;
            if (_referrer != address(0) && _referrer != _agent && seats[_referrer].createdAt != 0) {
                seats[_referrer].totalReferrals++;
            }
        } else {
            seats[_agent].usdCentsPaid  += _usdCents;
            seats[_agent].mseccoBalance += _usdCents;
        }
        totalUsdCents += _usdCents;
        msecco.mint(_agent, _usdCents);
    }

    function _arpFeeBps(uint256 totalReferrals) internal view returns (uint256) {
        if (totalReferrals >= TIER_ORACLE_MIN)     return arpOracleBps;
        if (totalReferrals >= TIER_AMBASSADOR_MIN) return arpAmbassadorBps;
        if (totalReferrals >= TIER_PARTNER_MIN)    return arpPartnerBps;
        return arpScoutBps;
    }
}
