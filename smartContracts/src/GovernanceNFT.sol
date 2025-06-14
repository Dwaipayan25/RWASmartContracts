// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title GovernanceNFT
 * @dev NFT representing governance rights for a vault
 */
contract GovernanceNFT is ERC721Enumerable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    string private _baseTokenURI;
    uint256 private _tokenIdCounter;
    
    // Mapping from token ID to voting power
    mapping(uint256 => uint256) private _votingPower;
    
    // Events
    event VotingPowerSet(uint256 indexed tokenId, uint256 votingPower);
    
    constructor(
        string memory name, 
        string memory symbol,
        string memory baseTokenURI
    ) ERC721(name, symbol) {
        _baseTokenURI = baseTokenURI;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }
    
    /**
     * @dev Mint a new governance NFT with default voting power of 1
     */
    function mint(address to) external onlyRole(MINTER_ROLE) returns (uint256) {
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;
        
        _mint(to, tokenId);
        _votingPower[tokenId] = 1; // Default voting power
        
        return tokenId;
    }
    
    /**
     * @dev Mint a new governance NFT with specific voting power
     */
    function mintWithVotingPower(address to, uint256 power) external onlyRole(MINTER_ROLE) returns (uint256) {
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;
        
        _mint(to, tokenId);
        _votingPower[tokenId] = power;
        
        emit VotingPowerSet(tokenId, power);
        return tokenId;
    }
    
    /**
     * @dev Set voting power for a token (only admin)
     */
    function setVotingPower(uint256 tokenId, uint256 power) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _votingPower[tokenId] = power;
        emit VotingPowerSet(tokenId, power);
    }

    /**
     * @dev Get voting power of a token
     */
    function getVotingPower(uint256 tokenId) external view returns (uint256) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return _votingPower[tokenId];
    }
    
    /**
     * @dev Get total voting power of an address (sum of all NFTs)
     */
    function getAddressVotingPower(address owner) external view returns (uint256) {
        uint256 balance = balanceOf(owner);
        uint256 totalPower = 0;
        
        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(owner, i);
            totalPower += _votingPower[tokenId];
        }
        
        return totalPower;
    }
    
    /**
     * @dev Base URI for computing token URI
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    /**
     * @dev Update the base token URI
     */
    function setBaseURI(string memory baseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = baseURI;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     * Override to support both ERC721Enumerable and AccessControl interfaces
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable, AccessControl) returns (bool) {
        return ERC721Enumerable.supportsInterface(interfaceId) || 
            AccessControl.supportsInterface(interfaceId);
    }
}