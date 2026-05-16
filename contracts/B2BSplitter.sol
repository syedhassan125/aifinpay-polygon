// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./errors/Errors.sol";

/// @title B2BSplitter v1.1 — AiFinPay Standalone Payment Splitter
/// @notice Splits incoming MATIC or ERC-20 payments between merchant, treasury,
///         and IP creator. Owned by Gnosis Safe multisig.
/// @dev Owner = Gnosis Safe (4-of-4). No upgradeability — redeploy to change logic.
contract B2BSplitter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_PAYMENT = 100_000;

    address public constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address public constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    uint256 public treasuryBps = 100;
    uint256 public ipCreatorBps = 1;
    address public treasury;

    event Payment(
        address indexed payer,
        address indexed merchant,
        address indexed token,
        uint256 totalAmount,
        uint256 merchantAmount,
        uint256 treasuryAmount,
        uint256 ipCreatorAmount,
        string  orderId
    );
    event SplitUpdated(uint256 treasuryBps, uint256 ipCreatorBps);
    event TreasuryUpdated(address newTreasury);

    constructor(address initialOwner, address _treasury) Ownable(initialOwner) {
        if (_treasury == address(0)) revert ZeroTreasury();
        treasury = _treasury;
    }

    /// @notice Pay a merchant in MATIC. Automatically splits on-chain.
    /// @param merchant    Merchant wallet address
    /// @param ipCreator   IP creator address (receives royalty). Pass address(0) to skip.
    /// @param orderId     Off-chain order reference
    function payMatic(
        address payable merchant,
        address         ipCreator,
        string calldata orderId
    ) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroMatic();
        if (merchant == address(0)) revert ZeroMerchant();

        (uint256 merchantAmt, uint256 treasuryAmt, uint256 ipAmt) = _split(msg.value);

        (bool s1,) = merchant.call{value: merchantAmt}("");
        if (!s1) revert MerchantTransferFailed();

        (bool s2,) = payable(treasury).call{value: treasuryAmt}("");
        if (!s2) revert TreasuryTransferFailed();

        if (ipAmt > 0 && ipCreator != address(0)) {
            (bool s3,) = payable(ipCreator).call{value: ipAmt}("");
            if (!s3) revert IPCreatorTransferFailed();
        }

        emit Payment(msg.sender, merchant, address(0), msg.value, merchantAmt, treasuryAmt, ipAmt, orderId);
    }

    /// @notice Pay a merchant in USDC or USDT. Automatically splits on-chain.
    /// @dev Caller must approve this contract for `amount` before calling.
    function payStable(
        address         token,
        uint256         amount,
        address         merchant,
        address         ipCreator,
        string calldata orderId
    ) external nonReentrant whenNotPaused {
        if (token != USDC && token != USDT) revert UnsupportedToken();
        if (amount == 0) revert ZeroAmount();
        if (merchant == address(0)) revert ZeroMerchant();

        (uint256 merchantAmt, uint256 treasuryAmt, uint256 ipAmt) = _split(amount);

        IERC20(token).safeTransferFrom(msg.sender, merchant, merchantAmt);
        IERC20(token).safeTransferFrom(msg.sender, treasury, treasuryAmt);

        if (ipAmt > 0 && ipCreator != address(0)) {
            IERC20(token).safeTransferFrom(msg.sender, ipCreator, ipAmt);
        }

        emit Payment(msg.sender, merchant, token, amount, merchantAmt, treasuryAmt, ipAmt, orderId);
    }

    /// @notice Emergency pause — halts all payments instantly
    function pause() external onlyOwner { _pause(); }

    /// @notice Resume payments after an emergency pause
    function unpause() external onlyOwner { _unpause(); }

    function setSplit(uint256 _treasuryBps, uint256 _ipCreatorBps) external onlyOwner {
        if (_treasuryBps + _ipCreatorBps >= BPS_DENOMINATOR) revert FeesExceed100();
        if (_treasuryBps < 1) revert TreasuryFeeTooLow();
        treasuryBps  = _treasuryBps;
        ipCreatorBps = _ipCreatorBps;
        emit SplitUpdated(_treasuryBps, _ipCreatorBps);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroTreasury();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function _split(uint256 total) internal view returns (
        uint256 merchantAmt,
        uint256 treasuryAmt,
        uint256 ipAmt
    ) {
        if (total < MIN_PAYMENT) revert PaymentBelowMinimum();

        treasuryAmt = (total * treasuryBps) / BPS_DENOMINATOR;
        ipAmt = (total * ipCreatorBps) / BPS_DENOMINATOR;

        if (treasuryBps > 0 && treasuryAmt == 0) revert PaymentTooSmallForTreasury();
        if (ipCreatorBps > 0 && ipAmt == 0) revert PaymentTooSmallForRoyalty();

        merchantAmt = total - treasuryAmt - ipAmt;
        if (merchantAmt == 0) revert PaymentTooSmallForMerchant();
    }
}
