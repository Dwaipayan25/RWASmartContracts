// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PriceOracle
 * @dev Oracle for RWA asset prices using Chainlink feeds
 */
contract PriceOracle is Ownable {
    // Asset price feed configuration
    struct AssetConfig {
        address priceFeed;      // Chainlink price feed address
        uint8 decimals;         // Number of decimals in the price feed
        uint8 tokenDecimals;    // Number of decimals in the token
        bool isActive;
    }
    
    mapping(address => AssetConfig) public assetConfigs;
    
    // Events
    event AssetConfigUpdated(
        address indexed asset, 
        address priceFeed, 
        uint8 decimals, 
        uint8 tokenDecimals
    );
    event AssetConfigDeactivated(address indexed asset);
    
    constructor() Ownable(msg.sender) {}
    
    /**
     * @dev Configure a price feed for an asset
     */
    function setAssetPriceFeed(
        address asset,
        address priceFeed, 
        uint8 tokenDecimals
    ) external onlyOwner {
        require(asset != address(0), "Invalid asset address");
        require(priceFeed != address(0), "Invalid price feed address");
        
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);
        uint8 decimals = feed.decimals();
        
        assetConfigs[asset] = AssetConfig({
            priceFeed: priceFeed,
            decimals: decimals,
            tokenDecimals: tokenDecimals,
            isActive: true
        });
        
        emit AssetConfigUpdated(asset, priceFeed, decimals, tokenDecimals);
    }
    
    /**
     * @dev Deactivate a price feed
     */
    function deactivateAssetPriceFeed(address asset) external onlyOwner {
        require(assetConfigs[asset].isActive, "Asset not active");
        assetConfigs[asset].isActive = false;
        emit AssetConfigDeactivated(asset);
    }
    
    /**
     * @dev Get latest price for an asset in USD (18 decimals)
     */
    function getAssetPrice(address asset) public view returns (uint256) {
        AssetConfig memory config = assetConfigs[asset];
        require(config.isActive, "Price feed not configured or not active");
        
        AggregatorV3Interface priceFeed = AggregatorV3Interface(config.priceFeed);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        
        // Convert to 18 decimals
        return uint256(price) * 10**(18 - config.decimals);
    }
    
    /**
     * @dev Calculate value of a token amount in USD (18 decimals)
     */
    function getAssetValueInUSD(address asset, uint256 amount) public view returns (uint256) {
        AssetConfig memory config = assetConfigs[asset];
        require(config.isActive, "Price feed not configured or not active");
        
        uint256 price = getAssetPrice(asset);
        
        // Scale amount to 18 decimals and multiply by price
        return (amount * price) / 10**config.tokenDecimals;
    }
    
    /**
     * @dev Check if an asset has a configured price feed
     */
    function hasActivePriceFeed(address asset) external view returns (bool) {
        return assetConfigs[asset].isActive;
    }
}