// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/RWAVault.sol";
import "../src/RWAToken.sol";
import "../src/VaultToken.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying contracts to Base Sepolia...");
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy RWAVault (main contract)
        RWAVault vault = new RWAVault();
        console.log("RWAVault deployed at:", address(vault));
        
        // Deploy sample RWA tokens for testing
        RWAToken rwa1 = new RWAToken("Real Estate Token", "RET", 18);
        RWAToken rwa2 = new RWAToken("Gold Token", "GOLD", 8);
        RWAToken rwa3 = new RWAToken("Treasury Bond Token", "TBT", 6);
        
        console.log("RWA Token 1 (RET) deployed at:", address(rwa1));
        console.log("RWA Token 2 (GOLD) deployed at:", address(rwa2));
        console.log("RWA Token 3 (TBT) deployed at:", address(rwa3));
        
        // Note: VaultToken is deployed automatically by RWAVault.createVault()
        
        vm.stopBroadcast();
        
        // Log deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base Sepolia");
        console.log("RWAVault:", address(vault));
        console.log("RET Token:", address(rwa1));
        console.log("GOLD Token:", address(rwa2));
        console.log("TBT Token:", address(rwa3));
        console.log("==========================");
        
        // Save addresses to file for verification
        string memory addresses = string(abi.encodePacked(
            "RWAVault=", vm.toString(address(vault)), "\n",
            "RWAToken1=", vm.toString(address(rwa1)), "\n",
            "RWAToken2=", vm.toString(address(rwa2)), "\n",
            "RWAToken3=", vm.toString(address(rwa3)), "\n"
        ));
    }
}