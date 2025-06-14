// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink-ccip/applications/CCIPReceiver.sol";
import "@chainlink-ccip/interfaces/IRouterClient.sol";
import "@chainlink/contracts/v0.8/shared/access/OwnerIsCreator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CrossChainManager
 * @dev Handles cross-chain deposits and redemptions via Chainlink CCIP
 */
contract CrossChainManager is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;
    
    // Vault registry
    mapping(uint64 => address) public remoteVaults;  // chainSelector => vault address
    mapping(uint64 => address) private linkTokenAddresses;
    address public localVault;
    
    // CCIP fees can be paid in LINK or native token
    enum PayFeesIn {
        Native,
        LINK
    }
    
    // Message types
    enum MessageType {
        Deposit,
        Redemption,
        RebalanceSignal
    }
    
    // Message structure
    struct CrossChainMessage {
        MessageType msgType;
        address sender;
        bytes payload;
    }
    
    // Events
    event MessageSent(uint64 indexed destinationChainSelector, bytes32 messageId);
    event MessageReceived(uint64 indexed sourceChainSelector, address sender, MessageType msgType);
    event DepositInitiated(address indexed sender, uint64 indexed destinationChain, address[] tokens, uint256[] amounts);
    event RedemptionInitiated(address indexed sender, uint64 indexed destinationChain, uint256 etfAmount);
    
    constructor(address router, address _localVault) CCIPReceiver(router) {
        localVault = _localVault;
    }
    
    /**
     * @dev Update local vault address
     */
    function setLocalVault(address _localVault) external onlyOwner {
        require(_localVault != address(0), "Invalid vault address");
        localVault = _localVault;
    }
    
    /**
     * @dev Add a remote vault on another chain
     */
    function addRemoteVault(uint64 chainSelector, address vaultAddress) external onlyOwner {
        require(chainSelector != 0, "Invalid chain selector");
        require(vaultAddress != address(0), "Invalid vault address");
        remoteVaults[chainSelector] = vaultAddress;
    }

    function setLinkTokenAddress(uint64 chainSelector, address linkToken) external onlyOwner {
        linkTokenAddresses[chainSelector] = linkToken;
    }
    
    /**
     * @dev Remove a remote vault
     */
    function removeRemoteVault(uint64 chainSelector) external onlyOwner {
        delete remoteVaults[chainSelector];
    }
    
    /**
     * @dev Initiate a cross-chain deposit
     */
    function depositCrossChain(
        uint64 destinationChainSelector,
        address[] calldata tokens,
        uint256[] calldata amounts,
        PayFeesIn payFeesIn
    ) external payable {
        require(tokens.length == amounts.length, "Arrays length mismatch");
        require(tokens.length > 0, "No tokens specified");
        require(remoteVaults[destinationChainSelector] != address(0), "Remote vault not registered");
        
        // Transfer tokens from sender to this contract
        for (uint256 i = 0; i < tokens.length; i++) {
            require(amounts[i] > 0, "Amount must be greater than 0");
            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            
            // Approve router to spend tokens
            IERC20(tokens[i]).approve(getRouter(), amounts[i]);
        }
        
        // Prepare token transfers for CCIP
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenAmounts[i] = Client.EVMTokenAmount({
                token: tokens[i],
                amount: amounts[i]
            });
        }
        
        // Encode deposit data
        bytes memory depositData = abi.encode(tokens, amounts);
        
        // Prepare CCIP message
        CrossChainMessage memory message = CrossChainMessage({
            msgType: MessageType.Deposit,
            sender: msg.sender,
            payload: depositData
        });
        
        // Encode the message
        bytes memory ccipMessage = abi.encode(message);
        
        // Build CCIP message with tokens
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(remoteVaults[destinationChainSelector]),
            data: ccipMessage,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300_000})
            ),
            feeToken: payFeesIn == PayFeesIn.LINK ? linkTokenAddresses[destinationChainSelector] : address(0)
        });
        
        // Calculate fee
        uint256 fee = IRouterClient(getRouter()).getFee(
            destinationChainSelector,
            evm2AnyMessage
        );
        
        // Send message
        bytes32 messageId;
        if (payFeesIn == PayFeesIn.LINK) {
            // Pay with LINK
            IERC20 linkToken = IERC20(linkTokenAddresses[destinationChainSelector]);
            linkToken.safeTransferFrom(msg.sender, address(this), fee);
            linkToken.approve(getRouter(), fee);
            
            messageId = IRouterClient(getRouter()).ccipSend(
                destinationChainSelector,
                evm2AnyMessage
            );
        } else {
            // Pay with native token
            require(msg.value >= fee, "Insufficient fee");
            
            messageId = IRouterClient(getRouter()).ccipSend{value: fee}(
                destinationChainSelector,
                evm2AnyMessage
            );
            
            // Refund excess payment
            if (msg.value > fee) {
                (bool success, ) = msg.sender.call{value: msg.value - fee}("");
                require(success, "Refund failed");
            }
        }
        
        emit MessageSent(destinationChainSelector, messageId);
        emit DepositInitiated(msg.sender, destinationChainSelector, tokens, amounts);
    }
    
    /**
     * @dev Initiate a cross-chain redemption
     */
    function redeemCrossChain(
        uint64 destinationChainSelector,
        uint256 etfAmount,
        PayFeesIn payFeesIn
    ) external payable {
        require(etfAmount > 0, "Amount must be greater than 0");
        require(remoteVaults[destinationChainSelector] != address(0), "Remote vault not registered");
        
        // Transfer ETF tokens from sender to this contract
        IERC20 etfToken = IERC20(vaultToToken(localVault));
        etfToken.safeTransferFrom(msg.sender, address(this), etfAmount);
        
        // Encode redemption data
        bytes memory redemptionData = abi.encode(etfAmount);
        
        // Prepare CCIP message
        CrossChainMessage memory message = CrossChainMessage({
            msgType: MessageType.Redemption,
            sender: msg.sender,
            payload: redemptionData
        });
        
        // Encode message
        bytes memory ccipMessage = abi.encode(message);
        
        // Prepare token transfer if needed (ETF token)
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(etfToken),
            amount: etfAmount
        });
        
        // Approve router to spend ETF tokens
        etfToken.approve(getRouter(), etfAmount);
        
        // Build CCIP message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(remoteVaults[destinationChainSelector]),
            data: ccipMessage,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300_000})
            ),
            feeToken: payFeesIn == PayFeesIn.LINK ? linkTokenAddresses[destinationChainSelector] : address(0)
        });
        
        // Calculate fee
        uint256 fee = IRouterClient(getRouter()).getFee(
            destinationChainSelector,
            evm2AnyMessage
        );
        
        // Send message
        bytes32 messageId;
        if (payFeesIn == PayFeesIn.LINK) {
            // Pay with LINK
            IERC20 linkToken = IERC20(linkTokenAddresses[destinationChainSelector]);
            linkToken.safeTransferFrom(msg.sender, address(this), fee);
            linkToken.approve(getRouter(), fee);
            
            messageId = IRouterClient(getRouter()).ccipSend(
                destinationChainSelector,
                evm2AnyMessage
            );
        } else {
            // Pay with native token
            require(msg.value >= fee, "Insufficient fee");
            
            messageId = IRouterClient(getRouter()).ccipSend{value: fee}(
                destinationChainSelector,
                evm2AnyMessage
            );
            
            // Refund excess payment
            if (msg.value > fee) {
                (bool success, ) = msg.sender.call{value: msg.value - fee}("");
                require(success, "Refund failed");
            }
        }
        
        emit MessageSent(destinationChainSelector, messageId);
        emit RedemptionInitiated(msg.sender, destinationChainSelector, etfAmount);
    }
    
    /**
     * @dev CCIP message handler
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        // Decode the message
        CrossChainMessage memory ccMessage = abi.decode(message.data, (CrossChainMessage));
        
        // Process based on message type
        if (ccMessage.msgType == MessageType.Deposit) {
            // Forward any received tokens to the local vault
            for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
                IERC20(message.destTokenAmounts[i].token).safeTransfer(
                    localVault, 
                    message.destTokenAmounts[i].amount
                );
            }
            
            // Call the local vault's processCrossChainDeposit function
            (bool success, ) = localVault.call(
                abi.encodeWithSignature(
                    "processCrossChainDeposit(address,uint64,bytes)",
                    ccMessage.sender,
                    message.sourceChainSelector,
                    ccMessage.payload
                )
            );
            require(success, "Cross-chain deposit failed");
        } else if (ccMessage.msgType == MessageType.Redemption) {
            // Forward ETF tokens to the local vault
            for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
                IERC20(message.destTokenAmounts[i].token).safeTransfer(
                    localVault, 
                    message.destTokenAmounts[i].amount
                );
            }
            
            // Call the local vault's processCrossChainRedemption function
            (bool success, ) = localVault.call(
                abi.encodeWithSignature(
                    "processCrossChainRedemption(address,uint64,bytes)",
                    ccMessage.sender,
                    message.sourceChainSelector,
                    ccMessage.payload
                )
            );
            require(success, "Cross-chain redemption failed");
        }
        
        emit MessageReceived(message.sourceChainSelector, ccMessage.sender, ccMessage.msgType);
    }
    
    /**
     * @dev Helper to get token address for a vault
     */
    function vaultToToken(address vault) public view returns (address) {
        // This would need to be implemented through a registry or by calling the vault
        return IETFVault(vault).etfToken();
    }
    
    /**
     * @dev Withdraw any stuck tokens (admin only)
     */
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
    
    /**
     * @dev Withdraw any stuck ETH (admin only)
     */
    function withdrawETH(address to, uint256 amount) external onlyOwner {
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    // Enable contract to receive ETH
    receive() external payable {}
}

// Minimal interface for vault token getter
interface IETFVault {
    function etfToken() external view returns (address);
}