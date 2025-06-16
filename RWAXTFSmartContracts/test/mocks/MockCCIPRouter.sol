// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouterClient} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";

contract MockCCIPRouter is IRouterClient {
    uint256 public constant MOCK_FEE = 0.01 ether;
    uint256 private messageIdCounter = 1;
    
    mapping(bytes32 => bool) public sentMessages;
    
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChain,
        address indexed receiver,
        bytes data,
        Client.EVMTokenAmount[] tokenAmounts
    );

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external pure override returns (uint256) {
        return MOCK_FEE;
    }

    // function ccipSend(
    //     uint64 destinationChainSelector,
    //     Client.EVM2AnyMessage memory message
    // ) external payable override returns (bytes32) {
    //     require(msg.value >= MOCK_FEE, "Insufficient fee");
        
    //     bytes32 messageId = keccak256(abi.encodePacked(messageIdCounter++, block.timestamp));
    //     sentMessages[messageId] = true;
        
    //     address receiver = abi.decode(message.receiver, (address));
        
    //     emit MessageSent(
    //         messageId,
    //         destinationChainSelector,
    //         receiver,
    //         message.data,
    //         message.tokenAmounts
    //     );
        
    //     return messageId;
    // }

    // function getFee(
    //     uint64,
    //     Client.EVM2AnyMessage memory
    // ) external pure override returns (uint256) {
    //     return MOCK_FEE;
    // }

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage memory message
    ) external payable override returns (bytes32) {
        // For testing: Allow zero fee when no tokens are being sent
        if (message.tokenAmounts.length == 0) {
            // Message-only, allow zero fee for testing
        } else {
            require(msg.value >= MOCK_FEE, "Insufficient fee");
        }
        
        bytes32 messageId = keccak256(abi.encodePacked(messageIdCounter++, block.timestamp));
        sentMessages[messageId] = true;
        
        return messageId;
    }

    function isChainSupported(uint64) external pure override returns (bool) {
        return true;
    }

    function getSupportedTokens(uint64) external pure returns (address[] memory) {
        return new address[](0);
    }
}