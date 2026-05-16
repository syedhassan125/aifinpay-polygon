// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../errors/Errors.sol";

/// @title AgentPassport — On-chain identity NFT for AI agents (Polygon)
/// @notice Each agent wallet gets one passport. Non-transferable after mint.
contract AgentPassport is ERC721, Ownable {

    enum PassportStatus {
        BORN,
        ACTIVE,
        VERIFIED_B2B,
        SUSPENDED
    }

    struct Passport {
        address ipCreator;
        bytes32 ipMetadata;
        PassportStatus status;
        uint64  dailyLimit;
        uint64  currentSpent;
        uint64  lastResetDay;
        uint256 bornAt;
    }

    address public aifinpayCore;
    uint256 private _tokenIdCounter;

    event CoreSet(address indexed core);

    mapping(address => uint256) public agentTokenId;
    mapping(uint256 => Passport) public passports;

    modifier onlyCore() {
        if (msg.sender != aifinpayCore) revert OnlyCore();
        _;
    }

    constructor(address initialOwner) ERC721("AiFinPay Agent Passport", "AIPASS") Ownable(initialOwner) {}

    /// @notice Set the AiFinPay core contract address — one-time only
    function setCore(address _core) external onlyOwner {
        if (aifinpayCore != address(0)) revert CoreAlreadySet();
        if (_core == address(0)) revert ZeroAddress();
        aifinpayCore = _core;
        emit CoreSet(_core);
    }

    /// @notice Mint a passport for an agent — one per wallet
    function mintPassport(
        address agent,
        address ipCreator,
        bytes32 ipMetadata,
        uint64  dailyLimit
    ) external onlyCore returns (uint256 tokenId) {
        if (agentTokenId[agent] != 0) revert PassportAlreadyExists();

        _tokenIdCounter++;
        tokenId = _tokenIdCounter;

        agentTokenId[agent] = tokenId;
        passports[tokenId] = Passport({
            ipCreator:    ipCreator,
            ipMetadata:   ipMetadata,
            status:       PassportStatus.BORN,
            dailyLimit:   dailyLimit,
            currentSpent: 0,
            lastResetDay: uint64(block.timestamp / 1 days),
            bornAt:       block.timestamp
        });

        _safeMint(agent, tokenId);
    }

    /// @notice Update passport status — admin only via core
    function setStatus(address agent, PassportStatus status) external onlyCore {
        uint256 tokenId = agentTokenId[agent];
        if (tokenId == 0) revert NoPassport();
        passports[tokenId].status = status;
    }

    /// @notice Check and update daily spend limit
    function checkAndSpend(address agent, uint64 amount) external onlyCore returns (bool) {
        uint256 tokenId = agentTokenId[agent];
        if (tokenId == 0) revert NoPassport();
        Passport storage p = passports[tokenId];

        uint64 today = uint64(block.timestamp / 1 days);
        if (today > p.lastResetDay) {
            p.currentSpent = 0;
            p.lastResetDay = today;
        }

        if (p.currentSpent + amount > p.dailyLimit) return false;
        p.currentSpent += amount;
        return true;
    }

    function getPassport(address agent) external view returns (Passport memory) {
        uint256 tokenId = agentTokenId[agent];
        if (tokenId == 0) revert NoPassport();
        return passports[tokenId];
    }

    function hasPassport(address agent) external view returns (bool) {
        return agentTokenId[agent] != 0;
    }

    function isVerifiedB2B(address agent) external view returns (bool) {
        uint256 tokenId = agentTokenId[agent];
        if (tokenId == 0) return false;
        return passports[tokenId].status == PassportStatus.VERIFIED_B2B;
    }

    /// @notice Soulbound — non-transferable after mint
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert Soulbound();
        }
        return super._update(to, tokenId, auth);
    }
}
