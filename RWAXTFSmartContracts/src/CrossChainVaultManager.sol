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
    IRouterClient public immutable router;
    
    // Chain configuration
    mapping(uint64 => bool) public allowlistedChains;
    mapping(uint64 => address) public crossChainManagers; // Manager contracts on other chains
    mapping(address => bool) public allowlistedTokens;
    
    // Track user vault shares (vaultId => user => shares)
    mapping(uint256 => mapping(address => uint256)) public userVaultShares;
    
    // Track which chain hosts each vault
    mapping(uint256 => uint64) public vaultChains;
    mapping(uint256 => address) public vaultCreators;
    uint64 public immutable thisChain;
    bool public immutable isVaultChain;
    
    // Message tracking
    mapping(bytes32 => bool) public processedMessages;

    // Add these state variables after other mappings
    uint256[] public allVaultIds;                    // Array of all registered vault IDs
    mapping(uint64 => uint256[]) public chainVaults; // Mapping of chain selector to vault IDs on that chain
    mapping(uint256 => uint256) private vaultIdToIndex; // For O(1) existence check and removal
    
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

    event VaultRegistered(uint256 indexed vaultId, uint64 indexed chainSelector, address indexed registrar);


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

    function setVaultChain(uint256 _vaultId, uint64 _chainSelector) external {
    require(_chainSelector != 0, "Invalid chain selector");
    // require(allowlistedChains[_chainSelector], "Chain not allowlisted");
    
    // Check if this vault was previously registered on a different chain
    uint64 previousChain = vaultChains[_vaultId];
    if (previousChain != 0 && previousChain != _chainSelector) {
        // Remove from previous chain's array
        _removeVaultFromChain(previousChain, _vaultId);
    }
    
    // Set the chain selector for this vault
    vaultChains[_vaultId] = _chainSelector;
    
    // Add to chain's vault array if not already there
    if (previousChain != _chainSelector) {
        chainVaults[_chainSelector].push(_vaultId);
    }
    
    // Add to global vault list if new
    if (previousChain == 0) {
        vaultIdToIndex[_vaultId] = allVaultIds.length;
        allVaultIds.push(_vaultId);
    }
    
    // Track the vault registrar for permission management
    if (vaultCreators[_vaultId] == address(0)) {
        vaultCreators[_vaultId] = msg.sender;
    }
    
    emit VaultRegistered(_vaultId, _chainSelector, msg.sender);
}

