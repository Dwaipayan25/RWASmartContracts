// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/RWAVault.sol";
import "../src/VaultToken.sol";

// Minimal ERC20 mock with decimals
contract ERC20Mock is IERC20Decimals {
    string public name;
    string public symbol;
    uint8 public override decimals;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Chainlink price feed mock
contract PriceFeedMock is AggregatorV3Interface {
    int256 public answer;
    uint8 public override decimals;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
    }

    function setPrice(int256 _newPrice) external {
        answer = _newPrice;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80, int256, uint256, uint256, uint80
        )
    {
        return (0, answer, 0, 0, 0);
    }

    // Unused functions
    function description() external pure override returns (string memory) { return ""; }
    function version() external pure override returns (uint256) { return 1; }
    function getRoundData(uint80) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }
}

contract CalculateRequiredRWAsTest is Test {
    RWAVault vault;
    ERC20Mock usdc;
    ERC20Mock rwa1;
    ERC20Mock rwa2;
    ERC20Mock rwa3;
    PriceFeedMock feed1;
    PriceFeedMock feed2;
    PriceFeedMock feed3;

    uint256 vaultId;

    function setUp() public {
        vault = new RWAVault();
        
        // Create tokens with different decimals
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        rwa1 = new ERC20Mock("RWA1", "RWA1", 18);
        rwa2 = new ERC20Mock("RWA2", "RWA2", 8);
        rwa3 = new ERC20Mock("RWA3", "RWA3", 6);

        // Create price feeds with different decimals and prices
        feed1 = new PriceFeedMock(2e6, 6);   // 1 RWA1 = 2 USDC
        feed2 = new PriceFeedMock(5e8, 8);   // 1 RWA2 = 5 USDC
        feed3 = new PriceFeedMock(1e6, 6);   // 1 RWA3 = 1 USDC

        // Create vault with 3 assets
        address[] memory assets = new address[](3);
        assets[0] = address(rwa1);
        assets[1] = address(rwa2);
        assets[2] = address(rwa3);

        address[] memory feeds = new address[](3);
        feeds[0] = address(feed1);
        feeds[1] = address(feed2);
        feeds[2] = address(feed3);

        uint256[] memory pcts = new uint256[](3);
        pcts[0] = 5000; // 50%
        pcts[1] = 3000; // 30%
        pcts[2] = 2000; // 20%

        vaultId = vault.createVault(
            assets, feeds, pcts, address(usdc), 6, "VaultToken", "VT"
        );
    }

    function testCalculateRequiredRWAs_BasicCase() public {
        uint256 depositAmount = 1000e6; // 1000 USDC

        (address[] memory assets, uint256[] memory amounts) = 
            vault.calculateRequiredRWAs(vaultId, depositAmount);

        // Verify assets returned correctly
        assertEq(assets.length, 3);
        assertEq(assets[0], address(rwa1));
        assertEq(assets[1], address(rwa2));
        assertEq(assets[2], address(rwa3));

        // Calculate expected amounts:
        // RWA1: 50% of 1000 USDC = 500 USDC, price = 2 USDC/RWA1 → 250 RWA1 (18 decimals)
        uint256 expectedRWA1 = 250e18;
        
        // RWA2: 30% of 1000 USDC = 300 USDC, price = 5 USDC/RWA2 → 60 RWA2 (8 decimals)
        uint256 expectedRWA2 = 60e8;
        
        // RWA3: 20% of 1000 USDC = 200 USDC, price = 1 USDC/RWA3 → 200 RWA3 (6 decimals)
        uint256 expectedRWA3 = 200e6;

        assertEq(amounts[0], expectedRWA1);
        assertEq(amounts[1], expectedRWA2);
        assertEq(amounts[2], expectedRWA3);
    }

    function testCalculateRequiredRWAs_SmallAmount() public {
        uint256 depositAmount = 1e6; // 1 USDC

        (address[] memory assets, uint256[] memory amounts) = 
            vault.calculateRequiredRWAs(vaultId, depositAmount);

        // RWA1: 50% of 1 USDC = 0.5 USDC, price = 2 USDC/RWA1 → 0.25 RWA1
        uint256 expectedRWA1 = 25e16; // 0.25 * 1e18
        
        // RWA2: 30% of 1 USDC = 0.3 USDC, price = 5 USDC/RWA2 → 0.06 RWA2
        uint256 expectedRWA2 = 6e6; // 0.06 * 1e8
        
        // RWA3: 20% of 1 USDC = 0.2 USDC, price = 1 USDC/RWA3 → 0.2 RWA3
        uint256 expectedRWA3 = 2e5; // 0.2 * 1e6

        assertEq(amounts[0], expectedRWA1);
        assertEq(amounts[1], expectedRWA2);
        assertEq(amounts[2], expectedRWA3);
    }

    function testCalculateRequiredRWAs_PriceChange() public {
        // Change RWA1 price from 2 USDC to 4 USDC
        feed1.setPrice(4e6);

        uint256 depositAmount = 1000e6; // 1000 USDC

        (address[] memory assets, uint256[] memory amounts) = 
            vault.calculateRequiredRWAs(vaultId, depositAmount);

        // RWA1: 50% of 1000 USDC = 500 USDC, price = 4 USDC/RWA1 → 125 RWA1
        uint256 expectedRWA1 = 125e18;
        
        // RWA2 and RWA3 should remain the same
        uint256 expectedRWA2 = 60e8;
        uint256 expectedRWA3 = 200e6;

        assertEq(amounts[0], expectedRWA1);
        assertEq(amounts[1], expectedRWA2);
        assertEq(amounts[2], expectedRWA3);
    }

    function testCalculateRequiredRWAs_InvalidVaultId() public {
        vm.expectRevert("Invalid vault ID");
        vault.calculateRequiredRWAs(999, 1000e6);
    }

    function testCalculateRequiredRWAs_ZeroAmount() public {
        (address[] memory assets, uint256[] memory amounts) = 
            vault.calculateRequiredRWAs(vaultId, 0);

        // All amounts should be zero
        for (uint i = 0; i < amounts.length; i++) {
            assertEq(amounts[i], 0);
        }
    }

    function testCalculateRequiredRWAs_DifferentFeedDecimals() public {
        // Create a new vault with a price feed having different decimals
        ERC20Mock rwa4 = new ERC20Mock("RWA4", "RWA4", 12);
        PriceFeedMock feed4 = new PriceFeedMock(15e4, 4); // 1.5 USDC with 4 decimals

        address[] memory assets = new address[](1);
        assets[0] = address(rwa4);

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed4);

        uint256[] memory pcts = new uint256[](1);
        pcts[0] = 10000; // 100%

        uint256 newVaultId = vault.createVault(
            assets, feeds, pcts, address(usdc), 6, "VaultToken2", "VT2"
        );

        uint256 depositAmount = 150e6; // 150 USDC

        (address[] memory returnedAssets, uint256[] memory amounts) = 
            vault.calculateRequiredRWAs(newVaultId, depositAmount);

        // 150 USDC / 1.5 USDC per RWA4 = 100 RWA4 (12 decimals)
        uint256 expectedRWA4 = 10e12;

        assertEq(amounts[0], expectedRWA4);
    }
}