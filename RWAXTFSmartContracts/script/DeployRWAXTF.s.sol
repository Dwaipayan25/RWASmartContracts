// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/RWAToken.sol";
import "../src/RWAVault.sol";
import "../src/CrossChainVaultManager.sol";
import "../src/VaultToken.sol";

contract DeployRWAXTF is Script {
    function run() public {
        // Get private key for deployment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Get chain specifics
        uint256 chainId;
        assembly { chainId := chainid() }
        
        console.log("Deploying to chain ID:", chainId);
        
        // Define CCIP configuration based on chain
        address ccipRouter;
        uint64 chainSelector;
        bool isVaultChain;
        
        if (chainId == 84532) { // Base Sepolia
            console.log("Deploying to Base Sepolia as vault chain");
            ccipRouter = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
            chainSelector = 10344971235874465080;
            isVaultChain = true;
        } else if (chainId == 11155111) { // Ethereum Sepolia
            console.log("Deploying to Ethereum Sepolia as supporting chain");
            ccipRouter = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
            chainSelector = 16015286601757825753;
            isVaultChain = false;
        } else {
            revert("Unsupported chain");
        }
        
        // 1. Deploy tokens
        RWAToken baseToken = new RWAToken("USD Coin", "USDC", 6);
        console.log("BaseToken (USDC) deployed at:", address(baseToken));
        
        RWAToken rwaToken1 = new RWAToken("Real Estate Token", "RET", 18);
        console.log("RWA Token 1 (RET) deployed at:", address(rwaToken1));
        
        RWAToken rwaToken2 = new RWAToken("Carbon Credit Token", "CCT", 8);
        console.log("RWA Token 2 (CCT) deployed at:", address(rwaToken2));
        
        // 2. Deploy RWAVault only on the vault chain
        RWAVault rwaVault;
        if (isVaultChain) {
            rwaVault = new RWAVault();
            console.log("RWA Vault deployed at:", address(rwaVault));
        }
        
        // 3. Deploy Cross Chain Manager
        SimplifiedCrossChainManager crossChainManager = new SimplifiedCrossChainManager(
            ccipRouter,
            isVaultChain ? address(rwaVault) : address(0),
            chainSelector,
            isVaultChain
        );
        console.log("Cross Chain Manager deployed at:", address(crossChainManager));
        
        // 4. Create a test vault if on vault chain
        if (isVaultChain) {
            // Setup mock price feeds
            // In production, these would be actual Chainlink price feeds
            console.log("Setting up mock price feeds for testing");
            address priceFeed1 = 0xb113F5A928BCfF189C998ab20d753a47F9dE5A61;
            address priceFeed2 = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
            
            // Setup vault parameters
            address[] memory rwaAssets = new address[](2);
            rwaAssets[0] = address(rwaToken1);
            rwaAssets[1] = address(rwaToken2);
            
            address[] memory priceFeeds = new address[](2);
            priceFeeds[0] = priceFeed1;
            priceFeeds[1] = priceFeed2;
            
            uint256[] memory percentages = new uint256[](2);
            percentages[0] = 6000; // 60%
            percentages[1] = 4000; // 40%
            
            // Create a sample vault
            uint256 vaultId = rwaVault.createVault(
                rwaAssets,
                priceFeeds,
                percentages,
                address(baseToken),
                6, // USDC decimals
                "Diversified RWA Portfolio",
                "DRWA"
            );
            console.log("Sample vault created with ID:", vaultId);
            
            // Pre-fund cross chain manager with RWA tokens
            rwaToken1.mint(address(crossChainManager), 1000000 * 10**18);
            rwaToken2.mint(address(crossChainManager), 1000000 * 10**8);
            console.log("Cross Chain Manager pre-funded with RWA tokens");
            
            // Register vault in cross chain manager
            crossChainManager.setVaultChain(vaultId, chainSelector);
            console.log("Vault registered with Cross Chain Manager");
        }
        
        vm.stopBroadcast();
        
        console.log("Deployment completed. Save these addresses for testing!");
    }
}