contract MockCCIPRouter {
    mapping(address => mapping(address => uint256)) public allowances;

    function approve(address spender, uint256 amount) public returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function getFee(uint256 chainId, bytes memory message) public view returns (uint256) {
        return 10000000000000000; // Example fee
    }

    function ccipSend(uint256 chainId, bytes memory message) public payable returns (bytes32) {
        require(allowances[msg.sender][address(this)] >= msg.value, "ERC20InsufficientAllowance");
        return keccak256(abi.encodePacked(chainId, message));
    }

    function lastMessage() public view returns (bytes32) {
        return 0; // Placeholder for last message
    }

    function deliverMessage(address manager, address router, uint256 amount, address token, uint256 value, bytes memory data) public {
        // Logic to deliver message
    }
}