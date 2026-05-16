// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title mSECCO — AiFinPay Compute Credit Token (Polygon)
/// @notice 1 USD = 100 mSECCO. No withdraw — credits are locked in-protocol.
contract MSECCOToken is ERC20, Ownable {

    address public aifinpayCore;

    event CoreSet(address indexed core);

    modifier onlyCore() {
        require(msg.sender == aifinpayCore, "Only AiFinPay core");
        _;
    }

    constructor(address initialOwner) ERC20("mSECCO", "mSECCO") {
        require(initialOwner != address(0), "Zero owner");
        _transferOwnership(initialOwner);
    }

    /// @notice Set the AiFinPay core contract address — one-time only
    function setCore(address _core) external onlyOwner {
        require(aifinpayCore == address(0), "Core already set");
        require(_core != address(0), "Zero address");
        aifinpayCore = _core;
        emit CoreSet(_core);
    }

    /// @notice Mint mSECCO credits — only callable by AiFinPay core
    function mint(address to, uint256 amount) external onlyCore {
        _mint(to, amount);
    }

    /// @notice Burn mSECCO credits when spent — only callable by AiFinPay core
    function burn(address from, uint256 amount) external onlyCore {
        _burn(from, amount);
    }

    /// @notice Transfers are disabled — mSECCO is non-transferable, protocol-locked
    function transfer(address, uint256) public pure override returns (bool) {
        revert("mSECCO is non-transferable");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("mSECCO is non-transferable");
    }

    /// @notice EVM-INFO-002: block approvals — no point approving a non-transferable token
    function approve(address, uint256) public pure override returns (bool) {
        revert("mSECCO is non-transferable");
    }

    function decimals() public pure override returns (uint8) {
        return 2; // 1.00 mSECCO = 100 units (matches Solana: 1 USD = 100 mSECCO)
    }
}
