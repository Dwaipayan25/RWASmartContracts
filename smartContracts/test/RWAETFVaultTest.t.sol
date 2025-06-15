// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/RWAETFVault.sol";
import "../src/interfaces/IETFToken.sol";
import "../src/PriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// Mock contracts for testing
contract MockETFToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    constructor() ERC20("Test ETF Token", "TETF") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }
    
    function setVaultRole(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, vault);
        _grantRole(BURNER_ROLE, vault);
    }
}

contract MockRWAToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPriceOracle {
    mapping(address => uint256) public prices;
    mapping(address => bool) public activeFeeds;
    
    function setPrice(address token, uint256 price) external {
        prices[token] = price;
        activeFeeds[token] = true;
    }
    
    function getAssetValueInUSD(address token, uint256 amount) external view returns (uint256) {
        return (amount * prices[token]) / 10**18;
    }
    
    function hasActivePriceFeed(address token) external view returns (bool) {
        return activeFeeds[token];
    }
}

contract RWAETFVaultTest is Test {
    RWAETFVault public vault;
    MockETFToken public etfToken;
    MockPriceOracle public priceOracle;
    MockRWAToken public rwaToken1;
    MockRWAToken public rwaToken2;
    MockRWAToken public rwaToken3;
    
    address public governance = address(0x1);
    address public rebalancer = address(0x2);
    address public crossChainManager = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    address public feeRecipient = address(0x6);
    
    uint256 constant BASIS_POINTS = 10000;
    
    event Deposit(address indexed user, address[] tokens, uint256[] amounts, uint256 etfMinted);
    event Redemption(address indexed user, uint256 etfBurned, address[] tokens, uint256[] amounts);
    event AssetAdded(address indexed token, uint256 targetWeight, string name);
    event AssetUpdated(address indexed token, uint256 targetWeight, uint256 minWeight, uint256 maxWeight);
    event AssetRemoved(address indexed token);
    event FractionalOwnershipPurchased(address indexed buyer, uint256 numberOfSquares, uint256 etfAmount);
    event FractionalOwnershipRedeemed(address indexed user, uint256 numberOfSquares, uint256 etfBurned);
    event Rebalanced(address indexed rebalancer);
    
    function setUp() public {
        // Deploy mock contracts
        etfToken = new MockETFToken();
        priceOracle = new MockPriceOracle();
        rwaToken1 = new MockRWAToken("Carbon Credits", "CARBON");
        rwaToken2 = new MockRWAToken("Treasury Bills", "TBILL");
        rwaToken3 = new MockRWAToken("Real Estate", "REIT");
        
        // Set up price feeds
        priceOracle.setPrice(address(rwaToken1), 10 * 10**18); // $10 per token
        priceOracle.setPrice(address(rwaToken2), 100 * 10**18); // $100 per token
        priceOracle.setPrice(address(rwaToken3), 50 * 10**18); // $50 per token
        
        // Deploy vault
        vault = new RWAETFVault(
            "Green Energy Vault",
            address(etfToken),
            address(priceOracle),
            governance
        );
        
        // Grant vault permissions to mint/burn ETF tokens
        etfToken.setVaultRole(address(vault));
        
        // Distribute tokens to users
        rwaToken1.transfer(user1, 100 * 10**18);
        rwaToken2.transfer(user1, 10 * 10**18);
        rwaToken3.transfer(user1, 20 * 10**18);
        
        rwaToken1.transfer(user2, 100 * 10**18);
        rwaToken2.transfer(user2, 10 * 10**18);
        rwaToken3.transfer(user2, 20 * 10**18);
    }
    
    function testConstructor() public {
        assertEq(vault.name(), "Green Energy Vault");
        assertEq(address(vault.etfToken()), address(etfToken));
        assertEq(address(vault.priceOracle()), address(priceOracle));
        assertEq(vault.feeRecipient(), governance);
        assertEq(vault.totalFractions(), 100);
        assertEq(vault.nextFractionId(), 1);
        
        // Check roles
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(vault.hasRole(vault.GOVERNANCE_ROLE(), governance));
        assertTrue(vault.hasRole(vault.REBALANCER_ROLE(), governance));
    }
    
    function testAddAsset() public {
        vm.prank(governance);
        vm.expectEmit(true, false, false, true);
        emit AssetAdded(address(rwaToken1), 5000, "Carbon Credits");
        
        vault.addAsset(address(rwaToken1), 5000, 4000, 6000, "Carbon Credits");
        
        // Verify asset was added
        (address tokenAddr, uint256 targetWeight, uint256 minWeight, uint256 maxWeight, bool isActive) = vault.assets(0);
        assertEq(tokenAddr, address(rwaToken1));
        assertEq(targetWeight, 5000);
        assertEq(minWeight, 4000);
        assertEq(maxWeight, 6000);
        assertTrue(isActive);
        
        assertEq(vault.assetIndexes(address(rwaToken1)), 1);
        assertEq(vault.getAssetName(address(rwaToken1)), "Carbon Credits");
    }
    
    function testAddAssetFailures() public {
        // Test unauthorized access
        vm.prank(user1);
        vm.expectRevert();
        vault.addAsset(address(rwaToken1), 5000, 4000, 6000, "Carbon Credits");
        
        // Test invalid parameters
        vm.startPrank(governance);
        
        // Zero address
        vm.expectRevert("Invalid token address");
        vault.addAsset(address(0), 5000, 4000, 6000, "Test");
        
        // Invalid weight
        vm.expectRevert("Invalid target weight");
        vault.addAsset(address(rwaToken1), 0, 4000, 6000, "Test");
        
        vm.expectRevert("Invalid target weight");
        vault.addAsset(address(rwaToken1), 15000, 4000, 6000, "Test");
        
        // Invalid weight range
        vm.expectRevert("Invalid weight range");
        vault.addAsset(address(rwaToken1), 5000, 6000, 4000, "Test");
        
        // No price feed
        MockRWAToken newToken = new MockRWAToken("No Feed", "NOFEED");
        vm.expectRevert("No price feed for token");
        vault.addAsset(address(newToken), 5000, 4000, 6000, "Test");
        
        // Empty name
        vm.expectRevert("Asset name required");
        vault.addAsset(address(rwaToken1), 5000, 4000, 6000, "");
        
        vm.stopPrank();
    }
    
    function testAddMultipleAssetsWithWeightLimit() public {
        vm.startPrank(governance);
        
        vault.addAsset(address(rwaToken1), 6000, 5000, 7000, "Carbon Credits");
        vault.addAsset(address(rwaToken2), 4000, 3000, 5000, "Treasury Bills");
        
        // Should fail to add third asset that would exceed 100%
        vm.expectRevert("Total weight exceeds 100%");
        vault.addAsset(address(rwaToken3), 1000, 500, 1500, "Real Estate");
        
        vm.stopPrank();
    }
    
    function testUpdateAsset() public {
        // First add an asset
        vm.prank(governance);
        vault.addAsset(address(rwaToken1), 5000, 4000, 6000, "Carbon Credits");
        
        // Update the asset
        vm.prank(governance);
        vm.expectEmit(true, false, false, true);
        emit AssetUpdated(address(rwaToken1), 6000, 5000, 7000);
        
        vault.updateAsset(address(rwaToken1), 6000, 5000, 7000);
        
        // Verify update
        (, uint256 targetWeight, uint256 minWeight, uint256 maxWeight,) = vault.assets(0);
        assertEq(targetWeight, 6000);
        assertEq(minWeight, 5000);
        assertEq(maxWeight, 7000);
    }
    
    function testRemoveAsset() public {
        // First add an asset
        vm.prank(governance);
        vault.addAsset(address(rwaToken1), 5000, 4000, 6000, "Carbon Credits");
        
        // Remove the asset
        vm.prank(governance);
        vm.expectEmit(true, false, false, false);
        emit AssetRemoved(address(rwaToken1));
        
        vault.removeAsset(address(rwaToken1));
        
        // Verify asset is inactive
        (,,,, bool isActive) = vault.assets(0);
        assertFalse(isActive);
    }
    
    function testDepositFirstTime() public {
        // Add assets to vault
        vm.startPrank(governance);
        vault.addAsset(address(rwaToken1), 5000, 4000, 6000, "Carbon Credits");
        vault.addAsset(address(rwaToken2), 5000, 4000, 6000, "Treasury Bills");
        vm.stopPrank();
        
        // Prepare deposit
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(rwaToken1);
        tokens[1] = address(rwaToken2);
        amounts[0] = 10 * 10**18; // 10 tokens at $10 each = $100
        amounts[1] = 1 * 10**18;  // 1 token at $100 each = $100
        
        // Expected ETF amount: $200 total value
        uint256 expectedETF = 200 * 10**18;
        
        // Approve tokens
        vm.startPrank(user1);
        rwaToken1.approve(address(vault), amounts[0]);
        rwaToken2.approve(address(vault), amounts[1]);
        
        // Expect deposit event
        vm.expectEmit(true, false, false, true);
        emit Deposit(user1, tokens, amounts, expectedETF);
        
        vault.deposit(tokens, amounts);
        vm.stopPrank();
        
        // Verify results
        assertEq(etfToken.balanceOf(user1), expectedETF);
        assertEq(rwaToken1.balanceOf(address(vault)), amounts[0]);
        assertEq(rwaToken2.balanceOf(address(vault)), amounts[1]);
    }
    
    function testDepositSubsequent() public {
        // Setup vault with initial deposit
        testDepositFirstTime();
        
        // Second deposit from user2
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(rwaToken1);
        amounts[0] = 5 * 10**18; // 5 tokens at $10 each = $50
        
        // Current vault value is $200, total supply is 200 ETF tokens
        // New deposit $50 should get 50 ETF tokens
        uint256 expectedETF = 50 * 10**18;
        
        vm.startPrank(user2);
        rwaToken1.approve(address(vault), amounts[0]);
        vault.deposit(tokens, amounts);
        vm.stopPrank();
        
        assertEq(etfToken.balanceOf(user2), expectedETF);
    }
    
    function testRedemption() public {
        // Setup vault with initial deposit
        testDepositFirstTime();
        
        uint256 etfBalance = etfToken.balanceOf(user1);
        uint256 redeemAmount = etfBalance / 2; // Redeem 50%
        
        vm.startPrank(user1);
        etfToken.approve(address(vault), redeemAmount);
        
        uint256 initialToken1Balance = rwaToken1.balanceOf(user1);
        uint256 initialToken2Balance = rwaToken2.balanceOf(user1);
        
        vault.redeem(redeemAmount);
        vm.stopPrank();
        
        // Should receive approximately 50% of vault assets minus fees
        assertGt(rwaToken1.balanceOf(user1), initialToken1Balance);
        assertGt(rwaToken2.balanceOf(user1), initialToken2Balance);
        
        // ETF balance should be reduced (considering fees)
        assertLt(etfToken.balanceOf(user1), etfBalance);
    }
    
    function testBuyVaultFractions() public {
        // Setup vault with initial assets
        vm.startPrank(governance);
        vault.addAsset(address(rwaToken1), 10000, 9000, 10000, "Carbon Credits");
        vm.stopPrank();
        
        // Create initial vault value
        vm.startPrank(user1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(rwaToken1);
        amounts[0] = 100 * 10**18; // $1000 value
        
        rwaToken1.approve(address(vault), amounts[0]);
        vault.deposit(tokens, amounts);
        vm.stopPrank();
        
        // User2 buys 10 squares (10% of vault)
        uint256 numberOfSquares = 10;
        
        vm.startPrank(user2);
        rwaToken1.approve(address(vault), 10 * 10**18);
        
        vm.expectEmit(true, false, false, true);
        emit FractionalOwnershipPurchased(user2, numberOfSquares, 100 * 10**18);
        
        vault.buyVaultFractions(numberOfSquares, tokens, amounts);
        vm.stopPrank();
        
        // Verify square ownership
        assertEq(vault.getUserTotalSquares(user2), numberOfSquares);
        assertEq(vault.getAvailableFractions(), 90);
    }
    
    function testRedeemSquares() public {
        // Setup with square ownership
        testBuyVaultFractions();
        
        uint256 squaresToRedeem = 5;
        uint256 initialBalance = rwaToken1.balanceOf(user2);
        
        vm.prank(user2);
        vault.redeemSquares(squaresToRedeem);
        
        // Should receive tokens back
        assertGt(rwaToken1.balanceOf(user2), initialBalance);
        
        // Square count should be reduced
        assertEq(vault.getUserTotalSquares(user2), 5);
    }
    
    function testCrossChainDeposit() public {
        // Setup vault and grant cross-chain role
        vm.startPrank(governance);
        vault.addAsset(address(rwaToken1), 10000, 9000, 10000, "Carbon Credits");
        vault.setCrossChainManager(crossChainManager);
        vm.stopPrank();
        
        // Simulate cross-chain deposit
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(rwaToken1);
        amounts[0] = 10 * 10**18;
        
        bytes memory data = abi.encode(tokens, amounts);
        
        // Transfer tokens to vault (simulating CCIP transfer)
        rwaToken1.transfer(address(vault), amounts[0]);
        
        vm.prank(crossChainManager);
        vault.processCrossChainDeposit(user1, 1, data);
        
        // Verify ETF tokens were minted to user1
        assertEq(etfToken.balanceOf(user1), 100 * 10**18);
    }
    
    function testManagementFees() public {
        // Setup vault with deposit
        testDepositFirstTime();
        
        uint256 initialSupply = etfToken.totalSupply();
        uint256 initialFeeRecipientBalance = etfToken.balanceOf(feeRecipient);
        
        // Fast forward time by 1 year
        vm.warp(block.timestamp + 365 days);
        
        // Collect fees
        vault.collectManagementFees();
        
        // Fee recipient should have received management fees
        assertGt(etfToken.balanceOf(feeRecipient), initialFeeRecipientBalance);
        
        // Total supply should have increased
        assertGt(etfToken.totalSupply(), initialSupply);
    }
    
    function testUpdateFeeSettings() public {
        vm.prank(governance);
        vault.updateFeeSettings(100, 50, feeRecipient);
        
        assertEq(vault.managementFeeBps(), 100);
        assertEq(vault.redemptionFeeBps(), 50);
        assertEq(vault.feeRecipient(), feeRecipient);
    }
    
    function testGetVaultComposition() public {
        // Setup vault with multiple assets
        vm.startPrank(governance);
        vault.addAsset(address(rwaToken1), 6000, 5000, 7000, "Carbon Credits");
        vault.addAsset(address(rwaToken2), 4000, 3000, 5000, "Treasury Bills");
        vm.stopPrank();
        
        // Add some assets to vault
        vm.startPrank(user1);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(rwaToken1);
        tokens[1] = address(rwaToken2);
        amounts[0] = 10 * 10**18; // $100 value
        amounts[1] = 1 * 10**18;  // $100 value
        
        rwaToken1.approve(address(vault), amounts[0]);
        rwaToken2.approve(address(vault), amounts[1]);
        vault.deposit(tokens, amounts);
        vm.stopPrank();
        
        // Test composition
        (string[] memory names, uint256[] memory percentages, uint256[] memory values, address[] memory addresses) = vault.getVaultComposition();
        
        assertEq(names.length, 2);
        assertEq(percentages.length, 2);
        assertEq(values.length, 2);
        assertEq(addresses.length, 2);
        
        // Each asset should be 50% of vault (5000 basis points)
        assertEq(percentages[0], 5000);
        assertEq(percentages[1], 5000);
    }
    
    function testGetVaultGrid() public {
        // Setup and get grid
        testGetVaultComposition();
        
        uint256[100] memory grid = vault.getVaultGrid();
        
        // First 50 squares should be asset 1, next 50 should be asset 2
        for (uint256 i = 0; i < 50; i++) {
            assertEq(grid[i], 1);
        }
        for (uint256 i = 50; i < 100; i++) {
            assertEq(grid[i], 2);
        }
    }
    
    function testGetNAV() public {
        testDepositFirstTime();
        
        uint256 nav = vault.getNAV();
        
        // NAV should be $1 per ETF token initially (200 value / 200 supply)
        assertEq(nav, 1 * 10**18);
    }
    
    function testGetCurrentWeights() public {
        testGetVaultComposition();
        
        (address[] memory tokens, uint256[] memory weights) = vault.getCurrentWeights();
        
        assertEq(tokens.length, 2);
        assertEq(weights.length, 2);
        
        // Each asset should be 50% (5000 basis points)
        assertEq(weights[0], 5000);
        assertEq(weights[1], 5000);
    }
    
    function testRebalance() public {
        testDepositFirstTime();
        
        vm.prank(governance);
        vm.expectEmit(true, false, false, false);
        emit Rebalanced(governance);
        
        vault.rebalance();
    }
    
    function testAccessControl() public {
        // Test that non-governance cannot add assets
        vm.prank(user1);
        vm.expectRevert();
        vault.addAsset(address(rwaToken1), 5000, 4000, 6000, "Test");
        
        // Test that non-rebalancer cannot rebalance
        vm.prank(user1);
        vm.expectRevert();
        vault.rebalance();
        
        // Test that non-admin cannot set cross-chain manager
        vm.prank(user1);
        vm.expectRevert();
        vault.setCrossChainManager(crossChainManager);
    }
    
    function testDepositFailures() public {
        // Test empty arrays
        address[] memory emptyTokens = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        
        vm.prank(user1);
        vm.expectRevert("No tokens specified");
        vault.deposit(emptyTokens, emptyAmounts);
        
        // Test mismatched arrays
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(rwaToken1);
        amounts[0] = 10;
        amounts[1] = 20;
        
        vm.prank(user1);
        vm.expectRevert("Arrays length mismatch");
        vault.deposit(tokens, amounts);
    }
    
    function testRedemptionFailures() public {
        // Test redeem with no balance
        vm.prank(user1);
        vm.expectRevert("Insufficient ETF balance");
        vault.redeem(100);
        
        // Test redeem zero amount
        vm.prank(user1);
        vm.expectRevert("Amount must be greater than 0");
        vault.redeem(0);
    }
    
    function testFeeValidation() public {
        // Test excessive management fee
        vm.prank(governance);
        vm.expectRevert("Management fee too high");
        vault.updateFeeSettings(1001, 25, feeRecipient);
        
        // Test excessive redemption fee
        vm.prank(governance);
        vm.expectRevert("Redemption fee too high");
        vault.updateFeeSettings(50, 501, feeRecipient);
        
        // Test invalid fee recipient
        vm.prank(governance);
        vm.expectRevert("Invalid fee recipient");
        vault.updateFeeSettings(50, 25, address(0));
    }
    
    function testGetUserOwnership() public {
        testDepositFirstTime();
        
        (uint256 totalSquares, uint256 etfBalance, uint256 ownershipPercentage, uint256 usdValue) = vault.getUserOwnership(user1);
        
        assertEq(etfBalance, 200 * 10**18);
        assertEq(ownershipPercentage, 10000); // 100% ownership
        assertApproxEqAbs(usdValue, 200 * 10**18, 1); // ~$200 value
    }
}