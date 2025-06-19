// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/CrossChainVaultManager.sol";
import "../src/RWAVault.sol";
import "../src/RWAToken.sol";
import "../src/VaultToken.sol";
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

// Mock CCIP Router for testing
contract MockCCIPRouter is IRouterClient {
    uint256 private counter = 0;
    address public lastSender;
    bytes public lastMessage;
    uint256 public lastFee;
    uint64 public lastDestinationChainSelector;
    
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message) external payable returns (bytes32) {
        lastSender = msg.sender;
        lastMessage = message.data;
        lastFee = msg.value;
        lastDestinationChainSelector = destinationChainSelector;
        counter++;
        return bytes32(counter);
    }
    
    function getFee(uint64, Client.EVM2AnyMessage calldata) external pure returns (uint256) {
        return 0.01 ether; // Fixed fee for testing
    }
    
    function getSupportedTokens(uint64) external pure returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x1); // Dummy token address
        return tokens;
    }
    
    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }
    
    // Helper for tests to deliver messages between chains
    function deliverMessage(
        address targetManager,
        address sourceRouter,
        uint64 sourceChain,
        address token,
        uint256 amount,
        bytes memory data
    ) external payable {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);
        
        if (token != address(0) && amount > 0) {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({
                token: token,
                amount: amount
            });
            
            // Transfer tokens to the target manager if needed
            // In a real CCIP scenario, the tokens would be locked on source chain and minted on destination
            if (token.code.length > 0) { // Check if it's a real contract
                IERC20(token).transferFrom(msg.sender, targetManager, amount);
            }
        }
        
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(counter++),
            sourceChainSelector: sourceChain,
            sender: abi.encode(sourceRouter),
            data: data,
            destTokenAmounts: tokenAmounts
        });
        
        (bool success,) = targetManager.call(abi.encodeWithSignature("ccipReceiveForTesting((bytes32,uint64,bytes,bytes,(address,uint256)[]))", message));
        require(success, "ccipReceiveForTesting call failed");
    }
}

