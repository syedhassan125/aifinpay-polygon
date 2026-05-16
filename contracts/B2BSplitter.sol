// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/// @title B2BSplitter v1.1 — AiFinPay Standalone Payment Splitter
/// @notice Splits incoming MATIC or ERC-20 payments between merchant, treasury,
///         and IP creator. Owned by Gnosis Safe multisig.
/// @dev Owner = Gnosis Safe (4-of-4). No upgradeability — redeploy to change logic.
contract B2BSplitter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20; // EVM-HIGH-001: SafeERC20 for all token transfers

    // ── Constants ──────────────────────────────────────────────────────────────
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_PAYMENT = 100_000; // Min 100k wei → at bps=1, fee ≥ 10 wei

    // ── Stablecoins (Polygon mainnet) ──────────────────────────────────────────
    address public constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address public constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    // ── Split Config ───────────────────────────────────────────────────────────
    /// @notice Protocol fee (to treasury). Default: 100 bps = 1%
    uint256 public treasuryBps = 100;
    /// @notice IP creator royalty. Default: 1 bps = 0.01%
    uint256 public ipCreatorBps = 1;
    /// @notice Treasury wallet address
    address public treasury;

    // ── Events ─────────────────────────────────────────────────────────────────
    event Payment(
        address indexed payer,
        address indexed merchant,
        address indexed token,   // address(0) = MATIC
        uint256 totalAmount,
        uint256 merchantAmount,
        uint256 treasuryAmount,
        uint256 ipCreatorAmount,
        string  orderId
    );
    event SplitUpdated(uint256 treasuryBps, uint256 ipCreatorBps);
    event TreasuryUpdated(address newTreasury);

    // ── Constructor ────────────────────────────────────────────────────────────
    constructor(address initialOwner, address _treasury) {
        require(initialOwner != address(0), "Zero owner");
        require(_treasury != address(0), "Zero treasury");
        _transferOwnership(initialOwner);
        treasury = _treasury;
    }

    // ── MATIC Split ────────────────────────────────────────────────────────────
    /// @notice Pay a merchant in MATIC. Automatically splits on-chain.
    /// @param merchant    Merchant wallet address
    /// @param ipCreator   IP creator address (receives royalty). Pass address(0) to skip.
    /// @param orderId     Off-chain order reference
    function payMatic(
        address payable merchant,
        address         ipCreator,
        string calldata orderId
    ) external payable nonReentrant whenNotPaused {
        require(msg.value > 0,            "Must send MATIC");
        require(merchant != address(0),   "Zero merchant");

        (uint256 merchantAmt, uint256 treasuryAmt, uint256 ipAmt) = _split(msg.value);

        (bool s1,) = merchant.call{value: merchantAmt}("");
        require(s1, "Merchant transfer failed");

        (bool s2,) = payable(treasury).call{value: treasuryAmt}("");
        require(s2, "Treasury transfer failed");

        if (ipAmt > 0 && ipCreator != address(0)) {
            (bool s3,) = payable(ipCreator).call{value: ipAmt}("");
            require(s3, "IP creator transfer failed");
        }

        emit Payment(msg.sender, merchant, address(0), msg.value, merchantAmt, treasuryAmt, ipAmt, orderId);
    }

    // ── Stablecoin Split ───────────────────────────────────────────────────────
    /// @notice Pay a merchant in USDC or USDT. Automatically splits on-chain.
    /// @dev Caller must approve this contract for `amount` before calling.
    function payStable(
        address         token,
        uint256         amount,
        address         merchant,
        address         ipCreator,
        string calldata orderId
    ) external nonReentrant whenNotPaused {
        require(token == USDC || token == USDT, "Unsupported token");
        require(amount > 0,                     "Zero amount");
        require(merchant != address(0),         "Zero merchant");

        (uint256 merchantAmt, uint256 treasuryAmt, uint256 ipAmt) = _split(amount);

        // EVM-HIGH-001: SafeERC20 — reverts on failed transfers (no silent failure)
        IERC20(token).safeTransferFrom(msg.sender, merchant, merchantAmt);
        IERC20(token).safeTransferFrom(msg.sender, treasury, treasuryAmt);

        if (ipAmt > 0 && ipCreator != address(0)) {
            IERC20(token).safeTransferFrom(msg.sender, ipCreator, ipAmt);
        }

        emit Payment(msg.sender, merchant, token, amount, merchantAmt, treasuryAmt, ipAmt, orderId);
    }

    // ── Admin (onlyOwner = Gnosis Safe multisig) ───────────────────────────────

    /// @notice EVM-MED-004: emergency pause — halts all payments instantly
    function pause() external onlyOwner { _pause(); }

    /// @notice Resume payments after an emergency pause
    function unpause() external onlyOwner { _unpause(); }

    function setSplit(uint256 _treasuryBps, uint256 _ipCreatorBps) external onlyOwner {
        require(_treasuryBps + _ipCreatorBps < BPS_DENOMINATOR, "Fees exceed 100%");
        // EVM-MED-003 mirror: prevent zero treasury fee breaking payment invariant
        require(_treasuryBps >= 1, "Treasury fee must be at least 0.01%");
        treasuryBps  = _treasuryBps;
        ipCreatorBps = _ipCreatorBps;
        emit SplitUpdated(_treasuryBps, _ipCreatorBps);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Zero address");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    // ── Internal ───────────────────────────────────────────────────────────────
    function _split(uint256 total) internal view returns (
        uint256 merchantAmt,
        uint256 treasuryAmt,
        uint256 ipAmt
    ) {
        require(total > MIN_PAYMENT, "MIN_PAYMENT not met");

        treasuryAmt = (total * treasuryBps) / BPS_DENOMINATOR;
        ipAmt = (total * ipCreatorBps) / BPS_DENOMINATOR;

        if (treasuryBps > 0) {
            require(treasuryAmt > 0, "Payment too small for treasury fee");
        }

        if (ipCreatorBps > 0) {
            require(ipAmt > 0, "Payment too small for royalty");
        }

        merchantAmt = total - treasuryAmt - ipAmt;
        require(merchantAmt > 0, "Payment too small for merchant");
    }
}
