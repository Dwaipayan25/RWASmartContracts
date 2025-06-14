// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IETFToken.sol";
import "./PriceOracle.sol";

/**
 * @title RWAETFVault
 * @dev Main vault contract for managing RWA assets and ETF token issuance
 */
contract RWAETFVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant CROSS_CHAIN_ROLE = keccak256("CROSS_CHAIN_ROLE");
    
    // Configuration
    string public name;
    IETFToken public etfToken;
    PriceOracle public priceOracle;
    
    // Asset tracking
    struct Asset {
        address tokenAddress;
        uint256 targetWeight; // in basis points (e.g. 5000 = 50%)
        uint256 minWeight;    // in basis points
        uint256 maxWeight;    // in basis points
        bool isActive;
    }
    
    Asset[] public assets;
    mapping(address => uint256) public assetIndexes; // 1-based index
    
    // Fee settings
    uint256 public managementFeeBps = 50; // 0.5% annual
    uint256 public redemptionFeeBps = 25;  // 0.25%
    address public feeRecipient;
    uint256 public lastFeeCollection;
    
    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    
    // Events
    event Deposit(address indexed user, address[] tokens, uint256[] amounts, uint256 etfMinted);
    event Redemption(address indexed user, uint256 etfBurned, address[] tokens, uint256[] amounts);
    event AssetAdded(address indexed token, uint256 targetWeight);
    event AssetUpdated(address indexed token, uint256 targetWeight, uint256 minWeight, uint256 maxWeight);
    event AssetRemoved(address indexed token);
    event Rebalanced(address indexed executor);
    event FeesCollected(uint256 etfAmount);
    
    /**
     * @dev Constructor
     */
    constructor(
        string memory _name,
        address _etfToken,
        address _priceOracle,
        address _governance
    ) {
        name = _name;
        etfToken = IETFToken(_etfToken);
        priceOracle = PriceOracle(_priceOracle);
        feeRecipient = _governance;
        lastFeeCollection = block.timestamp;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(REBALANCER_ROLE, _governance);
    }
    
    /**
     * @dev Add an asset to the vault
     */
    function addAsset(
        address token, 
        uint256 targetWeight, 
        uint256 minWeight, 
        uint256 maxWeight
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(0), "Invalid token address");
        require(assetIndexes[token] == 0, "Asset already exists");
        require(targetWeight > 0 && targetWeight <= BASIS_POINTS, "Invalid target weight");
        require(minWeight <= targetWeight && targetWeight <= maxWeight, "Invalid weight range");
        require(priceOracle.hasActivePriceFeed(token), "No price feed for token");
        
        // Calculate total weight to ensure we don't exceed 100%
        uint256 totalWeight = targetWeight;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].isActive) {
                totalWeight += assets[i].targetWeight;
            }
        }
        require(totalWeight <= BASIS_POINTS, "Total weight exceeds 100%");
        
        // Add the asset
        assets.push(Asset({
            tokenAddress: token,
            targetWeight: targetWeight,
            minWeight: minWeight,
            maxWeight: maxWeight,
            isActive: true
        }));
        
        // Store the index (1-based to distinguish from non-existent assets)
        assetIndexes[token] = assets.length;
        
        emit AssetAdded(token, targetWeight);
    }
    
    /**
     * @dev Update an existing asset configuration
     */
    function updateAsset(
        address token,
        uint256 targetWeight,
        uint256 minWeight,
        uint256 maxWeight
    ) external onlyRole(GOVERNANCE_ROLE) {
        uint256 index = assetIndexes[token];
        require(index > 0, "Asset not found");
        index -= 1; // Convert to 0-based index
        
        require(assets[index].isActive, "Asset not active");
        require(targetWeight > 0 && targetWeight <= BASIS_POINTS, "Invalid target weight");
        require(minWeight <= targetWeight && targetWeight <= maxWeight, "Invalid weight range");
        
        // Calculate total weight to ensure we don't exceed 100%
        uint256 totalWeight = targetWeight;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].isActive && i != index) {
                totalWeight += assets[i].targetWeight;
            }
        }
        require(totalWeight <= BASIS_POINTS, "Total weight exceeds 100%");
        
        // Update the asset
        assets[index].targetWeight = targetWeight;
        assets[index].minWeight = minWeight;
        assets[index].maxWeight = maxWeight;
        
        emit AssetUpdated(token, targetWeight, minWeight, maxWeight);
    }
    
    /**
     * @dev Remove an asset from the vault (set inactive)
     */
    function removeAsset(address token) external onlyRole(GOVERNANCE_ROLE) {
        uint256 index = assetIndexes[token];
        require(index > 0, "Asset not found");
        index -= 1; // Convert to 0-based index
        
        require(assets[index].isActive, "Asset already inactive");
        
        // We don't physically remove the asset, just mark it inactive
        assets[index].isActive = false;
        
        emit AssetRemoved(token);
    }
    
    /**
     * @dev Deposit assets into the vault and receive ETF tokens
     */
    function deposit(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(tokens.length == amounts.length, "Arrays length mismatch");
        require(tokens.length > 0, "No tokens specified");
        
        uint256 depositValue = 0;
        
        // Transfer tokens to the vault and calculate total value
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 assetIndex = assetIndexes[tokens[i]];
            require(assetIndex > 0, "Invalid token");
            assetIndex -= 1; // Convert to 0-based index
            
            require(assets[assetIndex].isActive, "Asset not active");
            require(amounts[i] > 0, "Amount must be greater than 0");
            
            // Transfer tokens
            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            
            // Calculate value in USD using price oracle
            uint256 tokenValue = priceOracle.getAssetValueInUSD(tokens[i], amounts[i]);
            depositValue += tokenValue;
        }
        
        require(depositValue > 0, "Deposit value must be greater than 0");
        
        // Collect management fees before minting new tokens
        collectManagementFees();
        
        // Calculate ETF tokens to mint based on NAV
        uint256 etfToMint = calculateETFAmount(depositValue);
        require(etfToMint > 0, "ETF amount too small");
        
        // Mint ETF tokens to the user
        etfToken.mint(msg.sender, etfToMint);
        
        emit Deposit(msg.sender, tokens, amounts, etfToMint);
    }
    
    /**
     * @dev Redeem ETF tokens for underlying assets
     */
    function redeem(uint256 etfAmount) external nonReentrant {
        require(etfAmount > 0, "Amount must be greater than 0");
        require(etfToken.balanceOf(msg.sender) >= etfAmount, "Insufficient ETF balance");
        
        // Collect management fees before redemption
        collectManagementFees();
        
        // Calculate proportion of vault to redeem
        uint256 totalETFSupply = etfToken.totalSupply();
        
        // Apply redemption fee
        uint256 feeAmount = (etfAmount * redemptionFeeBps) / BASIS_POINTS;
        uint256 etfAmountAfterFee = etfAmount - feeAmount;
        
        // Send fee to fee recipient
        if (feeAmount > 0) {
            etfToken.transferFrom(msg.sender, feeRecipient, feeAmount);
        }
        
        // Burn remaining ETF tokens
        etfToken.burn(msg.sender, etfAmountAfterFee);
        
        uint256 redeemRatio = (etfAmountAfterFee * 1e18) / totalETFSupply;
        
        // Prepare arrays for event
        address[] memory tokens = new address[](assets.length);
        uint256[] memory amounts = new uint256[](assets.length);
        
        // Transfer proportional assets to user
        uint256 activeAssetCount = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].isActive) {
                address tokenAddr = assets[i].tokenAddress;
                uint256 vaultBalance = IERC20(tokenAddr).balanceOf(address(this));
                uint256 userAmount = (vaultBalance * redeemRatio) / 1e18;
                
                if (userAmount > 0) {
                    IERC20(tokenAddr).safeTransfer(msg.sender, userAmount);
                    tokens[activeAssetCount] = tokenAddr;
                    amounts[activeAssetCount] = userAmount;
                    activeAssetCount++;
                }
            }
        }
        
        // Resize arrays for emitting event
        assembly {
            mstore(tokens, activeAssetCount)
            mstore(amounts, activeAssetCount)
        }
        
        emit Redemption(msg.sender, etfAmount, tokens, amounts);
    }
    
    /**
     * @dev Process deposit from cross-chain bridge
     */
    function processCrossChainDeposit(
        address sender,
        uint64 sourceChain,
        bytes calldata data
    ) external onlyRole(CROSS_CHAIN_ROLE) nonReentrant {
        // Decode the cross-chain deposit data
        (address[] memory tokens, uint256[] memory amounts) = abi.decode(data, (address[], uint256[]));
        
        require(tokens.length == amounts.length, "Arrays length mismatch");
        require(tokens.length > 0, "No tokens specified");
        
        uint256 depositValue = 0;
        
        // Calculate deposit value (tokens are already in this contract via CCIP)
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 assetIndex = assetIndexes[tokens[i]];
            require(assetIndex > 0, "Invalid token");
            assetIndex -= 1; // Convert to 0-based index
            
            require(assets[assetIndex].isActive, "Asset not active");
            require(amounts[i] > 0, "Amount must be greater than 0");
            
            // Calculate value in USD
            uint256 tokenValue = priceOracle.getAssetValueInUSD(tokens[i], amounts[i]);
            depositValue += tokenValue;
        }
        
        require(depositValue > 0, "Deposit value must be greater than 0");
        
        // Collect management fees before minting new tokens
        collectManagementFees();
        
        // Calculate ETF tokens to mint based on NAV
        uint256 etfToMint = calculateETFAmount(depositValue);
        require(etfToMint > 0, "ETF amount too small");
        
        // Mint ETF tokens to the sender
        etfToken.mint(sender, etfToMint);
        
        emit Deposit(sender, tokens, amounts, etfToMint);
    }
    
    /**
     * @dev Process redemption from cross-chain bridge
     */
    function processCrossChainRedemption(
        address sender,
        uint64 sourceChain,
        bytes calldata data
    ) external onlyRole(CROSS_CHAIN_ROLE) nonReentrant {
        // Decode the cross-chain redemption data
        uint256 etfAmount = abi.decode(data, (uint256));
        
        require(etfAmount > 0, "Amount must be greater than 0");
        
        // Collect management fees before redemption
        collectManagementFees();
        
        // Calculate proportion of vault to redeem
        uint256 totalETFSupply = etfToken.totalSupply();
        
        // Apply redemption fee
        uint256 feeAmount = (etfAmount * redemptionFeeBps) / BASIS_POINTS;
        uint256 etfAmountAfterFee = etfAmount - feeAmount;
        
        // Send fee to fee recipient
        if (feeAmount > 0) {
            etfToken.transferFrom(address(this), feeRecipient, feeAmount);
        }
        
        // Burn remaining ETF tokens (already transferred to this contract via CCIP)
        etfToken.burn(address(this), etfAmountAfterFee);
        
        uint256 redeemRatio = (etfAmountAfterFee * 1e18) / totalETFSupply;
        
        // Prepare arrays for event
        address[] memory tokens = new address[](assets.length);
        uint256[] memory amounts = new uint256[](assets.length);
        
        // Note: For cross-chain redemption, we don't transfer assets directly
        // Instead, we track what should be transferred and let the bridge contract handle it
        uint256 activeAssetCount = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].isActive) {
                address tokenAddr = assets[i].tokenAddress;
                uint256 vaultBalance = IERC20(tokenAddr).balanceOf(address(this));
                uint256 userAmount = (vaultBalance * redeemRatio) / 1e18;
                
                if (userAmount > 0) {
                    // Transfer to the cross-chain manager (msg.sender)
                    IERC20(tokenAddr).safeTransfer(msg.sender, userAmount);
                    tokens[activeAssetCount] = tokenAddr;
                    amounts[activeAssetCount] = userAmount;
                    activeAssetCount++;
                }
            }
        }
        
        // Resize arrays for emitting event
        assembly {
            mstore(tokens, activeAssetCount)
            mstore(amounts, activeAssetCount)
        }
        
        emit Redemption(sender, etfAmount, tokens, amounts);
    }
    
    /**
     * @dev Calculate amount of ETF tokens to mint based on deposit value
     */
    function calculateETFAmount(uint256 depositValueUSD) internal view returns (uint256) {
        uint256 totalSupply = etfToken.totalSupply();
        
        // If first deposit, use 1:1 ratio with 18 decimals
        if (totalSupply == 0) {
            return depositValueUSD;
        }
        
        uint256 vaultValue = getTotalVaultValue();
        return (depositValueUSD * totalSupply) / vaultValue;
    }
    
    /**
     * @dev Get total value of assets in the vault in USD (18 decimals)
     */
    function getTotalVaultValue() public view returns (uint256) {
        uint256 totalValue = 0;
        
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].isActive) {
                address tokenAddr = assets[i].tokenAddress;
                uint256 balance = IERC20(tokenAddr).balanceOf(address(this));
                
                if (balance > 0) {
                    uint256 assetValue = priceOracle.getAssetValueInUSD(tokenAddr, balance);
                    totalValue += assetValue;
                }
            }
        }
        
        return totalValue;
    }
    
    /**
     * @dev Get current Net Asset Value per ETF token in USD (18 decimals)
     */
    function getNAV() public view returns (uint256) {
        uint256 totalSupply = etfToken.totalSupply();
        if (totalSupply == 0) return 0;
        
        return (getTotalVaultValue() * 1e18) / totalSupply;
    }
    
    /**
     * @dev Get current weights of assets in the vault
     */
    function getCurrentWeights() public view returns (
        address[] memory tokens, 
        uint256[] memory currentWeights
    ) {
        uint256 activeAssetCount = 0;
        
        // Count active assets
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].isActive) {
                activeAssetCount++;
            }
        }
        
        tokens = new address[](activeAssetCount);
        currentWeights = new uint256[](activeAssetCount);
        
        uint256 totalValue = getTotalVaultValue();
        if (totalValue == 0) {
            return (tokens, currentWeights);
        }
        
        uint256 index = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].isActive) {
                address tokenAddr = assets[i].tokenAddress;
                uint256 balance = IERC20(tokenAddr).balanceOf(address(this));
                uint256 assetValue = priceOracle.getAssetValueInUSD(tokenAddr, balance);
                
                tokens[index] = tokenAddr;
                currentWeights[index] = (assetValue * BASIS_POINTS) / totalValue;
                index++;
            }
        }
    }
    
    /**
     * @dev Collect management fees based on time elapsed
     */
    function collectManagementFees() public {
        uint256 timeElapsed = block.timestamp - lastFeeCollection;
        if (timeElapsed == 0) return;
        
        uint256 totalSupply = etfToken.totalSupply();
        if (totalSupply == 0) {
            lastFeeCollection = block.timestamp;
            return;
        }
        
        // Calculate fee amount based on annual rate and time elapsed
        uint256 feeAmount = (totalSupply * managementFeeBps * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
        
        if (feeAmount > 0) {
            // Mint fee tokens to fee recipient
            etfToken.mint(feeRecipient, feeAmount);
            emit FeesCollected(feeAmount);
        }
        
        lastFeeCollection = block.timestamp;
    }
    
    /**
     * @dev Execute rebalancing of vault assets
     */
    function rebalance() external onlyRole(REBALANCER_ROLE) nonReentrant {
        // Actual rebalancing implementation would require:
        // 1. Integration with DEXes or other swap mechanisms
        // 2. Calculating optimal trades to reach target weights
        // 3. Executing trades
        
        // For this example, we'll just collect fees and emit an event
        collectManagementFees();
        emit Rebalanced(msg.sender);
    }
    
    /**
     * @dev Update fee settings
     */
    function updateFeeSettings(
        uint256 _managementFeeBps,
        uint256 _redemptionFeeBps,
        address _feeRecipient
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_managementFeeBps <= 1000, "Management fee too high"); // Max 10%
        require(_redemptionFeeBps <= 500, "Redemption fee too high");  // Max 5%
        require(_feeRecipient != address(0), "Invalid fee recipient");
        
        // Collect any pending fees before changing rates
        collectManagementFees();
        
        managementFeeBps = _managementFeeBps;
        redemptionFeeBps = _redemptionFeeBps;
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Get target weight for a specific asset
     */
    function getAssetTargetWeight(address token) external view returns (uint256) {
        uint256 index = assetIndexes[token];
        require(index > 0, "Asset not found");
        index -= 1; // Convert to 0-based index
        
        require(assets[index].isActive, "Asset not active");
        return assets[index].targetWeight;
    }
    
    /**
     * @dev Set cross-chain manager address
     */
    function setCrossChainManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(CROSS_CHAIN_ROLE, manager);
    }
}