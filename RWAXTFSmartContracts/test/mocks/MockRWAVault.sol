// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockRWAVault {
    struct VaultDetails {
        address vaultToken;
        address[] rwaAssets;
        uint256[] percentages;
        address baseCurrency;
        uint256 baseCurrencyDecimals;
    }
    
    mapping(uint256 => VaultDetails) public vaults;
    mapping(uint256 => mapping(address => uint256)) public balances;
    uint256 public vaultCount;
    
    event Deposited(uint256 vaultId, address user, uint256 baseAmount, uint256 shares);
    event Redeemed(uint256 vaultId, address user, uint256 shares, uint256[] amounts);

    function createMockVault(
        uint256 vaultId,
        address vaultToken,
        address[] memory rwaAssets,
        uint256[] memory percentages,
        address baseCurrency,
        uint256 baseCurrencyDecimals
    ) external {
        vaults[vaultId] = VaultDetails({
            vaultToken: vaultToken,
            rwaAssets: rwaAssets,
            percentages: percentages,
            baseCurrency: baseCurrency,
            baseCurrencyDecimals: baseCurrencyDecimals
        });
        vaultCount = vaultId + 1;
    }

    function getVaultDetails(uint256 vaultId) external view returns (
        address vaultToken,
        address[] memory rwaAssets,
        uint256[] memory percentages,
        address baseCurrency,
        uint256 baseCurrencyDecimals
    ) {
        VaultDetails storage vault = vaults[vaultId];
        return (
            vault.vaultToken,
            vault.rwaAssets,
            vault.percentages,
            vault.baseCurrency,
            vault.baseCurrencyDecimals
        );
    }

    function calculateRequiredRWAs(
        uint256 vaultId,
        uint256 baseAmount
    ) external view returns (address[] memory, uint256[] memory) {
        VaultDetails storage vault = vaults[vaultId];
        uint256[] memory amounts = new uint256[](vault.rwaAssets.length);
        
        for (uint i = 0; i < vault.rwaAssets.length; i++) {
            // Simple calculation: 1:1 ratio for testing
            amounts[i] = (baseAmount * vault.percentages[i]) / 10000;
        }
        
        return (vault.rwaAssets, amounts);
    }

    function deposit(uint256 vaultId, uint256 baseAmount) external {
        VaultDetails storage vault = vaults[vaultId];
        
        // Transfer vault tokens to caller (simulate minting)
        MockVaultToken(vault.vaultToken).mint(msg.sender, baseAmount);
        
        emit Deposited(vaultId, msg.sender, baseAmount, baseAmount);
    }

    function redeem(uint256 vaultId, uint256 shares) external {
        VaultDetails storage vault = vaults[vaultId];
        
        // Burn vault tokens
        MockVaultToken(vault.vaultToken).burn(msg.sender, shares);
        
        // Return base currency
        IERC20(vault.baseCurrency).transfer(msg.sender, shares);
        
        uint256[] memory amounts = new uint256[](vault.rwaAssets.length + 1);
        amounts[0] = shares; // Base currency amount
        
        emit Redeemed(vaultId, msg.sender, shares, amounts);
    }
}

contract MockVaultToken is ERC20 {
    address public vault;
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        vault = msg.sender;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}