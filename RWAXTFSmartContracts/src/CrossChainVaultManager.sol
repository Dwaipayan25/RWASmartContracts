// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouterClient} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./RWAVault.sol";
import "./VaultToken.sol";

contract CrossChainVaultManager is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    enum MessageType { DEPOSIT, REDEEM }
    
    struct CrossChainMessage {
        MessageType msgType;
        uint256 vaultId;
        address user;
        uint256 amount;
        address token;
    }

    // Core contracts
    RWAVault public immutable vault;
    IRouterClient private immutable router;
    
    // Chain configuration
    mapping(uint64 => bool) public allowlistedChains;
    mapping(uint64 => address) public crossChainManagers; // Manager contracts on other chains
    mapping(address => bool) public allowlistedTokens;
    
    // Cross-chain vault tokens (deployed on each supported chain)
    mapping(uint256 => mapping(uint64 => address)) public crossChainVaultTokens; // vaultId => chainSelector => tokenAddress
    
    // Message tracking
    mapping(bytes32 => bool) public processedMessages;
    
    // Gas limits
    uint256 public constant GAS_LIMIT_DEPOSIT = 500_000;
    uint256 public constant GAS_LIMIT_REDEEM = 800_000;

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

    constructor(
        address _router,
        address _vault
    ) CCIPReceiver(_router) {
        router = IRouterClient(_router);
        vault = RWAVault(_vault);
    }

    modifier onlyAllowlistedChain(uint64 _chainSelector) {
        require(allowlistedChains[_chainSelector], "Chain not allowlisted");
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
    
    function setCrossChainVaultToken(
        uint256 _vaultId,
        uint64 _chainSelector,
        address _tokenAddress
    ) external onlyOwner {
        crossChainVaultTokens[_vaultId][_chainSelector] = _tokenAddress;
    }

    // ============ CROSS-CHAIN DEPOSIT ============
    
    function crossChainDeposit(
        uint256 vaultId,
        uint256 baseAmount,
        uint64 destinationChain,
        address baseToken
    ) external payable onlyAllowlistedChain(destinationChain) {
        require(allowlistedTokens[baseToken], "Token not allowlisted");
        require(baseAmount > 0, "Amount must be positive");
        
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
        
        // Send to destination chain
        bytes32 messageId = _sendCCIPMessage(
            destinationChain,
            encodedMessage,
            baseToken,
            baseAmount,
            GAS_LIMIT_DEPOSIT
        );
        
        emit CrossChainDepositInitiated(
            messageId,
            destinationChain,
            msg.sender,
            vaultId,
            baseAmount
        );
    }

    // ============ CROSS-CHAIN REDEEM ============
    
    function crossChainRedeem(
        uint256 vaultId,
        uint256 shares,
        uint64 destinationChain
    ) external payable onlyAllowlistedChain(destinationChain) {
        require(shares > 0, "Shares must be positive");
        
        // Get cross-chain vault token for this chain
        address crossChainToken = crossChainVaultTokens[vaultId][uint64(block.chainid)];
        require(crossChainToken != address(0), "Cross-chain token not set");
        
        // Burn user's vault tokens on this chain
        VaultToken(crossChainToken).burn(msg.sender, shares);
        
        // Prepare CCIP message
        CrossChainMessage memory message = CrossChainMessage({
            msgType: MessageType.REDEEM,
            vaultId: vaultId,
            user: msg.sender,
            amount: shares,
            token: address(0) // Not needed for redeem
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Send to destination chain (vault chain)
        bytes32 messageId = _sendCCIPMessage(
            destinationChain,
            encodedMessage,
            address(0), // No token transfer for redeem
            0,
            GAS_LIMIT_REDEEM
        );
        
        emit CrossChainRedeemInitiated(
            messageId,
            destinationChain,
            msg.sender,
            vaultId,
            shares
        );
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
        }
    }
    
    function _handleCrossChainDeposit(
        CrossChainMessage memory message,
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal {
        // Get received tokens from CCIP
        require(any2EvmMessage.destTokenAmounts.length > 0, "No tokens received");
        
        address receivedToken = any2EvmMessage.destTokenAmounts[0].token;
        uint256 receivedAmount = any2EvmMessage.destTokenAmounts[0].amount;
        
        // Get vault details
        (address vaultToken, address[] memory rwaAssets, , address baseCurrency, ) = 
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
            
            // Send vault tokens to user on their chain
            _sendVaultTokensToUser(message.user, message.vaultId, shares, any2EvmMessage.sourceChainSelector);
            
            emit CrossChainDepositCompleted(message.user, message.vaultId, receivedAmount, shares);
        } else {
            // Return base currency to user if we can't complete deposit
            _sendTokensToUser(message.user, receivedToken, receivedAmount, any2EvmMessage.sourceChainSelector);
        }
    }
    
    function _handleCrossChainRedeem(
        CrossChainMessage memory message,
        Client.Any2EVMMessage memory
    ) internal {
        // Redeem from vault
        vault.redeem(message.vaultId, message.amount);
        
        // Get vault base currency
        (, , , address baseCurrency, ) = vault.getVaultDetails(message.vaultId);
        
        // Calculate base currency received (simplified - in practice you'd track this)
        uint256 baseAmount = IERC20(baseCurrency).balanceOf(address(this));
        
        // Send base currency back to user
        // _sendTokensToUser(message.user, baseCurrency, baseAmount, any2EvmMessage.sourceChainSelector);
        
        emit CrossChainRedeemCompleted(message.user, message.vaultId, message.amount, baseAmount);
    }

    // ============ HELPER FUNCTIONS ============
    
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
    
    function _sendVaultTokensToUser(
        address user,
        uint256 vaultId,
        uint256 shares,
        uint64 userChain
    ) internal {
        // Get cross-chain vault token address
        address crossChainToken = crossChainVaultTokens[vaultId][userChain];
        
        if (crossChainToken != address(0)) {
            // Mint tokens on user's chain (would need cross-chain call)
            // This is simplified - you'd need to send another CCIP message
            VaultToken(crossChainToken).mint(user, shares);
        }
    }
    
    function _sendTokensToUser(
        address user,
        address token,
        uint256 amount,
        uint64 userChain
    ) internal {
        // Send tokens back to user's chain
        // Implementation would depend on your cross-chain token bridge
    }

    // ============ VIEW FUNCTIONS ============
    
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
    
    // Emergency functions
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner(), balance);
    }
    
    receive() external payable {}
}