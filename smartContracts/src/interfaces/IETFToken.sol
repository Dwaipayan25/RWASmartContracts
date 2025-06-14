// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IETFToken
 * @dev Interface for the ETFToken representing ownership shares in the ETF vault
 */
interface IETFToken is IERC20, IAccessControl {
    /**
     * @dev Mint new tokens - only callable by authorized minters (vaults)
     * @param to The address that will receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;
    
    /**
     * @dev Burn tokens - only callable by authorized minters (vaults)
     * @param from The address whose tokens will be burned
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external;
    
    /**
     * @dev Grant minter role to a new vault
     * @param minter The address to be granted the minter role
     */
    function addMinter(address minter) external;
}