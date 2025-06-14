// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./RWAETFVault.sol";
import "./ETFToken.sol";
import "./GovernanceNFT.sol";

/**
 * @title VaultFactory
 * @dev Factory contract to create new ETF vaults
 */
contract VaultFactory is Ownable {
    // Registry of created vaults
    address[] public vaults;
    mapping(address => bool) public isVault;
    
    // Registry of tokens
    mapping(address => address) public vaultToToken;
    mapping(address => address) public vaultToGovernance;
    
    // Price oracle used by vaults
    address public priceOracle;
    
    // Cross-chain manager
    address public crossChainManager;
    
    // Events
    event VaultCreated(
        address indexed vault, 
        address indexed etfToken, 
        address indexed governanceNFT, 
        string name
    );
    
    constructor(address _priceOracle) Ownable(msg.sender) {
        priceOracle = _priceOracle;
    }
    
    /**
     * @dev Set cross-chain manager address
     */
    function setCrossChainManager(address _crossChainManager) external onlyOwner {
        crossChainManager = _crossChainManager;
    }
    
    /**
     * @dev Update price oracle address
     */
    function setPriceOracle(address _priceOracle) external onlyOwner {
        require(_priceOracle != address(0), "Invalid oracle address");
        priceOracle = _priceOracle;
    }
    
    /**
     * @dev Create a new ETF vault with associated tokens
     */
    function createVault(
        string memory name,
        string memory symbol,
        address initialGovernor
    ) external returns (address vault) {
        require(priceOracle != address(0), "Price oracle not set");
        require(initialGovernor != address(0), "Invalid governor address");
        
        // Deploy ETF token
        ETFToken etfToken = new ETFToken(
            string(abi.encodePacked("AetherFund ", name, " Token")),
            symbol
        );
        
        // Deploy governance NFT
        GovernanceNFT governanceNFT = new GovernanceNFT(
            string(abi.encodePacked("AetherFund ", name, " Governance")),
            string(abi.encodePacked(symbol, "-GOV")),
            "https://aetherfund.io/api/metadata/"
        );
        
        // Create vault
        RWAETFVault newVault = new RWAETFVault(
            name,
            address(etfToken),
            priceOracle,
            address(governanceNFT)
        );
        
        // Setup permissions
        etfToken.addMinter(address(newVault));
        governanceNFT.grantRole(governanceNFT.MINTER_ROLE(), address(this));
        
        // Mint initial governance NFT to governor
        governanceNFT.mint(initialGovernor);
        
        // Set cross-chain manager if available
        if (crossChainManager != address(0)) {
            newVault.setCrossChainManager(crossChainManager);
        }
        
        // Transfer ownership of tokens to the governor
        etfToken.grantRole(etfToken.DEFAULT_ADMIN_ROLE(), initialGovernor);
        governanceNFT.grantRole(governanceNFT.DEFAULT_ADMIN_ROLE(), initialGovernor);
        
        // Revoke factory permissions
        etfToken.revokeRole(etfToken.DEFAULT_ADMIN_ROLE(), address(this));
        governanceNFT.revokeRole(governanceNFT.MINTER_ROLE(), address(this));
        governanceNFT.revokeRole(governanceNFT.DEFAULT_ADMIN_ROLE(), address(this));
        
        // Register vault
        vaults.push(address(newVault));
        isVault[address(newVault)] = true;
        vaultToToken[address(newVault)] = address(etfToken);
        vaultToGovernance[address(newVault)] = address(governanceNFT);
        
        emit VaultCreated(address(newVault), address(etfToken), address(governanceNFT), name);
        
        return address(newVault);
    }
    
    /**
     * @dev Get count of all vaults created
     */
    function getVaultCount() external view returns (uint256) {
        return vaults.length;
    }
    
    /**
     * @dev Get vault info by index
     */
    function getVaultInfo(uint256 index) external view returns (
        address vault,
        address etfToken,
        address governanceNFT
    ) {
        require(index < vaults.length, "Invalid index");
        vault = vaults[index];
        etfToken = vaultToToken[vault];
        governanceNFT = vaultToGovernance[vault];
    }
}