// Helper function to remove a vault from a chain's array
function _removeVaultFromChain(uint64 _chainSelector, uint256 _vaultId) internal {
    uint256[] storage vaults = chainVaults[_chainSelector];
    for (uint i = 0; i < vaults.length; i++) {
        if (vaults[i] == _vaultId) {
            // Replace with the last element and pop
            vaults[i] = vaults[vaults.length - 1];
            vaults.pop();
            break;
        }
    }
}

    // ============ CROSS-CHAIN DEPOSIT ============
    
    function crossChainDeposit(
        uint256 vaultId,
        uint256 baseAmount,
        address baseToken
    ) external payable {
        // require(allowlistedTokens[baseToken], "Token not allowlisted");
        require(baseAmount > 0, "Amount must be positive");
        
        uint64 vaultChain = vaultChains[vaultId];
        require(vaultChain != 0, "Vault chain not set");
        // require(allowlistedChains[vaultChain], "Vault chain not allowlisted");

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
        // require(allowlistedChains[vaultChain], "Vault chain not allowlisted");

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

    // Add this function to the contract for testing
    function ccipReceiveForTesting(Client.Any2EVMMessage memory any2EvmMessage) external {
        _ccipReceive(any2EvmMessage);
    }

    // Add these functions to the VIEW FUNCTIONS section

/// @notice Get all registered vault IDs
/// @return Array of all vault IDs that have been registered
function getAllVaultIds() external view returns (uint256[] memory) {
    return allVaultIds;
}

/// @notice Get the total number of registered vaults
/// @return The count of registered vaults
function getVaultCount() external view returns (uint256) {
    return allVaultIds.length;
}

/// @notice Get all vault IDs registered on a specific chain
/// @param _chainSelector The chain selector to query
/// @return Array of vault IDs registered on the specified chain
function getVaultsByChain(uint64 _chainSelector) external view returns (uint256[] memory) {
    return chainVaults[_chainSelector];
}

/// @notice Get a paginated list of all vault IDs (useful for UIs with many vaults)
/// @param _start The starting index
/// @param _limit Maximum number of entries to return
/// @return Array of vault IDs within the specified range
function getPaginatedVaultIds(uint256 _start, uint256 _limit) external view returns (uint256[] memory) {
    if (_start >= allVaultIds.length) {
        return new uint256[](0);
    }
    
    uint256 end = _start + _limit;
    if (end > allVaultIds.length) {
        end = allVaultIds.length;
    }
    
    uint256[] memory result = new uint256[](end - _start);
    for (uint256 i = _start; i < end; i++) {
        result[i - _start] = allVaultIds[i];
    }
    
    return result;
}

/// @notice Get comprehensive information about a specific vault
/// @param _vaultId The vault ID to query
/// @return chainSelector The chain where this vault is registered
/// @return creator Address that registered this vault
/// @return isActive Whether this vault is on an allowlisted chain
/// @return totalUserShares Total shares tracked on this chain
function getVaultInfo(uint256 _vaultId) external view returns (
    uint64 chainSelector,
    address creator, 
    bool isActive,
    uint256 totalUserShares
) {
    chainSelector = vaultChains[_vaultId];
    creator = vaultCreators[_vaultId];
    // isActive = allowlistedChains[chainSelector];
    
    // For total shares, we need to sum all user shares for this vault on this chain
    // This is a simplified approach and could be optimized with a dedicated counter
    totalUserShares = 0;
    
    // Return details based on what's available on this chain
    if (isVaultChain && chainSelector == thisChain) {
        // We're on the vault chain for this vault - get data from the actual vault
        (address vaultToken, , , , ) = vault.getVaultDetails(_vaultId);
        totalUserShares = IERC20(vaultToken).totalSupply();
    }
    
    return (chainSelector, creator, isActive, totalUserShares);
}

/// @notice Get detailed information about multiple vaults at once
/// @param _vaultIds Array of vault IDs to query
/// @return chainSelectors The chains where these vaults are registered
/// @return creators Addresses that registered these vaults
/// @return isActives Whether these vaults are on allowlisted chains
/// @return totalShares Total shares for each vault tracked on this chain
function getBatchVaultInfo(uint256[] calldata _vaultIds) external view 
    returns (
        uint64[] memory chainSelectors, 
        address[] memory creators, 
        bool[] memory isActives,
        uint256[] memory totalShares
    ) 
{
    uint256 length = _vaultIds.length;
    chainSelectors = new uint64[](length);
    creators = new address[](length);
    isActives = new bool[](length);
    totalShares = new uint256[](length);
    
    for (uint256 i = 0; i < length; i++) {
        uint256 vaultId = _vaultIds[i];
        chainSelectors[i] = vaultChains[vaultId];
        creators[i] = vaultCreators[vaultId];
        // isActives[i] = allowlistedChains[chainSelectors[i]];
        
        // Get total shares similar to the single vault case
        if (isVaultChain && chainSelectors[i] == thisChain) {
            (address vaultToken, , , , ) = vault.getVaultDetails(vaultId);
            totalShares[i] = IERC20(vaultToken).totalSupply();
        }
    }
    
    return (chainSelectors, creators, isActives, totalShares);
}


function getLocalVaultDetails() external view returns (
    uint256[] memory vaultIds,
    uint64[] memory chainSelectors,
    address[] memory creators,
    uint256[] memory totalShares,
    uint256[] memory tvls  // TVL only available for vaults on this chain
) {
    // Get vaults on this chain
    uint256[] memory localVaults = chainVaults[thisChain];
    uint256 count = localVaults.length;
    
    vaultIds = new uint256[](count);
    chainSelectors = new uint64[](count);
    creators = new address[](count);
    totalShares = new uint256[](count);
    tvls = new uint256[](count);
    
    for (uint256 i = 0; i < count; i++) {
        uint256 vaultId = localVaults[i];
        vaultIds[i] = vaultId;
        chainSelectors[i] = thisChain;
        creators[i] = vaultCreators[vaultId];
        
        // Additional vault-specific details if this is the vault chain
        if (isVaultChain) {
            (address vaultToken, , , , ) = vault.getVaultDetails(vaultId);
            totalShares[i] = IERC20(vaultToken).totalSupply();
            
            // Calculate TVL if we're on the vault chain and have access to the vault
            // This leverages the vault's internal TVL calculation function
            tvls[i] = vault._calculateVaultTVL(vaultId);
        }
    }
    
    return (vaultIds, chainSelectors, creators, totalShares, tvls);
}


/// @notice Get user balances across multiple vaults
/// @param _user The user address to query
/// @param _vaultIds Array of vault IDs to check
/// @return balances Array of the user's balances for each vault
function getUserVaultBalances(address _user, uint256[] calldata _vaultIds) external view returns (uint256[] memory balances) {
    uint256 length = _vaultIds.length;
    balances = new uint256[](length);
    
    for (uint256 i = 0; i < length; i++) {
        balances[i] = userVaultShares[_vaultIds[i]][_user];
    }
    
    return balances;
}

/// @notice Get all vaults where a user has shares
/// @param _user The user address to query
/// @return userVaultIds Array of vault IDs where the user has shares
/// @return userBalances Array of the user's corresponding balances
function getUserVaults(address _user) external view returns (
    uint256[] memory userVaultIds,
    uint256[] memory userBalances
) {
    // First, count how many vaults the user has shares in
    uint256 userVaultCount = 0;
    for (uint256 i = 0; i < allVaultIds.length; i++) {
        if (userVaultShares[allVaultIds[i]][_user] > 0) {
            userVaultCount++;
        }
    }
    
    // Then populate the result arrays
    userVaultIds = new uint256[](userVaultCount);
    userBalances = new uint256[](userVaultCount);
    
    uint256 resultIndex = 0;
    for (uint256 i = 0; i < allVaultIds.length; i++) {
        uint256 vaultId = allVaultIds[i];
        uint256 balance = userVaultShares[vaultId][_user];
        
        if (balance > 0) {
            userVaultIds[resultIndex] = vaultId;
            userBalances[resultIndex] = balance;
            resultIndex++;
        }
    }
    
    return (userVaultIds, userBalances);
}

/// @notice Get the chain selectors where this user has vault balances
/// @param _user The user address to query
/// @return activeChains Array of chain selectors where this user has activity
function getUserActiveChains(address _user) external view returns (uint64[] memory activeChains) {
    // This is a simplified implementation that requires iterating over all vaults
    // A more efficient implementation would maintain a mapping of user -> chains
    
    // First, find all unique chains where the user has balances
    uint64[] memory tempChains = new uint64[](allVaultIds.length); // Max possible size
    uint256 uniqueChainCount = 0;
    
    for (uint256 i = 0; i < allVaultIds.length; i++) {
        uint256 vaultId = allVaultIds[i];
        if (userVaultShares[vaultId][_user] > 0) {
            uint64 chainSelector = vaultChains[vaultId];
            
            // Check if we've already added this chain
            bool found = false;
            for (uint256 j = 0; j < uniqueChainCount; j++) {
                if (tempChains[j] == chainSelector) {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                tempChains[uniqueChainCount] = chainSelector;
                uniqueChainCount++;
            }
        }
    }
    
    // Create the properly sized result array
    activeChains = new uint64[](uniqueChainCount);
    for (uint256 i = 0; i < uniqueChainCount; i++) {
        activeChains[i] = tempChains[i];
    }
    
    return activeChains;
}

/// @notice Get complete user portfolio across all vaults
/// @param _user The user address to query
/// @return vaultIds Array of vault IDs where user has shares
/// @return chainSelectors The respective chain for each vault
/// @return balances User's balance in each vault
/// @return percentages User's percentage ownership of each vault (in basis points, 10000 = 100%)
function getUserPortfolio(address _user) external view returns (
    uint256[] memory vaultIds,
    uint64[] memory chainSelectors,
    uint256[] memory balances,
    uint256[] memory percentages
) {
    // First pass: count user vaults
    uint256 userVaultCount = 0;
    for (uint256 i = 0; i < allVaultIds.length; i++) {
        if (userVaultShares[allVaultIds[i]][_user] > 0) {
            userVaultCount++;
        }
    }
    
    // Initialize return arrays
    vaultIds = new uint256[](userVaultCount);
    chainSelectors = new uint64[](userVaultCount);
    balances = new uint256[](userVaultCount);
    percentages = new uint256[](userVaultCount);
    
    // Second pass: populate data
    uint256 resultIndex = 0;
    for (uint256 i = 0; i < allVaultIds.length; i++) {
        uint256 vaultId = allVaultIds[i];
        uint256 userShares = userVaultShares[vaultId][_user];
        
        if (userShares > 0) {
            vaultIds[resultIndex] = vaultId;
            chainSelectors[resultIndex] = vaultChains[vaultId];
            balances[resultIndex] = userShares;
            
            // Only calculate percentage if this is the vault chain
            if (isVaultChain && vaultChains[vaultId] == thisChain) {
                (address vaultToken, , , , ) = vault.getVaultDetails(vaultId);
                uint256 totalSupply = IERC20(vaultToken).totalSupply();
                
                if (totalSupply > 0) {
                    percentages[resultIndex] = (userShares * 10000) / totalSupply;
                }
            }
            
            resultIndex++;
        }
    }
    
    return (vaultIds, chainSelectors, balances, percentages);
}


/// @notice Get global vault statistics across all chains
/// @return totalVaults Total number of registered vaults
/// @return totalChains Number of chains with registered vaults
/// @return vaultsPerChain Count of vaults on each chain
/// @return chainSelectors List of chain selectors with vaults
function getGlobalVaultStats() external view returns (
    uint256 totalVaults,
    uint256 totalChains,
    uint256[] memory vaultsPerChain,
    uint64[] memory chainSelectors
) {
    // Count unique chains with vaults
    uint64[] memory uniqueChains = new uint64[](allVaultIds.length); // Max possible size
    uint256 uniqueChainCount = 0;
    
    // Find all unique chains with vaults
    for (uint256 i = 0; i < allVaultIds.length; i++) {
        uint64 chainSelector = vaultChains[allVaultIds[i]];
        
        bool found = false;
        for (uint256 j = 0; j < uniqueChainCount; j++) {
            if (uniqueChains[j] == chainSelector) {
                found = true;
                break;
            }
        }
        
        if (!found && chainSelector != 0) {
            uniqueChains[uniqueChainCount] = chainSelector;
            uniqueChainCount++;
        }
    }
    
    // Create properly sized result arrays
    chainSelectors = new uint64[](uniqueChainCount);
    vaultsPerChain = new uint256[](uniqueChainCount);
    
    // Copy unique chains and count vaults per chain
    for (uint256 i = 0; i < uniqueChainCount; i++) {
        chainSelectors[i] = uniqueChains[i];
        vaultsPerChain[i] = chainVaults[uniqueChains[i]].length;
    }
    
    return (
        allVaultIds.length,
        uniqueChainCount,
        vaultsPerChain,
        chainSelectors
    );
}
}