// Mock Chainlink Price Feed
contract MockPriceFeed {
    int256 private price;
    uint8 private _decimals;
    
    constructor(int256 _price, uint8 decimals_) {
        price = _price;
        _decimals = decimals_;
    }
    
    function decimals() external view returns (uint8) {
        return _decimals;
    }
    
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

contract CrossChainVaultE2ETest is Test {
    // Chain selectors
    uint64 constant BASE_SEPOLIA_SELECTOR = 10344971235874465080;
    uint64 constant SEPOLIA_SELECTOR = 16015286601757825753;
    
    // Actors
    address vaultCreator = address(0x1);
    address user1OnBase = address(0x2);
    address user2OnBase = address(0x3);
    address user1OnSepolia = address(0x4);
    address user2OnSepolia = address(0x5);

    // Base Sepolia contracts
    MockCCIPRouter baseRouter;
    RWAVault baseVault;
    SimplifiedCrossChainManager baseManager;
    RWAToken baseUSDC;
    RWAToken baseRWA1; // Real estate token
    RWAToken baseRWA2; // Gold token
    MockPriceFeed baseFeed1;
    MockPriceFeed baseFeed2;
    
    // Sepolia contracts
    MockCCIPRouter sepoliaRouter;
    SimplifiedCrossChainManager sepoliaManager;
    RWAToken sepoliaUSDC;
    
    // Test parameters
    uint256 vaultId;
    address vaultTokenAddress;
    
    function setUp() public {
        // Setup Base Sepolia (vault chain)
        vm.startPrank(address(this));
        
        // Deploy Base Sepolia contracts
        baseRouter = new MockCCIPRouter();
        baseVault = new RWAVault();
        baseManager = new SimplifiedCrossChainManager(
            address(baseRouter),
            address(baseVault),
            BASE_SEPOLIA_SELECTOR,
            true // is vault chain
        );
        
        baseUSDC = new RWAToken("USD Coin", "USDC", 6);
        baseRWA1 = new RWAToken("Real Estate Token", "RET", 18);
        baseRWA2 = new RWAToken("Gold Token", "GOLD", 8);
        
        // Deploy price feeds (1 RET = $100, 1 GOLD = $1800)
        baseFeed1 = new MockPriceFeed(100 * 10**8, 8); // $100 with 8 decimals
        baseFeed2 = new MockPriceFeed(1800 * 10**8, 8); // $1800 with 8 decimals
        
        // Configure Base chain
        baseManager.allowlistToken(address(baseUSDC), true);
        baseManager.allowlistChain(SEPOLIA_SELECTOR, address(0), true);
        // FIX: Also allowlist BASE_SEPOLIA_SELECTOR on the base chain
        baseManager.allowlistChain(BASE_SEPOLIA_SELECTOR, address(0), true);
        
        // Send funds to users on Base
        deal(address(baseManager), 10000 ether); // For CCIP fees
        baseUSDC.transfer(user1OnBase, 10000 * 10**6); // 10,000 USDC
        baseUSDC.transfer(user2OnBase, 10000 * 10**6); // 10,000 USDC
        baseRWA1.transfer(vaultCreator, 1000 * 10**18); // 1,000 RET tokens
        baseRWA2.transfer(vaultCreator, 1000 * 10**8);  // 1,000 GOLD tokens
        baseRWA1.transfer(address(baseManager), 100 * 10**18); // 100 RET for the manager
        baseRWA2.transfer(address(baseManager), 100 * 10**8);  // 100 GOLD for the manager
        
        // Setup Sepolia (user chain)
        sepoliaRouter = new MockCCIPRouter();
        sepoliaManager = new SimplifiedCrossChainManager(
            address(sepoliaRouter),
            address(0), // No vault on Sepolia
            SEPOLIA_SELECTOR,
            false // not vault chain
        );
        
        sepoliaUSDC = new RWAToken("USD Coin", "USDC", 6);
        
        // Configure Sepolia chain
        sepoliaManager.allowlistToken(address(sepoliaUSDC), true);
        sepoliaManager.allowlistChain(BASE_SEPOLIA_SELECTOR, address(0), true);
        
        // Send funds to users on Sepolia
        deal(address(sepoliaManager), 10 ether); // For CCIP fees
        sepoliaUSDC.transfer(user1OnSepolia, 10000 * 10**6); // 10,000 USDC
        sepoliaUSDC.transfer(user2OnSepolia, 10000 * 10**6); // 10,000 USDC
        
        // Connect the two managers across chains
        baseManager.allowlistChain(SEPOLIA_SELECTOR, address(sepoliaManager), true);
        sepoliaManager.allowlistChain(BASE_SEPOLIA_SELECTOR, address(baseManager), true);


        deal(user1OnSepolia, 10 ether);
        deal(user2OnSepolia, 10 ether);
        
        vm.stopPrank();
    }

    function testEndToEndVaultCreationAndDeposits() public {
        // 1. Create a vault on Base Sepolia
        vm.startPrank(vaultCreator);
        
        // Setup vault parameters
        address[] memory rwaAssets = new address[](2);
        rwaAssets[0] = address(baseRWA1);
        rwaAssets[1] = address(baseRWA2);
        
        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = address(baseFeed1);
        priceFeeds[1] = address(baseFeed2);
        
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 6000; // 60%
        percentages[1] = 4000; // 40%
        
        // Approve assets for the vault
        baseRWA1.approve(address(baseVault), 1000 * 10**18);
        baseRWA2.approve(address(baseVault), 1000 * 10**8);
        
        // Create the vault
        vaultId = baseVault.createVault(
            rwaAssets,
            priceFeeds,
            percentages,
            address(baseUSDC),
            6, // USDC decimals
            "Diversified RWA Portfolio",
            "DRWA"
        );
        
        console.log("Vault created with ID:", vaultId);
        
        // Get the vault token address
        (address vaultToken, , , , ) = baseVault.getVaultDetails(vaultId);
        vaultTokenAddress = vaultToken;
        console.log("Vault token address:", vaultTokenAddress);
        
        vm.stopPrank();
        
        // Register the vault in the cross-chain system
        vm.prank(vaultCreator);
        baseManager.setVaultChain(vaultId, BASE_SEPOLIA_SELECTOR);
        
        // Register the vault on the other chain too
        vm.prank(vaultCreator);
        sepoliaManager.setVaultChain(vaultId, BASE_SEPOLIA_SELECTOR);
        
        // 2. User1 on Base deposits directly
        vm.startPrank(user1OnBase);
        uint256 depositAmount1 = 1000 * 10**6; // 1,000 USDC
        baseUSDC.approve(address(baseManager), depositAmount1);
        baseManager.crossChainDeposit(vaultId, depositAmount1, address(baseUSDC));
        vm.stopPrank();
        
        // 3. User2 on Base deposits directly
        vm.startPrank(user2OnBase);
        uint256 depositAmount2 = 2000 * 10**6; // 2,000 USDC
        baseUSDC.approve(address(baseManager), depositAmount2);
        baseManager.crossChainDeposit(vaultId, depositAmount2, address(baseUSDC));
        vm.stopPrank();
        
        // 4. User1 on Sepolia deposits cross-chain
        vm.startPrank(user1OnSepolia);
        uint256 depositAmount3 = 1500 * 10**6; // 1,500 USDC
        sepoliaUSDC.approve(address(sepoliaManager), depositAmount3);
        sepoliaManager.crossChainDeposit{value: 0.01 ether}(vaultId, depositAmount3, address(sepoliaUSDC));
        
        // Simulate CCIP message delivery from Sepolia to Base
        // Transfer USDC to simulate cross-chain token delivery
        baseUSDC.transfer(address(baseManager), depositAmount3);
        vm.stopPrank();
        vm.startPrank(address(baseManager));
        baseUSDC.approve(address(sepoliaRouter), depositAmount3);
        vm.stopPrank();
        vm.startPrank(user1OnSepolia);


        bytes memory message = sepoliaRouter.lastMessage();
        sepoliaRouter.deliverMessage(
            address(baseManager),
            address(sepoliaRouter),
            SEPOLIA_SELECTOR,
            address(baseUSDC), // Use Base USDC as the destination token
            depositAmount3,    // Same amount
            message           // The message data
        );
        vm.stopPrank();
        
        // 5. User2 on Sepolia deposits cross-chain
        vm.startPrank(user2OnSepolia);
        uint256 depositAmount4 = 2500 * 10**6; // 2,500 USDC
        sepoliaUSDC.approve(address(sepoliaManager), depositAmount4);
        sepoliaManager.crossChainDeposit{value: 0.01 ether}(vaultId, depositAmount4, address(sepoliaUSDC));
        
        // Simulate CCIP message delivery
        message = sepoliaRouter.lastMessage();
        sepoliaRouter.deliverMessage(
            address(baseManager),
            address(sepoliaRouter),
            SEPOLIA_SELECTOR,
            address(baseUSDC),
            depositAmount4,
            message
        );
        
        // Simulate share credit message delivery back to Sepolia
        message = baseRouter.lastMessage();
        baseRouter.deliverMessage(
            address(sepoliaManager),
            address(baseRouter),
            BASE_SEPOLIA_SELECTOR,
            address(0), // No token transfer
            0,         // No amount
            message
        );
        vm.stopPrank();
        
        // Check vault balances
        uint256 totalDeposited = depositAmount1 + depositAmount2 + depositAmount3 + depositAmount4;
        console.log("Total deposited:", totalDeposited / 10**6, "USDC");
        
        (address[] memory assets, uint256[] memory balances) = baseVault.getVaultBalances(vaultId);
        console.log("Vault USDC balance:", balances[0] / 10**6);
        console.log("Vault RWA1 balance:", balances[1] / 10**18);
        console.log("Vault RWA2 balance:", balances[2] / 10**8);
        
        // Check user share balances
        uint256 user1BaseShares = baseManager.getUserVaultBalance(vaultId, user1OnBase);
        uint256 user2BaseShares = baseManager.getUserVaultBalance(vaultId, user2OnBase);
        console.log("User1 Base shares:", user1BaseShares / 10**6);
        console.log("User2 Base shares:", user2BaseShares / 10**6);
        
        uint256 user1SepoliaShares = sepoliaManager.getUserVaultBalance(vaultId, user1OnSepolia);
        uint256 user2SepoliaShares = sepoliaManager.getUserVaultBalance(vaultId, user2OnSepolia);
        console.log("User1 Sepolia shares:", user1SepoliaShares / 10**6);
        console.log("User2 Sepolia shares:", user2SepoliaShares / 10**6);
        
        // Assert expected values
        assertEq(balances[0], totalDeposited, "USDC balance should match total deposited");
        assertEq(user1BaseShares, depositAmount1, "User1 Base shares incorrect");
        assertEq(user2BaseShares, depositAmount2, "User2 Base shares incorrect");
        assertEq(user1SepoliaShares, depositAmount3, "User1 Sepolia shares incorrect");
        assertEq(user2SepoliaShares, depositAmount4, "User2 Sepolia shares incorrect");
        
        // Now test redemptions within the same test function to ensure state is preserved
        _testRedemptions();
    }
    
    // Modified to be internal so it can be called from testEndToEndVaultCreationAndDeposits
    function _testRedemptions() internal {
        // Starting balances for comparison
        uint256 user1BaseStartBalance = baseUSDC.balanceOf(user1OnBase);
        uint256 user2BaseStartBalance = baseUSDC.balanceOf(user2OnBase);
        uint256 user1SepoliaStartBalance = sepoliaUSDC.balanceOf(user1OnSepolia);
        uint256 user2SepoliaStartBalance = sepoliaUSDC.balanceOf(user2OnSepolia);
        
        // 1. User1 on Base redeems directly
        vm.startPrank(user1OnBase);
        uint256 redeemAmount1 = 500 * 10**6; // 500 USDC worth of shares
        baseManager.crossChainRedeem(vaultId, redeemAmount1);
        vm.stopPrank();
        
        // 2. User2 on Base redeems directly
        vm.startPrank(user2OnBase);
        uint256 redeemAmount2 = 1000 * 10**6; // 1,000 USDC worth of shares
        baseManager.crossChainRedeem(vaultId, redeemAmount2);
        vm.stopPrank();
        
        // 3. User1 on Sepolia redeems cross-chain
        vm.startPrank(user1OnSepolia);
        uint256 redeemAmount3 = 750 * 10**6; // 750 USDC worth of shares
        sepoliaManager.crossChainRedeem{value: 0.01 ether}(vaultId, redeemAmount3);
        
        // Simulate CCIP message delivery from Sepolia to Base
        bytes memory message = sepoliaRouter.lastMessage();
        sepoliaRouter.deliverMessage(
            address(baseManager),
            address(sepoliaRouter),
            SEPOLIA_SELECTOR,
            address(0),
            0,
            message
        );
        
        // Simulate token return message from Base to Sepolia
        message = baseRouter.lastMessage();
        baseRouter.deliverMessage(
            address(sepoliaManager),
            address(baseRouter),
            BASE_SEPOLIA_SELECTOR,
            address(sepoliaUSDC),
            750 * 10**6, // Assuming 1:1 redemption for simplicity
            message
        );
        vm.stopPrank();
        
        // 4. User2 on Sepolia redeems cross-chain
        vm.startPrank(user2OnSepolia);
        uint256 redeemAmount4 = 1250 * 10**6; // 1,250 USDC worth of shares
        sepoliaManager.crossChainRedeem{value: 0.01 ether}(vaultId, redeemAmount4);
        
        // Simulate CCIP message delivery
        message = sepoliaRouter.lastMessage();
        sepoliaRouter.deliverMessage(
            address(baseManager),
            address(sepoliaRouter),
            SEPOLIA_SELECTOR,
            address(0),
            0,
            message
        );
        
        // Simulate token return message
        message = baseRouter.lastMessage();
        baseRouter.deliverMessage(
            address(sepoliaManager),
            address(baseRouter),
            BASE_SEPOLIA_SELECTOR,
            address(sepoliaUSDC),
            1250 * 10**6, // Assuming 1:1 redemption for simplicity
            message
        );
        vm.stopPrank();
        
        // Check ending balances and compare to starting
        uint256 user1BaseEndBalance = baseUSDC.balanceOf(user1OnBase);
        uint256 user2BaseEndBalance = baseUSDC.balanceOf(user2OnBase);
        uint256 user1SepoliaEndBalance = sepoliaUSDC.balanceOf(user1OnSepolia);
        uint256 user2SepoliaEndBalance = sepoliaUSDC.balanceOf(user2OnSepolia);
        
        console.log("User1 Base USDC balance change:", (user1BaseEndBalance - user1BaseStartBalance) / 10**6);
        console.log("User2 Base USDC balance change:", (user2BaseEndBalance - user2BaseStartBalance) / 10**6);
        console.log("User1 Sepolia USDC balance change:", (user1SepoliaEndBalance - user1SepoliaStartBalance) / 10**6);
        console.log("User2 Sepolia USDC balance change:", (user2SepoliaEndBalance - user2SepoliaStartBalance) / 10**6);
        
        // Check remaining shares
        uint256 user1BaseShares = baseManager.getUserVaultBalance(vaultId, user1OnBase);
        uint256 user2BaseShares = baseManager.getUserVaultBalance(vaultId, user2OnBase);
        uint256 user1SepoliaShares = sepoliaManager.getUserVaultBalance(vaultId, user1OnSepolia);
        uint256 user2SepoliaShares = sepoliaManager.getUserVaultBalance(vaultId, user2OnSepolia);
        
        console.log("Remaining shares:");
        console.log("User1 Base shares:", user1BaseShares / 10**6);
        console.log("User2 Base shares:", user2BaseShares / 10**6);
        console.log("User1 Sepolia shares:", user1SepoliaShares / 10**6);
        console.log("User2 Sepolia shares:", user2SepoliaShares / 10**6);
        
        // Check vault final balances
        (address[] memory assets, uint256[] memory balances) = baseVault.getVaultBalances(vaultId);
        console.log("Final vault balances:");
        console.log("Vault USDC balance:", balances[0] / 10**6);
        console.log("Vault RWA1 balance:", balances[1] / 10**18);
        console.log("Vault RWA2 balance:", balances[2] / 10**8);
        
        // Get TVL from the manager
        (
            uint256[] memory vaultIds,
            uint64[] memory chainSelectors,
            address[] memory creators,
            uint256[] memory totalShares,
            uint256[] memory tvls
        ) = baseManager.getLocalVaultDetails();
        
        if (vaultIds.length > 0) {
            console.log("Vault TVL:", tvls[0] / 10**6, "USDC");
        }
        
        // Assertions
        assertTrue(user1BaseEndBalance > user1BaseStartBalance, "User1 Base balance should increase");
        assertTrue(user2BaseEndBalance > user2BaseStartBalance, "User2 Base balance should increase");
        assertTrue(user1SepoliaEndBalance > user1SepoliaStartBalance, "User1 Sepolia balance should increase");
        assertTrue(user2SepoliaEndBalance > user2SepoliaStartBalance, "User2 Sepolia balance should increase");
        
        assertEq(user1BaseShares, 500 * 10**6, "User1 Base should have 500 shares remaining");
        assertEq(user2BaseShares, 1000 * 10**6, "User2 Base should have 1000 shares remaining");
        assertEq(user1SepoliaShares, 750 * 10**6, "User1 Sepolia should have 750 shares remaining");
        assertEq(user2SepoliaShares, 1250 * 10**6, "User2 Sepolia should have 1250 shares remaining");
    }
    
    // This test provides a standalone implementation for testing redemptions
    function testStandaloneRedemptionProcess() public {
        // Setup a vault and perform deposits first to create shares
        testEndToEndVaultCreationAndDeposits();
        
        // Additional redemption tests can be added here if needed
        // This ensures the test has shares to redeem
    }
}