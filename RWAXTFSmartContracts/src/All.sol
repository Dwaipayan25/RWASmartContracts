// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IERC20Decimals is IERC20 {
    function decimals() external view returns (uint8);
}

contract RWAToken is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 tokenDecimals
    ) ERC20(name, symbol) {
        _decimals = tokenDecimals;
        _mint(msg.sender, 1000000 * 10 ** tokenDecimals);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract VaultToken is ERC20 {
    address public immutable vault;

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault can call");
        _;
    }

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        vault = msg.sender;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}

contract RWAVault {
    using SafeERC20 for IERC20Decimals;
    
    struct VaultConfig {
        address vaultToken;
        address[] rwaAssets;
        address[] priceFeeds;
        uint256[] percentages;   // in basis points (10000 = 100%)
        address baseCurrency;    // e.g., USDC
        uint256 baseCurrencyDecimals;
    }

    VaultConfig[] public vaults;
    mapping(address => bool) public isVaultToken;
    mapping(uint256 => mapping(address => uint256)) public vaultBalances;

    event VaultCreated(uint256 vaultId, address vaultToken, address[] assets);
    event Deposited(uint256 vaultId, address user, uint256 baseAmount, uint256 shares);
    event Redeemed(uint256 vaultId, address user, uint256 shares, uint256[] amounts);

    function createVault(
        address[] calldata rwaAssets,
        address[] calldata priceFeeds,
        uint256[] calldata percentages,
        address baseCurrency,
        uint256 baseCurrencyDecimals,
        string memory tokenName,
        string memory tokenSymbol
    ) external returns (uint256 vaultId) {
        require(rwaAssets.length > 0, "No assets provided");
        require(rwaAssets.length == priceFeeds.length, "Invalid price feeds");
        require(rwaAssets.length == percentages.length, "Invalid percentages");
        require(baseCurrency != address(0), "Invalid base currency");
        
        // Validate percentages sum to 100%
        uint256 totalPercentage;
        for (uint i = 0; i < percentages.length; i++) {
            totalPercentage += percentages[i];
        }
        require(totalPercentage == 10000, "Percentages must sum to 10000");
        
        vaultId = vaults.length;
        VaultConfig memory newVault;
        
        newVault.rwaAssets = rwaAssets;
        newVault.priceFeeds = priceFeeds;
        newVault.percentages = percentages;
        newVault.baseCurrency = baseCurrency;
        newVault.baseCurrencyDecimals = baseCurrencyDecimals;
        newVault.vaultToken = address(new VaultToken(tokenName, tokenSymbol));
        
        vaults.push(newVault);
        isVaultToken[newVault.vaultToken] = true;
        
        emit VaultCreated(vaultId, newVault.vaultToken, rwaAssets);
        return vaultId;
    }

    function calculateRequiredRWAs(
        uint256 vaultId, 
        uint256 baseAmount
    ) public view returns (address[] memory, uint256[] memory) {
        require(vaultId < vaults.length, "Invalid vault ID");
        VaultConfig storage vault = vaults[vaultId];
        
        uint256[] memory amounts = new uint256[](vault.rwaAssets.length);
        
        for (uint i = 0; i < vault.rwaAssets.length; i++) {
            // Calculate base currency value for this asset
            uint256 assetValue = (baseAmount * vault.percentages[i]) / 10000;
            
            // Get price from Chainlink (base currency per RWA token)
            AggregatorV3Interface priceFeed = AggregatorV3Interface(vault.priceFeeds[i]);
            (, int256 price,,,) = priceFeed.latestRoundData();
            uint8 feedDecimals = priceFeed.decimals();
            
            // Convert price to base currency decimals
            uint256 priceInBase = uint256(price) * 
                (10 ** (vault.baseCurrencyDecimals - feedDecimals));
            
            // Get RWA token decimals
            IERC20Decimals rwaToken = IERC20Decimals(vault.rwaAssets[i]);
            uint8 rwaDecimals = rwaToken.decimals();
            
            // Calculate required RWA amount: (assetValue * 10^rwaDecimals) / priceInBase
            amounts[i] = (assetValue * (10 ** rwaDecimals)) / priceInBase;
        }
        
        return (vault.rwaAssets, amounts);
    }

    function deposit(uint256 vaultId, uint256 baseAmount) external {
        require(vaultId < vaults.length, "Invalid vault ID");
        require(baseAmount > 0, "Must deposit positive amount");
        
        VaultConfig storage vault = vaults[vaultId];
        
        // Calculate required RWA amounts
        (address[] memory assets, uint256[] memory amounts) = 
            calculateRequiredRWAs(vaultId, baseAmount);
        
        // Transfer base currency from user
        IERC20Decimals baseToken = IERC20Decimals(vault.baseCurrency);
        baseToken.safeTransferFrom(msg.sender, address(this), baseAmount);
        vaultBalances[vaultId][vault.baseCurrency] += baseAmount;
        
        // Transfer required RWAs from user
        for (uint i = 0; i < assets.length; i++) {
            if (amounts[i] > 0) {
                IERC20Decimals(assets[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
                vaultBalances[vaultId][assets[i]] += amounts[i];
            }
        }
        
        // Calculate shares (1 share per base currency unit)
        uint256 shares = baseAmount;
        
        // Mint vault tokens (1 token = 1 base currency unit)
        VaultToken(vault.vaultToken).mint(msg.sender, shares);
        
        emit Deposited(vaultId, msg.sender, baseAmount, shares);
    }

    function redeem(uint256 vaultId, uint256 shares) external {
        require(vaultId < vaults.length, "Invalid vault ID");
        require(shares > 0, "Must redeem positive shares");
        
        VaultConfig storage vault = vaults[vaultId];
        VaultToken token = VaultToken(vault.vaultToken);
        
        require(token.balanceOf(msg.sender) >= shares, "Insufficient shares");
        
        // Calculate proportional amounts for each asset
        uint256[] memory amounts = new uint256[](vault.rwaAssets.length + 1);
        address[] memory allAssets = new address[](vault.rwaAssets.length + 1);
        
        // Include base currency in redeemable assets
        allAssets[0] = vault.baseCurrency;
        for (uint i = 0; i < vault.rwaAssets.length; i++) {
            allAssets[i+1] = vault.rwaAssets[i];
        }
        
        for (uint i = 0; i < allAssets.length; i++) {
            address asset = allAssets[i];
            uint256 totalBalance = vaultBalances[vaultId][asset];
            uint256 redeemAmount = (totalBalance * shares) / token.totalSupply();
            
            if (redeemAmount > 0) {
                vaultBalances[vaultId][asset] -= redeemAmount;
                IERC20Decimals(asset).safeTransfer(msg.sender, redeemAmount);
                amounts[i] = redeemAmount;
            }
        }
        
        // Burn vault tokens
        token.burn(msg.sender, shares);
        
        emit Redeemed(vaultId, msg.sender, shares, amounts);
    }

    // ================== VIEW FUNCTIONS ==================
    function getVaultDetails(uint256 vaultId) external view returns (
        address vaultToken,
        address[] memory rwaAssets,
        uint256[] memory percentages,
        address baseCurrency,
        uint256 baseCurrencyDecimals
    ) {
        require(vaultId < vaults.length, "Invalid vault ID");
        VaultConfig storage vault = vaults[vaultId];
        
        return (
            vault.vaultToken,
            vault.rwaAssets,
            vault.percentages,
            vault.baseCurrency,
            vault.baseCurrencyDecimals
        );
    }

    function getVaultBalances(uint256 vaultId) external view returns (
        address[] memory assets,
        uint256[] memory balances
    ) {
        require(vaultId < vaults.length, "Invalid vault ID");
        VaultConfig storage vault = vaults[vaultId];
        
        uint256 length = vault.rwaAssets.length + 1; // +1 for base currency
        assets = new address[](length);
        balances = new uint256[](length);
        
        // Add base currency
        assets[0] = vault.baseCurrency;
        balances[0] = vaultBalances[vaultId][vault.baseCurrency];
        
        // Add RWA assets
        for (uint i = 0; i < vault.rwaAssets.length; i++) {
            assets[i+1] = vault.rwaAssets[i];
            balances[i+1] = vaultBalances[vaultId][vault.rwaAssets[i]];
        }
        
        return (assets, balances);
    }

    function getOwnershipPercentage(
        uint256 vaultId, 
        address owner
    ) external view returns (uint256) {
        require(vaultId < vaults.length, "Invalid vault ID");
        VaultConfig storage vault = vaults[vaultId];
        VaultToken token = VaultToken(vault.vaultToken);
        
        uint256 totalSupply = token.totalSupply();
        if (totalSupply == 0) return 0;
        
        return (token.balanceOf(owner) * 10000) / totalSupply;
    }
}