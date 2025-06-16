// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouterClient} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./RWAVault.sol";

contract SimplifiedCrossChainManager is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    enum MessageType { DEPOSIT, REDEEM, SEND_TOKENS }
    
    struct CrossChainMessage {
        MessageType msgType;
        uint256 vaultId;
        address user;
        uint256 amount;
        address token;
    }

    // Core contracts (only on vault chain)
    RWAVault public vault; // Not immutable since it might be zero on non-vault chains
    IRouterClient private immutable router;
    
    // Chain configuration
    mapping(uint64 => bool) public allowlistedChains;
    mapping(uint64 => address) public crossChainManagers; // Manager contracts on other chains
    mapping(address => bool) public allowlistedTokens;
    
    // Track user vault shares (vaultId => user => shares)
    mapping(uint256 => mapping(address => uint256)) public userVaultShares;
    
    // Track which chain hosts each vault
    mapping(uint256 => uint64) public vaultChains;
    uint64 public immutable thisChain;
    bool public immutable isVaultChain;
    
    // Message tracking
    mapping(bytes32 => bool) public processedMessages;
    
    // Gas limits
    uint256 public constant GAS_LIMIT_DEPOSIT = 500_000;
    uint256 public constant GAS_LIMIT_REDEEM = 800_000;
    uint256 public constant GAS_LIMIT_SEND_TOKENS = 200_000;

    event CrossChainDepositInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChain,
        address indexed user,
        uint256 vaultId,
        uint256 amount
    );
    
    event CrossChainRedeemInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChain,
        address indexed user,
        uint256 vaultId,
        uint256 shares
    );
    
    event CrossChainDepositCompleted(
        address indexed user,
        uint256 indexed vaultId,
        uint256 amount,
        uint256 shares
    );
    
    event CrossChainRedeemCompleted(
        address indexed user,
        uint256 indexed vaultId,
        uint256 shares,
        uint256 baseAmount
    );

    event SharesCredited(
        address indexed user,
        uint256 indexed vaultId,
        uint256 shares
    );

    event TokensSent(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint64 destinationChain
    );

    constructor(
        address _router,
        address _vault, // Will be address(0) on non-vault chains
        uint64 _thisChain,
        bool _isVaultChain
    ) CCIPReceiver(_router) {
        router = IRouterClient(_router);
        vault = RWAVault(_vault);
        thisChain = _thisChain;
        isVaultChain = _isVaultChain;
    }

    modifier onlyAllowlistedChain(uint64 _chainSelector) {
        require(allowlistedChains[_chainSelector], "Chain not allowlisted");
        _;
    }

    modifier onlyVaultChain() {
        require(isVaultChain, "Only vault chain can perform this action");
        _;
    }

    // ============ ADMIN FUNCTIONS ============
    
    function allowlistChain(
        uint64 _chainSelector,
        address _crossChainManager,
        bool _allowed
    ) external onlyOwner {
        allowlistedChains[_chainSelector] = _allowed;
        crossChainManagers[_chainSelector] = _crossChainManager;
    }
    
    function allowlistToken(address _token, bool _allowed) external onlyOwner {
        allowlistedTokens[_token] = _allowed;
    }

    function setVaultChain(uint256 _vaultId, uint64 _chainSelector) external onlyOwner {
        vaultChains[_vaultId] = _chainSelector;
    }

    // ============ CROSS-CHAIN DEPOSIT ============
    
    function crossChainDeposit(
        uint256 vaultId,
        uint256 baseAmount,
        address baseToken
    ) external payable {
        require(allowlistedTokens[baseToken], "Token not allowlisted");
        require(baseAmount > 0, "Amount must be positive");
        
        uint64 vaultChain = vaultChains[vaultId];
        require(vaultChain != 0, "Vault chain not set");
        require(allowlistedChains[vaultChain], "Vault chain not allowlisted");

        if (vaultChain == thisChain) {
            // Direct deposit on same chain
            _directDeposit(vaultId, baseAmount, baseToken, msg.sender);
        } else {
            // Cross-chain deposit
            // Transfer base token from user
            IERC20(baseToken).safeTransferFrom(msg.sender, address(this), baseAmount);
            
            // Prepare CCIP message
            CrossChainMessage memory message = CrossChainMessage({
                msgType: MessageType.DEPOSIT,
                vaultId: vaultId,
                user: msg.sender,
                amount: baseAmount,
                token: baseToken
            });
            
            bytes memory encodedMessage = abi.encode(message);
            
            // Send to vault chain
            bytes32 messageId = _sendCCIPMessage(
                vaultChain,
                encodedMessage,
                baseToken,
                baseAmount,
                GAS_LIMIT_DEPOSIT
            );
            
            emit CrossChainDepositInitiated(
                messageId,
                vaultChain,
                msg.sender,
                vaultId,
                baseAmount
            );
        }
    }

    // ============ CROSS-CHAIN REDEEM ============
    
    function crossChainRedeem(
        uint256 vaultId,
        uint256 shares
    ) external payable {
        require(shares > 0, "Shares must be positive");
        require(userVaultShares[vaultId][msg.sender] >= shares, "Insufficient shares");
        
        uint64 vaultChain = vaultChains[vaultId];
        require(vaultChain != 0, "Vault chain not set");
        require(allowlistedChains[vaultChain], "Vault chain not allowlisted");

        // Deduct shares from user's balance
        userVaultShares[vaultId][msg.sender] -= shares;

        if (vaultChain == thisChain) {
            // Direct redeem on same chain
            _directRedeem(vaultId, shares, msg.sender);
        } else {
            // Cross-chain redeem
            // Prepare CCIP message
            CrossChainMessage memory message = CrossChainMessage({
                msgType: MessageType.REDEEM,
                vaultId: vaultId,
                user: msg.sender,
                amount: shares,
                token: address(0) // Not needed for redeem
            });
            
            bytes memory encodedMessage = abi.encode(message);
            
            // Send to vault chain
            bytes32 messageId = _sendCCIPMessage(
                vaultChain,
                encodedMessage,
                address(0), // No token transfer for redeem
                0,
                GAS_LIMIT_REDEEM
            );
            
            emit CrossChainRedeemInitiated(
                messageId,
                vaultChain,
                msg.sender,
                vaultId,
                shares
            );
        }
    }

    // ============ DIRECT OPERATIONS (SAME CHAIN) ============

    function _directDeposit(
        uint256 vaultId,
        uint256 baseAmount,
        address baseToken,
        address user
    ) internal onlyVaultChain {
        // Transfer base token from user
        IERC20(baseToken).safeTransferFrom(user, address(this), baseAmount);

        // Get vault details
        (address vaultToken, , , address baseCurrency, ) = vault.getVaultDetails(vaultId);
        require(baseToken == baseCurrency, "Wrong base currency");

        // Calculate required RWAs
        (address[] memory assets, uint256[] memory amounts) = 
            vault.calculateRequiredRWAs(vaultId, baseAmount);

        // Check if we have enough RWAs
        bool hasEnoughRWAs = true;
        for (uint i = 0; i < assets.length; i++) {
            if (amounts[i] > IERC20(assets[i]).balanceOf(address(this))) {
                hasEnoughRWAs = false;
                break;
            }
        }

        require(hasEnoughRWAs, "Insufficient RWA tokens in manager");

        // Approve vault to spend tokens
        IERC20(baseCurrency).approve(address(vault), baseAmount);
        for (uint i = 0; i < assets.length; i++) {
            if (amounts[i] > 0) {
                IERC20(assets[i]).approve(address(vault), amounts[i]);
            }
        }

        // Deposit to vault
        vault.deposit(vaultId, baseAmount);

        // Get minted shares
        uint256 shares = IERC20(vaultToken).balanceOf(address(this));

        // Credit user's shares
        userVaultShares[vaultId][user] += shares;

        emit CrossChainDepositCompleted(user, vaultId, baseAmount, shares);
        emit SharesCredited(user, vaultId, shares);
    }

    function _directRedeem(
        uint256 vaultId,
        uint256 shares,
        address user
    ) internal onlyVaultChain {
        // Redeem from vault
        vault.redeem(vaultId, shares);

        // Get vault base currency
        (, , , address baseCurrency, ) = vault.getVaultDetails(vaultId);

        // Send base currency directly to user
        uint256 baseAmount = IERC20(baseCurrency).balanceOf(address(this));
        if (baseAmount > 0) {
            IERC20(baseCurrency).safeTransfer(user, baseAmount);
        }

        emit CrossChainRedeemCompleted(user, vaultId, shares, baseAmount);
    }

    // ============ CCIP MESSAGE HANDLING ============
    
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        bytes32 messageId = any2EvmMessage.messageId;
        require(!processedMessages[messageId], "Message already processed");
        processedMessages[messageId] = true;
        
        CrossChainMessage memory message = abi.decode(
            any2EvmMessage.data,
            (CrossChainMessage)
        );
        
        if (message.msgType == MessageType.DEPOSIT) {
            _handleCrossChainDeposit(message, any2EvmMessage);
        } else if (message.msgType == MessageType.REDEEM) {
            _handleCrossChainRedeem(message, any2EvmMessage);
        } else if (message.msgType == MessageType.SEND_TOKENS) {
            _handleTokenSend(message, any2EvmMessage);
        }
    }
    
    function _handleCrossChainDeposit(
        CrossChainMessage memory message,
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal onlyVaultChain {
        // Get received tokens from CCIP
        require(any2EvmMessage.destTokenAmounts.length > 0, "No tokens received");
        
        address receivedToken = any2EvmMessage.destTokenAmounts[0].token;
        uint256 receivedAmount = any2EvmMessage.destTokenAmounts[0].amount;
        
        // Get vault details
        (address vaultToken, , , address baseCurrency, ) = 
            vault.getVaultDetails(message.vaultId);
        
        require(receivedToken == baseCurrency, "Wrong base currency");
        
        // Calculate required RWAs
        (address[] memory assets, uint256[] memory amounts) = 
            vault.calculateRequiredRWAs(message.vaultId, receivedAmount);
        
        // Check if we have enough RWAs in this contract
        bool hasEnoughRWAs = true;
        for (uint i = 0; i < assets.length; i++) {
            if (amounts[i] > IERC20(assets[i]).balanceOf(address(this))) {
                hasEnoughRWAs = false;
                break;
            }
        }
        
        if (hasEnoughRWAs) {
            // Approve vault to spend tokens
            IERC20(baseCurrency).approve(address(vault), receivedAmount);
            for (uint i = 0; i < assets.length; i++) {
                if (amounts[i] > 0) {
                    IERC20(assets[i]).approve(address(vault), amounts[i]);
                }
            }
            
            // Deposit to vault
            vault.deposit(message.vaultId, receivedAmount);
            
            // Get minted shares
            uint256 shares = IERC20(vaultToken).balanceOf(address(this));
            
            // Credit shares to user on their chain
            _creditSharesToUser(message.user, message.vaultId, shares, any2EvmMessage.sourceChainSelector);
            
            emit CrossChainDepositCompleted(message.user, message.vaultId, receivedAmount, shares);
        } else {
            // Return base currency to user if we can't complete deposit
            _sendTokensToUser(message.user, receivedToken, receivedAmount, any2EvmMessage.sourceChainSelector);
        }
    }
    
    function _handleCrossChainRedeem(
        CrossChainMessage memory message,
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal onlyVaultChain {
        // Redeem from vault
        vault.redeem(message.vaultId, message.amount);
        
        // Get vault base currency
        (, , , address baseCurrency, ) = vault.getVaultDetails(message.vaultId);
        
        // Get redeemed amount
        uint256 baseAmount = IERC20(baseCurrency).balanceOf(address(this));
        
        // Send base currency back to user on their chain
        if (baseAmount > 0) {
            _sendTokensToUser(message.user, baseCurrency, baseAmount, any2EvmMessage.sourceChainSelector);
        }
        
        emit CrossChainRedeemCompleted(message.user, message.vaultId, message.amount, baseAmount);
    }

    function _handleTokenSend(
        CrossChainMessage memory message,
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal {
        if (message.msgType == MessageType.SEND_TOKENS) {
            // Credit shares to user
            userVaultShares[message.vaultId][message.user] += message.amount;
            emit SharesCredited(message.user, message.vaultId, message.amount);
        }
    }

    // ============ HELPER FUNCTIONS ============
    
    function _creditSharesToUser(
        address user,
        uint256 vaultId,
        uint256 shares,
        uint64 userChain
    ) internal {
        if (userChain == thisChain) {
            // Same chain - credit directly
            userVaultShares[vaultId][user] += shares;
            emit SharesCredited(user, vaultId, shares);
        } else {
            // Different chain - send CCIP message
            CrossChainMessage memory creditMessage = CrossChainMessage({
                msgType: MessageType.SEND_TOKENS,
                vaultId: vaultId,
                user: user,
                amount: shares,
                token: address(0)
            });
            
            bytes memory encodedMessage = abi.encode(creditMessage);
            
            _sendCCIPMessage(
                userChain,
                encodedMessage,
                address(0),
                0,
                GAS_LIMIT_SEND_TOKENS
            );
        }
    }
    
    function _sendTokensToUser(
        address user,
        address token,
        uint256 amount,
        uint64 userChain
    ) internal {
        if (userChain == thisChain) {
            // Same chain - transfer directly
            IERC20(token).safeTransfer(user, amount);
        } else {
            // Different chain - send via CCIP
            CrossChainMessage memory tokenMessage = CrossChainMessage({
                msgType: MessageType.SEND_TOKENS,
                vaultId: 0, // Not used for token sends
                user: user,
                amount: amount,
                token: token
            });
            
            bytes memory encodedMessage = abi.encode(tokenMessage);
            
            _sendCCIPMessage(
                userChain,
                encodedMessage,
                token,
                amount,
                GAS_LIMIT_SEND_TOKENS
            );
            
            emit TokensSent(user, token, amount, userChain);
        }
    }
    
    function _sendCCIPMessage(
        uint64 destinationChain,
        bytes memory data,
        address token,
        uint256 amount,
        uint256 gasLimit
    ) internal returns (bytes32 messageId) {
        Client.EVM2AnyMessage memory evm2AnyMessage;
        
        if (token != address(0) && amount > 0) {
            // Include token transfer
            Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({
                token: token,
                amount: amount
            });
            
            evm2AnyMessage = Client.EVM2AnyMessage({
                receiver: abi.encode(crossChainManagers[destinationChain]),
                data: data,
                tokenAmounts: tokenAmounts,
                extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
                feeToken: address(0) // Pay in native token
            });
            
            // Approve router to spend tokens
            IERC20(token).approve(address(router), amount);
        } else {
            // Message only
            evm2AnyMessage = Client.EVM2AnyMessage({
                receiver: abi.encode(crossChainManagers[destinationChain]),
                data: data,
                tokenAmounts: new Client.EVMTokenAmount[](0),
                extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
                feeToken: address(0) // Pay in native token
            });
        }
        
        uint256 fees = router.getFee(destinationChain, evm2AnyMessage);
        require(msg.value >= fees, "Insufficient fee");
        
        messageId = router.ccipSend{value: fees}(destinationChain, evm2AnyMessage);
        
        // Refund excess fee
        if (msg.value > fees) {
            payable(msg.sender).transfer(msg.value - fees);
        }
        
        return messageId;
    }

    // ============ VIEW FUNCTIONS ============
    
    function getUserVaultBalance(uint256 vaultId, address user) external view returns (uint256) {
        return userVaultShares[vaultId][user];
    }

    function getTotalVaultShares(uint256 vaultId) external view returns (uint256 total) {
        // Note: This only returns shares tracked on this chain
        // For complete picture, you'd need to query all chains
        return userVaultShares[vaultId][address(0)]; // Use as total tracker if implemented
    }
    
    function getCrossChainFee(
        uint64 destinationChain,
        uint256 vaultId,
        uint256 amount,
        address token
    ) external view returns (uint256 fee) {
        CrossChainMessage memory message = CrossChainMessage({
            msgType: MessageType.DEPOSIT,
            vaultId: vaultId,
            user: msg.sender,
            amount: amount,
            token: token
        });
        
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(crossChainManagers[destinationChain]),
            data: abi.encode(message),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: GAS_LIMIT_DEPOSIT})),
            feeToken: address(0)
        });
        
        return router.getFee(destinationChain, evm2AnyMessage);
    }

    // ============ OWNER FUNCTIONS FOR RWA MANAGEMENT ============
    
    function depositRWATokens(
        address token,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
    
    function withdrawRWATokens(
        address token,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    
    // Emergency functions
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner(), balance);
    }
    
    receive() external payable {}
}