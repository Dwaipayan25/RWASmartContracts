// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouterClient} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";

contract MockCCIPRouter is IRouterClient {
    uint256 public constant MOCK_FEE = 0 ether;
    uint256 private messageIdCounter = 1;
    
    mapping(bytes32 => bool) public sentMessages;
    
    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external pure override returns (uint256) {
        return MOCK_FEE;
    }

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage memory message
    ) external payable override returns (bytes32) {
        require(msg.value >= MOCK_FEE, "Insufficient fee");
        // For testing: Always allow the call regardless of msg.value
        // In real implementation, this would check msg.value >= getFee()
        
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