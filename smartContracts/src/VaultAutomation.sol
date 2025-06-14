// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink-contracts/automation/AutomationCompatible.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IRWAETFVault.sol";

/**
 * @title VaultAutomation
 * @dev Chainlink Automation compatible contract for vault maintenance
 */
contract VaultAutomation is AutomationCompatibleInterface, Ownable {
    // Vault configuration
    struct VaultConfig {
        address vaultAddress;
        uint256 checkInterval;
        uint256 lastCheckTime;
        uint256 rebalanceThresholdBps;
        bool isActive;
    }
    
    // Array of vault addresses to check
    address[] public vaultAddresses;
    
    // Mapping from vault address to config
    mapping(address => VaultConfig) public vaultConfigs;
    
    // Events
    event VaultAdded(address indexed vault, uint256 checkInterval, uint256 rebalanceThresholdBps);
    event VaultRemoved(address indexed vault);
    event VaultRebalanced(address indexed vault);
    event CheckPerformed(address indexed vault, bool rebalanced);
    
    constructor() Ownable(msg.sender){}
    
    /**
     * @dev Add a vault to be managed by the automation
     */
    function addVault(
        address vaultAddress,
        uint256 checkInterval,
        uint256 rebalanceThresholdBps
    ) external onlyOwner {
        require(vaultAddress != address(0), "Invalid vault address");
        require(!vaultConfigs[vaultAddress].isActive, "Vault already added");
        require(checkInterval > 0, "Check interval must be positive");
        require(rebalanceThresholdBps > 0 && rebalanceThresholdBps <= 10000, "Invalid threshold");
        
        vaultAddresses.push(vaultAddress);
        vaultConfigs[vaultAddress] = VaultConfig({
            vaultAddress: vaultAddress,
            checkInterval: checkInterval,
            lastCheckTime: block.timestamp,
            rebalanceThresholdBps: rebalanceThresholdBps,
            isActive: true
        });
        
        emit VaultAdded(vaultAddress, checkInterval, rebalanceThresholdBps);
    }
    
    /**
     * @dev Remove a vault from automation
     */
    function removeVault(address vaultAddress) external onlyOwner {
        require(vaultConfigs[vaultAddress].isActive, "Vault not active");
        
        vaultConfigs[vaultAddress].isActive = false;
        
        // Find and remove from array (maintain order)
        uint256 length = vaultAddresses.length;
        for (uint256 i = 0; i < length; i++) {
            if (vaultAddresses[i] == vaultAddress) {
                // Shift elements to remove
                for (uint256 j = i; j < length - 1; j++) {
                    vaultAddresses[j] = vaultAddresses[j + 1];
                }
                vaultAddresses.pop();
                break;
            }
        }
        
        emit VaultRemoved(vaultAddress);
    }
    
    /**
     * @dev Update vault configuration
     */
    function updateVaultConfig(
        address vaultAddress,
        uint256 checkInterval,
        uint256 rebalanceThresholdBps
    ) external onlyOwner {
        require(vaultConfigs[vaultAddress].isActive, "Vault not active");
        require(checkInterval > 0, "Check interval must be positive");
        require(rebalanceThresholdBps > 0 && rebalanceThresholdBps <= 10000, "Invalid threshold");
        
        vaultConfigs[vaultAddress].checkInterval = checkInterval;
        vaultConfigs[vaultAddress].rebalanceThresholdBps = rebalanceThresholdBps;
    }
    
    /**
     * @dev Manually trigger a check for all vaults
     */
    function checkAllVaults() external {
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            address vault = vaultAddresses[i];
            if (vaultConfigs[vault].isActive) {
                bool needsRebalance = checkIfRebalanceNeeded(vault);
                if (needsRebalance) {
                    try IRWAETFVault(vault).rebalance() {
                        vaultConfigs[vault].lastCheckTime = block.timestamp;
                        emit VaultRebalanced(vault);
                    } catch {
                        // If rebalance fails, we just emit the event but don't revert
                        emit CheckPerformed(vault, false);
                    }
                }
            }
        }
    }
    
    /**
     * @dev Chainlink Automation checkUpkeep function
     */
    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view override returns (bool upkeepNeeded, bytes memory performData) {
        address[] memory vaultsToRebalance = new address[](vaultAddresses.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            address vault = vaultAddresses[i];
            VaultConfig memory config = vaultConfigs[vault];
            
            if (config.isActive) {
                // Check if enough time has passed
                bool timeHasPassed = (block.timestamp - config.lastCheckTime) > config.checkInterval;
                
                if (timeHasPassed && checkIfRebalanceNeeded(vault)) {
                    vaultsToRebalance[count] = vault;
                    count++;
                }
            }
        }
        
        if (count > 0) {
            // Resize the array to include only vaults that need rebalancing
            assembly {
                mstore(vaultsToRebalance, count)
            }
            return (true, abi.encode(vaultsToRebalance));
        }
        
        return (false, "");
    }
    
    /**
     * @dev Check if a specific vault needs rebalancing
     */
    function checkIfRebalanceNeeded(address vault) public view returns (bool) {
        VaultConfig memory config = vaultConfigs[vault];
        if (!config.isActive) return false;
        
        try IRWAETFVault(vault).getCurrentWeights() returns (
            address[] memory tokens, 
            uint256[] memory currentWeights
        ) {
            // Get target weights for each token
            for (uint256 i = 0; i < tokens.length; i++) {
                uint256 targetWeight = IRWAETFVault(vault).getAssetTargetWeight(tokens[i]);
                uint256 currentWeight = currentWeights[i];
                
                // Check if deviation exceeds threshold
                if (targetWeight > currentWeight) {
                    if (targetWeight - currentWeight > config.rebalanceThresholdBps) {
                        return true;
                    }
                } else {
                    if (currentWeight - targetWeight > config.rebalanceThresholdBps) {
                        return true;
                    }
                }
            }
            
            return false;
        } catch {
            // If there's an error calling the vault, assume no rebalance needed
            return false;
        }
    }
    
    /**
     * @dev Chainlink Automation performUpkeep function
     */
    function performUpkeep(
        bytes calldata performData
    ) external override {
        address[] memory vaultsToRebalance = abi.decode(performData, (address[]));
        
        for (uint256 i = 0; i < vaultsToRebalance.length; i++) {
            address vault = vaultsToRebalance[i];
            
            if (vaultConfigs[vault].isActive) {
                try IRWAETFVault(vault).rebalance() {
                    // Update last check time
                    vaultConfigs[vault].lastCheckTime = block.timestamp;
                    emit VaultRebalanced(vault);
                } catch {
                    // If rebalance fails, we just emit the event but don't revert the whole transaction
                    emit CheckPerformed(vault, false);
                }
            }
        }
    }
}