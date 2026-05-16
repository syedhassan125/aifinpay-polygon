// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./errors/Errors.sol";

/// @title mSECCO — AiFinPay Compute Credit Token (Polygon)
/// @notice 1 USD = 100 mSECCO. No withdraw — credits are locked in-protocol.
contract MSECCOToken is ERC20, Ownable {
    address public aifinpayCore;

    event CoreSet(address indexed core);

    modifier onlyCore() {
        if (msg.sender != aifinpayCore) revert OnlyCore();
        _;
    }

    constructor(address initialOwner) ERC20("mSECCO", "mSECCO") Ownable(initialOwner) {}

    /// @notice Set the AiFinPay core contract address — one-time only
    function setCore(address _core) external onlyOwner {
        if (aifinpayCore != address(0)) revert CoreAlreadySet();
        if (_core == address(0)) revert ZeroAddress();
        aifinpayCore = _core;
        emit CoreSet(_core);
    }

    /// @notice Mint mSECCO credits — only callable by AiFinPay core
    function mint(address _to, uint256 _amount) external onlyCore {
        _mint(_to, _amount);
    }

    /// @notice Burn mSECCO credits when spent — only callable by AiFinPay core
    function burn(address _from, uint256 _amount) external onlyCore {
        _burn(_from, _amount);
    }

    /// @notice Transfers are disabled — mSECCO is non-transferable, protocol-locked
    function transfer(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    /// @notice Block approvals — no point approving a non-transferable token
    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function decimals() public pure override returns (uint8) {
        return 2;
    }
}
