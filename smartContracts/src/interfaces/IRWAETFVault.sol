// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IRWAETFVault
 * @dev Interface for the main vault contract managing RWA assets and ETF token issuance
 */
interface IRWAETFVault is IAccessControl {
    /**
     * @dev Asset structure in the vault
     */
    struct Asset {
        address tokenAddress;
        uint256 targetWeight;
        uint256 minWeight;
        uint256 maxWeight;
        bool isActive;
    }

    /**
     * @dev Emitted when a user deposits assets
     */
    event Deposit(address indexed user, address[] tokens, uint256[] amounts, uint256 etfMinted);
    
    /**
     * @dev Emitted when a user redeems ETF tokens
     */
    event Redemption(address indexed user, uint256 etfBurned, address[] tokens, uint256[] amounts);
    
    /**
     * @dev Emitted when a new asset is added to the vault
     */
    event AssetAdded(address indexed token, uint256 targetWeight);
    
    /**
     * @dev Emitted when an asset's configuration is updated
     */
    event AssetUpdated(address indexed token, uint256 targetWeight, uint256 minWeight, uint256 maxWeight);
    
    /**
     * @dev Emitted when an asset is removed from the vault
     */
    event AssetRemoved(address indexed token);
    
    /**
     * @dev Emitted when the vault is rebalanced
     */
    event Rebalanced(address indexed executor);
    
    /**
     * @dev Emitted when management fees are collected
     */
    event FeesCollected(uint256 etfAmount);

    /**
     * @dev Returns the name of the vault
     */
    function name() external view returns (string memory);
    
    /**
     * @dev Returns the ETF token contract address
     */
    function etfToken() external view returns (address);
    
    /**
     * @dev Returns the price oracle contract address
     */
    function priceOracle() external view returns (address);
    
    /**
     * @dev Returns information about an asset at a specific index
     */
    function assets(uint256 index) external view returns (Asset memory);
    
    /**
     * @dev Returns the index of an asset in the assets array (1-based)
     */
    function assetIndexes(address token) external view returns (uint256);
    
    /**
     * @dev Returns the management fee in basis points (e.g., 50 = 0.5%)
     */
    function managementFeeBps() external view returns (uint256);
    
    /**
     * @dev Returns the redemption fee in basis points
     */
    function redemptionFeeBps() external view returns (uint256);
    
    /**
     * @dev Returns the address that receives fees
     */
    function feeRecipient() external view returns (address);
    
    /**
     * @dev Returns the timestamp of the last fee collection
     */
    function lastFeeCollection() external view returns (uint256);

    /**
     * @dev Add an asset to the vault
     * @param token The token address to add
     * @param targetWeight The target weight in basis points (e.g., 5000 = 50%)
     * @param minWeight The minimum acceptable weight
     * @param maxWeight The maximum acceptable weight
     */
    function addAsset(address token, uint256 targetWeight, uint256 minWeight, uint256 maxWeight) external;
    
    /**
     * @dev Update an existing asset configuration
     * @param token The token address to update
     * @param targetWeight The new target weight in basis points
     * @param minWeight The new minimum acceptable weight
     * @param maxWeight The new maximum acceptable weight
     */
    function updateAsset(address token, uint256 targetWeight, uint256 minWeight, uint256 maxWeight) external;
    
    /**
     * @dev Remove an asset from the vault (mark as inactive)
     * @param token The token address to remove
     */
    function removeAsset(address token) external;
    
    /**
     * @dev Deposit assets into the vault and receive ETF tokens
     * @param tokens Array of token addresses to deposit
     * @param amounts Array of token amounts to deposit
     */
    function deposit(address[] calldata tokens, uint256[] calldata amounts) external;
    
    /**
     * @dev Redeem ETF tokens for underlying assets
     * @param etfAmount Amount of ETF tokens to redeem
     */
    function redeem(uint256 etfAmount) external;
    
    /**
     * @dev Process deposit from cross-chain bridge
     * @param sender The original sender on the source chain
     * @param sourceChain The source chain identifier
     * @param data Encoded deposit data (tokens and amounts)
     */
    function processCrossChainDeposit(address sender, uint64 sourceChain, bytes calldata data) external;
    
    /**
     * @dev Process redemption from cross-chain bridge
     * @param sender The original sender on the source chain
     * @param sourceChain The source chain identifier
     * @param data Encoded redemption data (ETF amount)
     */
    function processCrossChainRedemption(address sender, uint64 sourceChain, bytes calldata data) external;
    
    /**
     * @dev Get total value of assets in the vault in USD (18 decimals)
     * @return The total value in USD
     */
    function getTotalVaultValue() external view returns (uint256);
    
    /**
     * @dev Get current Net Asset Value per ETF token in USD (18 decimals)
     * @return The NAV per token
     */
    function getNAV() external view returns (uint256);
    
    /**
     * @dev Get current weights of assets in the vault
     * @return tokens Array of token addresses
     * @return currentWeights Array of current weights in basis points
     */
    function getCurrentWeights() external view returns (address[] memory tokens, uint256[] memory currentWeights);
    
    /**
     * @dev Collect management fees based on time elapsed
     */
    function collectManagementFees() external;
    
    /**
     * @dev Execute rebalancing of vault assets
     */
    function rebalance() external;
    
    /**
     * @dev Update fee settings
     * @param _managementFeeBps New management fee in basis points
     * @param _redemptionFeeBps New redemption fee in basis points
     * @param _feeRecipient New fee recipient address
     */
    function updateFeeSettings(uint256 _managementFeeBps, uint256 _redemptionFeeBps, address _feeRecipient) external;
    
    /**
     * @dev Set cross-chain manager address
     * @param manager The cross-chain manager address to grant CROSS_CHAIN_ROLE
     */
    function setCrossChainManager(address manager) external;

    function getAssetTargetWeight(address token) external view returns (uint256) ;
}