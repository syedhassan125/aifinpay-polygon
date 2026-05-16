// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title AgentPassport — On-chain identity NFT for AI agents (Polygon)
/// @notice Each agent wallet gets one passport. Non-transferable after mint.
contract AgentPassport is ERC721, Ownable {

    uint8 public constant STATUS_BORN        = 0;
    uint8 public constant STATUS_ACTIVE      = 1;
    uint8 public constant STATUS_VERIFIED_B2B = 2;
    uint8 public constant STATUS_SUSPENDED   = 3;

    struct Passport {
        address ipCreator;    // wallet that gets 0.01% royalty on B2B payments
        bytes32 ipMetadata;   // IPFS CID or metadata hash
        uint8   status;
        uint64  dailyLimit;   // max mSECCO spend per day (in mSECCO units)
        uint64  currentSpent; // spent today
        uint64  lastResetDay; // unix day of last reset
        uint256 bornAt;       // block.timestamp at mint
    }

    address public aifinpayCore;
    uint256 private _tokenIdCounter;

    event CoreSet(address indexed core);

    // agent wallet → token ID
    mapping(address => uint256) public agentTokenId;
    // token ID → passport data
    mapping(uint256 => Passport) public passports;

    modifier onlyCore() {
        require(msg.sender == aifinpayCore, "Only AiFinPay core");
        _;
    }

    constructor(address initialOwner) ERC721("AiFinPay Agent Passport", "AIPASS") {
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

    /// @notice Mint a passport for an agent — one per wallet
    function mintPassport(
        address agent,
        address ipCreator,
        bytes32 ipMetadata,
        uint64  dailyLimit
    ) external onlyCore returns (uint256 tokenId) {
        require(agentTokenId[agent] == 0, "Passport already exists");

        _tokenIdCounter++;
        tokenId = _tokenIdCounter;

        // ── Checks-Effects-Interactions: write state BEFORE external _safeMint call ──
        agentTokenId[agent] = tokenId;
        passports[tokenId] = Passport({
            ipCreator:    ipCreator,
            ipMetadata:   ipMetadata,
            status:       STATUS_BORN,
            dailyLimit:   dailyLimit,
            currentSpent: 0,
            lastResetDay: uint64(block.timestamp / 1 days),
            bornAt:       block.timestamp
        });

        _safeMint(agent, tokenId);
    }

    /// @notice Update passport status — admin only via core
    function setStatus(address agent, uint8 status) external onlyCore {
        uint256 tokenId = agentTokenId[agent];
        require(tokenId != 0, "No passport");
        passports[tokenId].status = status;
    }

    /// @notice Check and update daily spend limit
    function checkAndSpend(address agent, uint64 amount) external onlyCore returns (bool) {
        uint256 tokenId = agentTokenId[agent];
        require(tokenId != 0, "No passport");
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
        require(tokenId != 0, "No passport");
        return passports[tokenId];
    }

    function hasPassport(address agent) external view returns (bool) {
        return agentTokenId[agent] != 0;
    }

    function isVerifiedB2B(address agent) external view returns (bool) {
        uint256 tokenId = agentTokenId[agent];
        if (tokenId == 0) return false;
        return passports[tokenId].status == STATUS_VERIFIED_B2B;
    }

    /// @notice Soulbound — non-transferable after mint
    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize) internal override {
        if (from != address(0) && to != address(0)) {
            revert("Agent Passport is soulbound");
        }
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }
}
