// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract VaultToken is ERC20 {
    address public immutable vault;

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault can call");
        _;
    }

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        vault = msg.sender;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}