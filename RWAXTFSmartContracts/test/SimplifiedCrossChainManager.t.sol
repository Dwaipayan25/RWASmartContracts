// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/CrossChainVaultManager.sol";
import "./mocks/MockCCIPRouter.sol";
import "./mocks/MockRWAVault.sol";
import "./mocks/ERC20Mock.sol";
import {Client} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";

contract SimplifiedCrossChainManagerTest is Test {
    SimplifiedCrossChainManager public vaultChainManager;
    SimplifiedCrossChainManager public userChainManager;
    MockCCIPRouter public router;
    MockRWAVault public vault;
    MockERC20 public usdc;
    MockERC20 public rwa1;
    MockERC20 public rwa2;
    MockVaultToken public vaultToken;
    
    address public owner;
    address public user1;
    address public user2;
    
    uint64 public constant VAULT_CHAIN_SELECTOR = 1;
    uint64 public constant USER_CHAIN_SELECTOR = 2;
    uint256 public constant VAULT_ID = 0;
    
    event CrossChainDepositInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChain,
        address indexed user,
        uint256 vaultId,
        uint256 amount
    );
    
    event CrossChainDepositCompleted(
        address indexed user,
        uint256 indexed vaultId,
        uint256 amount,
        uint256 shares
    );
    
    event SharesCredited(
        address indexed user,
        uint256 indexed vaultId,
        uint256 shares
    );
    
    event CrossChainRedeemCompleted(
        address indexed user,
        uint256 indexed vaultId,
        uint256 shares,
        uint256 amount
    );

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Deploy mocks
        router = new MockCCIPRouter();
        vault = new MockRWAVault();
        usdc = new MockERC20("USDC", "USDC", 6);
        rwa1 = new MockERC20("RWA1", "RWA1", 18);
        rwa2 = new MockERC20("RWA2", "RWA2", 8);
        
        // Deploy vault token
        vaultToken = new MockVaultToken("Vault Token", "VT");
        
        // Setup mock vault
        address[] memory rwaAssets = new address[](2);
        rwaAssets[0] = address(rwa1);
        rwaAssets[1] = address(rwa2);
        
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 6000; // 60%
        percentages[1] = 4000; // 40%
        
        vault.createMockVault(
            VAULT_ID,
            address(vaultToken),
            rwaAssets,
            percentages,
            address(usdc),
            6
        );
        
        // Deploy managers
        vaultChainManager = new SimplifiedCrossChainManager(
            address(router),
            address(vault),
            VAULT_CHAIN_SELECTOR,
            true // isVaultChain
        );
        
        userChainManager = new SimplifiedCrossChainManager(
            address(router),
            address(0), // No vault on user chain
            USER_CHAIN_SELECTOR,
            false // isVaultChain
        );
        
        // Configure managers
        _setupManagers();
        
        // Fund users
        usdc.transfer(user1, 10000e6);
        usdc.transfer(user2, 10000e6);
        rwa1.transfer(address(vaultChainManager), 1000e18);
        rwa2.transfer(address(vaultChainManager), 1000e8);
        usdc.transfer(address(vaultChainManager), 10000e6);
        
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        vm.deal(address(vaultChainManager), 10 ether);
        vm.deal(address(userChainManager), 10 ether);
    }
    
    function _setupManagers() internal {
        // Cross-link managers
        vaultChainManager.allowlistChain(
            USER_CHAIN_SELECTOR,
            address(userChainManager),
            true
        );
        
        userChainManager.allowlistChain(
            VAULT_CHAIN_SELECTOR,
            address(vaultChainManager),
            true
        );

        // IMPORTANT: Vault chain manager also needs to allowlist itself!
        vaultChainManager.allowlistChain(
            VAULT_CHAIN_SELECTOR,
            address(vaultChainManager),
            true
        );
        
        // Allowlist tokens
        vaultChainManager.allowlistToken(address(usdc), true);
        userChainManager.allowlistToken(address(usdc), true);
        
        // Set vault chain
        userChainManager.setVaultChain(VAULT_ID, VAULT_CHAIN_SELECTOR);
        vaultChainManager.setVaultChain(VAULT_ID, VAULT_CHAIN_SELECTOR);
    }

    // ============ CONSTRUCTOR TESTS ============
    
    function testConstructor() public {
        assertEq(address(vaultChainManager.router()), address(router));
        assertEq(address(vaultChainManager.vault()), address(vault));
        assertEq(vaultChainManager.thisChain(), VAULT_CHAIN_SELECTOR);
        assertTrue(vaultChainManager.isVaultChain());
        
        assertEq(address(userChainManager.vault()), address(0));
        assertEq(userChainManager.thisChain(), USER_CHAIN_SELECTOR);
        assertFalse(userChainManager.isVaultChain());
    }

    // ============ ADMIN FUNCTION TESTS ============
    
    function testAllowlistChain() public {
        uint64 newChain = 3;
        address newManager = makeAddr("newManager");
        
        vaultChainManager.allowlistChain(newChain, newManager, true);
        
        assertTrue(vaultChainManager.allowlistedChains(newChain));
        assertEq(vaultChainManager.crossChainManagers(newChain), newManager);
    }
    
    function testAllowlistChainOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert("Only callable by owner"); // Change this line
        vaultChainManager.allowlistChain(3, makeAddr("manager"), true);
    }

    
    
    function testAllowlistToken() public {
        address newToken = makeAddr("newToken");
        
        vaultChainManager.allowlistToken(newToken, true);
        assertTrue(vaultChainManager.allowlistedTokens(newToken));
        
        vaultChainManager.allowlistToken(newToken, false);
        assertFalse(vaultChainManager.allowlistedTokens(newToken));
    }
    
    function testSetVaultChain() public {
        uint256 newVaultId = 1;
        uint64 newChain = 3;
        
        vaultChainManager.setVaultChain(newVaultId, newChain);
        assertEq(vaultChainManager.vaultChains(newVaultId), newChain);
    }

    // ============ SAME-CHAIN DEPOSIT TESTS ============
    
    function testDirectDeposit() public {
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(vaultChainManager), depositAmount);
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainDepositCompleted(user1, VAULT_ID, depositAmount, depositAmount);
        
        vaultChainManager.crossChainDeposit(VAULT_ID, depositAmount, address(usdc));
        vm.stopPrank();
        
        assertEq(vaultChainManager.getUserVaultBalance(VAULT_ID, user1), depositAmount);
    }
    
    function testDirectDepositInsufficientRWA() public {
        // Remove RWA tokens to simulate insufficient balance
        vm.prank(owner);
        vaultChainManager.withdrawRWATokens(address(rwa1), rwa1.balanceOf(address(vaultChainManager)));
        
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(vaultChainManager), depositAmount);
        
        vm.expectRevert("Insufficient RWA tokens in manager");
        vaultChainManager.crossChainDeposit(VAULT_ID, depositAmount, address(usdc));
        vm.stopPrank();
    }
    
    function testDirectDepositWrongBaseCurrency() public {
        MockERC20 wrongToken = new MockERC20("WRONG", "WRONG", 18);
        wrongToken.transfer(user1, 1000e18);
        
        vaultChainManager.allowlistToken(address(wrongToken), true);
        
        uint256 depositAmount = 1000e18;
        
        vm.startPrank(user1);
        wrongToken.approve(address(vaultChainManager), depositAmount);
        
        vm.expectRevert("Wrong base currency");
        vaultChainManager.crossChainDeposit(VAULT_ID, depositAmount, address(wrongToken));
        vm.stopPrank();
    }

    // ============ CROSS-CHAIN DEPOSIT TESTS ============
    
    function testCrossChainDepositInitiation() public {
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(userChainManager), depositAmount);
        
        vm.expectEmit(false, true, true, true);
        emit CrossChainDepositInitiated(
            bytes32(0), // Will be overridden by actual messageId
            VAULT_CHAIN_SELECTOR,
            user1,
            VAULT_ID,
            depositAmount
        );
        
        userChainManager.crossChainDeposit{value: router.MOCK_FEE()}(
            VAULT_ID,
            depositAmount,
            address(usdc)
        );
        vm.stopPrank();
        
        // Check USDC was transferred to manager
        assertEq(usdc.balanceOf(address(userChainManager)), depositAmount);
    }
    
    function testCrossChainDepositInsufficientFee() public {
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(userChainManager), depositAmount);
        
        vm.expectRevert("Insufficient fee");
        userChainManager.crossChainDeposit{value: router.MOCK_FEE() - 1}(
            VAULT_ID,
            depositAmount,
            address(usdc)
        );
        vm.stopPrank();
    }

    // ============ SAME-CHAIN REDEEM TESTS ============
    
    function testDirectRedeem() public {
        // First deposit
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(vaultChainManager), depositAmount);
        vaultChainManager.crossChainDeposit(VAULT_ID, depositAmount, address(usdc));
        
        uint256 shares = vaultChainManager.getUserVaultBalance(VAULT_ID, user1);
        uint256 redeemShares = shares / 2;
        
        uint256 usdcBalanceBefore = usdc.balanceOf(user1);
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainRedeemCompleted(user1, VAULT_ID, redeemShares, redeemShares);
        
        vaultChainManager.crossChainRedeem(VAULT_ID, redeemShares);
        vm.stopPrank();
        
        assertEq(vaultChainManager.getUserVaultBalance(VAULT_ID, user1), shares - redeemShares);
        assertEq(usdc.balanceOf(user1), usdcBalanceBefore + redeemShares);
    }
    
    function testRedeemInsufficientShares() public {
        vm.startPrank(user1);
        vm.expectRevert("Insufficient shares");
        vaultChainManager.crossChainRedeem(VAULT_ID, 1000);
        vm.stopPrank();
    }

    // ============ VALIDATION TESTS ============
    
    function testDepositZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert("Amount must be positive");
        vaultChainManager.crossChainDeposit(VAULT_ID, 0, address(usdc));
        vm.stopPrank();
    }
    
    function testDepositTokenNotAllowlisted() public {
        MockERC20 notAllowlisted = new MockERC20("BAD", "BAD", 18);
        
        vm.startPrank(user1);
        vm.expectRevert("Token not allowlisted");
        vaultChainManager.crossChainDeposit(VAULT_ID, 1000, address(notAllowlisted));
        vm.stopPrank();
    }
    
    function testDepositVaultChainNotSet() public {
        uint256 invalidVaultId = 999;
        
        vm.startPrank(user1);
        vm.expectRevert("Vault chain not set");
        userChainManager.crossChainDeposit(invalidVaultId, 1000e6, address(usdc));
        vm.stopPrank();
    }
    
    function testDepositVaultChainNotAllowlisted() public {
        // Set vault chain to non-allowlisted chain
        userChainManager.setVaultChain(VAULT_ID, 999);
        
        vm.startPrank(user1);
        vm.expectRevert("Vault chain not allowlisted");
        userChainManager.crossChainDeposit(VAULT_ID, 1000e6, address(usdc));
        vm.stopPrank();
    }
    
    function testRedeemZeroShares() public {
        vm.startPrank(user1);
        vm.expectRevert("Shares must be positive");
        vaultChainManager.crossChainRedeem(VAULT_ID, 0);
        vm.stopPrank();
    }

    // ============ CCIP MESSAGE HANDLING TESTS ============
    
    function testCcipReceiveDeposit() public {
        uint256 depositAmount = 1000e6;
        
        // Simulate CCIP message for deposit
        SimplifiedCrossChainManager.CrossChainMessage memory message = 
            SimplifiedCrossChainManager.CrossChainMessage({
                msgType: SimplifiedCrossChainManager.MessageType.DEPOSIT,
                vaultId: VAULT_ID,
                user: user1,
                amount: depositAmount,
                token: address(usdc)
            });
        
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(usdc),
            amount: depositAmount
        });
        
        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("test"),
            sourceChainSelector: USER_CHAIN_SELECTOR,
            sender: abi.encode(address(userChainManager)),
            data: abi.encode(message),
            destTokenAmounts: tokenAmounts
        });
        
        // Transfer USDC to vault chain manager to simulate CCIP transfer
        usdc.transfer(address(vaultChainManager), depositAmount);

        // Fund the vault manager with ETH for return CCIP message
        vm.deal(address(vaultChainManager), 1 ether);
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainDepositCompleted(user1, VAULT_ID, depositAmount, depositAmount);
        
        // Call _ccipReceive directly for testing
        vm.prank(address(router));
        vaultChainManager.ccipReceiveForTesting(ccipMessage);
    }
    
    function testCcipReceiveRedeem() public {
        // First credit some shares to user
        vm.prank(address(router));
        SimplifiedCrossChainManager.CrossChainMessage memory creditMessage = 
            SimplifiedCrossChainManager.CrossChainMessage({
                msgType: SimplifiedCrossChainManager.MessageType.SEND_TOKENS,
                vaultId: VAULT_ID,
                user: user1,
                amount: 1000e6,
                token: address(0)
            });
        
        Client.Any2EVMMessage memory creditCcipMessage = Client.Any2EVMMessage({
            messageId: keccak256("credit"),
            sourceChainSelector: VAULT_CHAIN_SELECTOR,
            sender: abi.encode(address(vaultChainManager)),
            data: abi.encode(creditMessage),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        
        userChainManager.ccipReceiveForTesting(creditCcipMessage);
        
        // Now test redeem
        uint256 redeemShares = 500e6;
        
        SimplifiedCrossChainManager.CrossChainMessage memory redeemMessage = 
            SimplifiedCrossChainManager.CrossChainMessage({
                msgType: SimplifiedCrossChainManager.MessageType.REDEEM,
                vaultId: VAULT_ID,
                user: user1,
                amount: redeemShares,
                token: address(0)
            });
        
        Client.Any2EVMMessage memory redeemCcipMessage = Client.Any2EVMMessage({
            messageId: keccak256("redeem"),
            sourceChainSelector: USER_CHAIN_SELECTOR,
            sender: abi.encode(address(userChainManager)),
            data: abi.encode(redeemMessage),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainRedeemCompleted(user1, VAULT_ID, redeemShares, redeemShares);
        
        vm.prank(address(router));
        vaultChainManager.ccipReceiveForTesting(redeemCcipMessage);
    }
    
    function testCcipReceiveDuplicateMessage() public {
        bytes32 messageId = keccak256("duplicate");
        
        SimplifiedCrossChainManager.CrossChainMessage memory message = 
            SimplifiedCrossChainManager.CrossChainMessage({
                msgType: SimplifiedCrossChainManager.MessageType.SEND_TOKENS,
                vaultId: VAULT_ID,
                user: user1,
                amount: 1000,
                token: address(0)
            });
        
        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: USER_CHAIN_SELECTOR,
            sender: abi.encode(address(userChainManager)),
            data: abi.encode(message),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        
        // First call should work
        vm.prank(address(router));
        vaultChainManager.ccipReceive(ccipMessage);
        
        // Second call should revert
        vm.prank(address(router));
        vm.expectRevert("Message already processed");
        vaultChainManager.ccipReceive(ccipMessage);
    }

    // ============ VIEW FUNCTION TESTS ============
    
    function testGetUserVaultBalance() public {
        assertEq(vaultChainManager.getUserVaultBalance(VAULT_ID, user1), 0);
        
        // Deposit and check balance
        uint256 depositAmount = 1000e6;
        vm.startPrank(user1);
        usdc.approve(address(vaultChainManager), depositAmount);
        vaultChainManager.crossChainDeposit(VAULT_ID, depositAmount, address(usdc));
        vm.stopPrank();
        
        assertEq(vaultChainManager.getUserVaultBalance(VAULT_ID, user1), depositAmount);
    }
    
    function testGetCrossChainFee() public {
        uint256 fee = userChainManager.getCrossChainFee(
            VAULT_CHAIN_SELECTOR,
            VAULT_ID,
            1000e6,
            address(usdc)
        );
        
        assertEq(fee, router.MOCK_FEE());
    }

    // ============ OWNER FUNCTION TESTS ============
    
    function testDepositRWATokens() public {
        uint256 depositAmount = 1000e18;
        
        rwa1.approve(address(vaultChainManager), depositAmount);
        vaultChainManager.depositRWATokens(address(rwa1), depositAmount);
        
        assertEq(rwa1.balanceOf(address(vaultChainManager)), 1000e18 + depositAmount);
    }
    
    function testWithdrawRWATokens() public {
        uint256 withdrawAmount = 500e18;
        uint256 balanceBefore = rwa1.balanceOf(owner);
        
        vaultChainManager.withdrawRWATokens(address(rwa1), withdrawAmount);
        
        assertEq(rwa1.balanceOf(owner), balanceBefore + withdrawAmount);
        assertEq(rwa1.balanceOf(address(vaultChainManager)), 1000e18 - withdrawAmount);
    }
    
    function testEmergencyWithdraw() public {
        uint256 managerBalance = usdc.balanceOf(address(vaultChainManager));
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);
        
        vaultChainManager.emergencyWithdraw(address(usdc));
        
        assertEq(usdc.balanceOf(address(vaultChainManager)), 0);
        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + managerBalance);
    }
    
    function testOnlyOwnerFunctions() public {
        vm.startPrank(user1);
        
        vm.expectRevert("Only callable by owner"); // Change these lines
        vaultChainManager.depositRWATokens(address(rwa1), 1000);
        
        vm.expectRevert("Only callable by owner");
        vaultChainManager.withdrawRWATokens(address(rwa1), 1000);
        
        vm.expectRevert("Only callable by owner");
        vaultChainManager.emergencyWithdraw(address(usdc));
        
        vm.stopPrank();
    }

    // ============ MODIFIER TESTS ============
    
    function testOnlyVaultChainModifier() public {
        // This should work on vault chain
        vm.startPrank(user1);
        usdc.approve(address(vaultChainManager), 1000e6);
        vaultChainManager.crossChainDeposit(VAULT_ID, 1000e6, address(usdc));
        vm.stopPrank();
        
        // Direct deposit should fail on user chain (if we could call it)
        // Note: _directDeposit is internal, so we can't test this directly
        // This is tested implicitly through cross-chain scenarios
    }

    // ============ EDGE CASE TESTS ============
    
    function testFeeRefund() public {
        uint256 extraFee = 0.1 ether;
        uint256 totalFee = router.MOCK_FEE() + extraFee;
        
        vm.startPrank(user1);
        usdc.approve(address(userChainManager), 1000e6);
        
        uint256 balanceBefore = user1.balance;
        
        userChainManager.crossChainDeposit{value: totalFee}(
            VAULT_ID,
            1000e6,
            address(usdc)
        );
        
        // Should refund extra fee
        assertEq(user1.balance, balanceBefore - router.MOCK_FEE());
        vm.stopPrank();
    }
    
    function testReceiveFunction() public {
        // Test that contract can receive ETH
        uint256 balanceBefore = address(vaultChainManager).balance;
        
        vm.prank(user1);
        (bool success,) = address(vaultChainManager).call{value: 1 ether}("");
        
        assertTrue(success);
        assertEq(address(vaultChainManager).balance, balanceBefore + 1 ether);
    }

    // ============ INTEGRATION TESTS ============
    
    function testFullCrossChainFlow() public {
        uint256 depositAmount = 1000e6;
        
        // 1. User deposits on user chain
        vm.startPrank(user1);
        usdc.approve(address(userChainManager), depositAmount);
        
        userChainManager.crossChainDeposit{value: router.MOCK_FEE()}(
            VAULT_ID,
            depositAmount,
            address(usdc)
        );
        vm.stopPrank();
        
        // 2. Simulate CCIP message processing on vault chain
        SimplifiedCrossChainManager.CrossChainMessage memory message = 
            SimplifiedCrossChainManager.CrossChainMessage({
                msgType: SimplifiedCrossChainManager.MessageType.DEPOSIT,
                vaultId: VAULT_ID,
                user: user1,
                amount: depositAmount,
                token: address(usdc)
            });
        
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(usdc),
            amount: depositAmount
        });
        
        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("deposit"),
            sourceChainSelector: USER_CHAIN_SELECTOR,
            sender: abi.encode(address(userChainManager)),
            data: abi.encode(message),
            destTokenAmounts: tokenAmounts
        });
        
        // Transfer USDC to simulate CCIP
        usdc.transfer(address(vaultChainManager), depositAmount);
        
        vm.prank(address(router));
        vaultChainManager.ccipReceive(ccipMessage);
        
        // 3. Simulate shares crediting back to user chain
        SimplifiedCrossChainManager.CrossChainMessage memory creditMessage = 
            SimplifiedCrossChainManager.CrossChainMessage({
                msgType: SimplifiedCrossChainManager.MessageType.SEND_TOKENS,
                vaultId: VAULT_ID,
                user: user1,
                amount: depositAmount,
                token: address(0)
            });
        
        Client.Any2EVMMessage memory creditCcipMessage = Client.Any2EVMMessage({
            messageId: keccak256("credit"),
            sourceChainSelector: VAULT_CHAIN_SELECTOR,
            sender: abi.encode(address(vaultChainManager)),
            data: abi.encode(creditMessage),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        
        vm.prank(address(router));
        userChainManager.ccipReceive(creditCcipMessage);
        
        // Verify final state
        assertEq(userChainManager.getUserVaultBalance(VAULT_ID, user1), depositAmount);
        assertEq(vaultToken.balanceOf(address(vaultChainManager)), depositAmount);
    }
}