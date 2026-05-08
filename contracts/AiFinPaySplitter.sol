// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title AiFinPaySplitter — fee-on-top atomic 3-way split
/// @notice Standalone contract, deployed alongside AiFinPayCore. Used by
///         the autonomous x402 loop: AI agents pay arbitrary AI services
///         their full quoted price, and the AiFinPay fee + creator/referral
///         fee are added on top in the same transaction.
///
/// @dev    AiFinPayCore (the seat / mSECCO / passport contract) is already
///         deployed on Polygon mainnet and is NOT upgradeable. Adding the
///         splitter as its own contract avoids redeploying core and
///         migrating state. This contract owns nothing seat-related — it
///         is purely a payment splitter.
contract AiFinPaySplitter is Ownable, ReentrancyGuard {

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Recipient of the protocol fee. Should equal the canonical
    ///         AiFinPay treasury / Squads multisig.
    address public treasury;

    /// @notice Protocol fee in basis points (100 = 1.00%). Charged on top.
    uint256 public treasuryBps;

    /// @notice Creator/referral fee in basis points (1 = 0.01%). Charged
    ///         on top. If feeRecipient passed to b2bPayWithSplit is the
    ///         zero address, this slot routes to treasury.
    uint256 public ipCreatorBps;

    /// @notice Emergency pause flag (owner only).
    bool public isPaused;

    event B2BPaymentWithSplit(
        address indexed agent,
        address indexed merchant,
        uint256 merchantAmount,
        uint256 treasuryFee,
        uint256 ipCreatorFee,
        address feeRecipient,
        string  orderId
    );
    event TreasuryUpdated(address indexed treasury);
    event FeesUpdated(uint256 treasuryBps, uint256 ipCreatorBps);
    event Paused(bool status);

    modifier notPaused() {
        require(!isPaused, "Splitter is paused");
        _;
    }

    constructor(
        address initialOwner,
        address _treasury,
        uint256 _treasuryBps,
        uint256 _ipCreatorBps
    ) {
        require(_treasury != address(0), "Zero treasury");
        require(_treasuryBps + _ipCreatorBps < BPS_DENOMINATOR, "Fees exceed 100%");
        _transferOwnership(initialOwner);
        treasury     = _treasury;
        treasuryBps  = _treasuryBps;
        ipCreatorBps = _ipCreatorBps;
    }

    /// @notice Pay a merchant their full quoted price; AiFinPay fee +
    ///         creator/referral fee are added on top.
    /// @dev    `msg.value` MUST equal at least
    ///         `merchantAmount + treasuryFee + ipCreatorFee`. Excess is
    ///         refunded to the caller in the same tx.
    /// @param  merchant       Receives the full `merchantAmount`.
    /// @param  merchantAmount Merchant's quoted price (wei).
    /// @param  feeRecipient   Receives `ipCreatorFee`. Pass `address(0)`
    ///                        to route the creator slot to treasury.
    /// @param  orderId        Off-chain reference (max 64 chars recommended).
    function b2bPayWithSplit(
        address payable merchant,
        uint256 merchantAmount,
        address payable feeRecipient,
        string  calldata orderId
    ) external payable notPaused nonReentrant {
        require(merchant != address(0), "Zero merchant");
        require(merchant != msg.sender, "Self-pay not allowed");
        require(merchantAmount > 0,     "Zero merchant amount");

        uint256 treasuryFee  = (merchantAmount * treasuryBps)  / BPS_DENOMINATOR;
        uint256 ipCreatorFee = (merchantAmount * ipCreatorBps) / BPS_DENOMINATOR;
        require(treasuryFee > 0, "Protocol fee underflow");

        uint256 total = merchantAmount + treasuryFee + ipCreatorFee;
        require(msg.value >= total, "Insufficient payment");
        uint256 refund = msg.value - total;

        // Settlement order: merchant first (the value the merchant quoted),
        // then protocol fee, then creator/referral fee, then refund.
        (bool s1,) = merchant.call{value: merchantAmount}("");
        require(s1, "Merchant transfer failed");

        (bool s2,) = treasury.call{value: treasuryFee}("");
        require(s2, "Treasury transfer failed");

        address payable creatorTo = feeRecipient == address(0)
            ? payable(treasury)
            : feeRecipient;
        if (ipCreatorFee > 0) {
            (bool s3,) = creatorTo.call{value: ipCreatorFee}("");
            require(s3, "Creator fee transfer failed");
        }

        if (refund > 0) {
            (bool s4,) = payable(msg.sender).call{value: refund}("");
            require(s4, "Refund failed");
        }

        emit B2BPaymentWithSplit(
            msg.sender, merchant, merchantAmount,
            treasuryFee, ipCreatorFee, creatorTo, orderId
        );
    }

    /// @notice Pure-view helper. Returns the totals an agent must send.
    /// @return treasuryFee   AiFinPay protocol fee on top.
    /// @return ipCreatorFee  Creator/referral fee on top.
    /// @return total         merchantAmount + both fees — minimum msg.value.
    function quoteSplit(uint256 merchantAmount)
        external
        view
        returns (uint256 treasuryFee, uint256 ipCreatorFee, uint256 total)
    {
        treasuryFee  = (merchantAmount * treasuryBps)  / BPS_DENOMINATOR;
        ipCreatorFee = (merchantAmount * ipCreatorBps) / BPS_DENOMINATOR;
        total        = merchantAmount + treasuryFee + ipCreatorFee;
    }

    // ── Admin ───────────────────────────────────────────────────────────

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Zero treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setFees(uint256 _treasuryBps, uint256 _ipCreatorBps) external onlyOwner {
        require(_treasuryBps + _ipCreatorBps < BPS_DENOMINATOR, "Fees exceed 100%");
        treasuryBps  = _treasuryBps;
        ipCreatorBps = _ipCreatorBps;
        emit FeesUpdated(_treasuryBps, _ipCreatorBps);
    }

    function pause() external onlyOwner {
        isPaused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        isPaused = false;
        emit Paused(false);
    }
}
