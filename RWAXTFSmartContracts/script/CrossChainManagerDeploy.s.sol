// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "src/CrossChainVaultManager.sol";
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simple mock ERC20 token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1000000 * 10**6); // 1M USDC
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract CrossChainManagerDeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory chainName = vm.envString("CHAIN_NAME");
        uint64 chainSelector = uint64(vm.envUint("CHAIN_SELECTOR"));
        address ccipRouter = vm.envAddress("CCIP_ROUTER");
        bool isVaultChain = vm.envBool("IS_VAULT_CHAIN");
        
        console.log("Deploying contracts to", chainName);
        console.log("Chain Selector:", chainSelector);
        console.log("CCIP Router:", ccipRouter);
        console.log("Is Vault Chain:", isVaultChain ? "Yes" : "No");
        console.log("Deployer address:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy USDC mock
        MockUSDC usdc = new MockUSDC();
        console.log("USDC Mock deployed at:", address(usdc));
        
        // Deploy a vault only if this is a vault chain
        address vaultAddress = address(0);
        if (isVaultChain) {
            // You would deploy your vault here
            // For now, just log that we'd deploy a vault
            console.log("This is a vault chain, but vault deployment is skipped for this simplified example");
            
            // If you need to deploy a real vault:
            // RWAVault vault = new RWAVault();
            // vaultAddress = address(vault);
        }
        
        // Deploy CrossChainManager with the correct parameters
        SimplifiedCrossChainManager crossChainManager = new SimplifiedCrossChainManager(
            ccipRouter,
            vaultAddress,   // Will be address(0) on non-vault chains
            chainSelector,
            isVaultChain
        );
        console.log("CrossChainManager deployed at:", address(crossChainManager));
        
        // Fund the contract with LINK for gas fees
        (bool success,) = address(crossChainManager).call{value: 0.2 ether}("");
        require(success, "Failed to send ETH");
        console.log("Funded contract with 0.2 ETH for CCIP fees");
        
        // Add USDC to allowlisted tokens
        crossChainManager.allowlistToken(address(usdc), true);
        console.log("Added USDC to allowlisted tokens");
        
        vm.stopBroadcast();
        
        // Save addresses to file for verification
        string memory filename = string(abi.encodePacked("./deployments/", chainName, ".txt"));
        string memory addresses = string(abi.encodePacked(
            "ChainName=", chainName, "\n",
            "ChainSelector=", vm.toString(chainSelector), "\n",
            "USDC=", vm.toString(address(usdc)), "\n",
            "CrossChainManager=", vm.toString(address(crossChainManager)), "\n",
            "CCIPRouter=", vm.toString(ccipRouter), "\n",
            "IsVaultChain=", isVaultChain ? "true" : "false", "\n",
            "VaultAddress=", vm.toString(vaultAddress), "\n"
        ));
        
        // Replace the file writing at the end of your run() function with:
    console.log("\n=== DEPLOYMENT SUMMARY ===");
    console.log("Chain Name:", chainName);
    console.log("Chain Selector:", chainSelector);
    console.log("USDC:", address(usdc));
    console.log("CrossChainManager:", address(crossChainManager));
    console.log("CCIP Router:", ccipRouter);
    console.log("Is Vault Chain:", isVaultChain ? "true" : "false");
    console.log("Vault Address:", vaultAddress);
    console.log("=========================\n");
    console.log(" Copy this information for future reference!");     
    }
}