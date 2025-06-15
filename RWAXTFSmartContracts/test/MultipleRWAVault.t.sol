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

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _supply) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        _mint(msg.sender, _supply);
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

    function _mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// Minimal Chainlink price feed mock
contract PriceFeedMock is AggregatorV3Interface {
    int256 public answer;
    uint8 public override decimals;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
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

    // Unused
    function description() external pure override returns (string memory) { return ""; }
    function version() external pure override returns (uint256) { return 1; }
    function getRoundData(uint80) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }
}

contract RWAVaultMultiUserTest is Test {
    RWAVault vault;
    ERC20Mock usdc;
    ERC20Mock rwa1;
    ERC20Mock rwa2;
    PriceFeedMock feed1;
    PriceFeedMock feed2;

    address user1 = address(0x1111);
    address user2 = address(0x2222);
    address user3 = address(0x3333);

    function setUp() public {
        vault = new RWAVault();
        usdc = new ERC20Mock("USD Coin", "USDC", 6, 1_000_000e6);
        rwa1 = new ERC20Mock("RWA1", "RWA1", 18, 1_000_000e18);
        rwa2 = new ERC20Mock("RWA2", "RWA2", 18, 1_000_000e18);

        // Price: 1 RWA1 = 2 USDC (6 decimals), 1 RWA2 = 1 USDC
        feed1 = new PriceFeedMock(2e6, 6);
        feed2 = new PriceFeedMock(1e6, 6);

        // Give users tokens
        usdc._mint(user1, 1_000e6);
        usdc._mint(user2, 1_000e6);
        usdc._mint(user3, 1_000e6);

        rwa1._mint(user1, 1_000e18);
        rwa1._mint(user2, 1_000e18);
        rwa1._mint(user3, 1_000e18);

        rwa2._mint(user1, 1_000e18);
        rwa2._mint(user2, 1_000e18);
        rwa2._mint(user3, 1_000e18);
    }

    function testThreeUsersDepositAndRedeem() public {
        // Create vault
        address[] memory assets = new address[](2);
        assets[0] = address(rwa1);
        assets[1] = address(rwa2);

        address[] memory feeds = new address[](2);
        feeds[0] = address(feed1);
        feeds[1] = address(feed2);

        uint256[] memory pcts = new uint256[](2);
        pcts[0] = 5000; // 50%
        pcts[1] = 5000; // 50%

        uint256 vaultId = vault.createVault(
            assets, feeds, pcts, address(usdc), 6, "VaultToken", "VT"
        );
        (address vaultTokenAddr,,,,) = vault.getVaultDetails(vaultId);
        VaultToken vaultToken = VaultToken(vaultTokenAddr);

        // --- User 1 deposits 100 USDC ---
        vm.startPrank(user1);
        usdc.approve(address(vault), 100e6);
        rwa1.approve(address(vault), 100e18);
        rwa2.approve(address(vault), 100e18);
        vault.deposit(vaultId, 100e6);
        vm.stopPrank();

        // --- User 2 deposits 200 USDC ---
        vm.startPrank(user2);
        usdc.approve(address(vault), 200e6);
        rwa1.approve(address(vault), 200e18);
        rwa2.approve(address(vault), 200e18);
        vault.deposit(vaultId, 200e6);
        vm.stopPrank();

        // --- User 3 deposits 300 USDC ---
        vm.startPrank(user3);
        usdc.approve(address(vault), 300e6);
        rwa1.approve(address(vault), 300e18);
        rwa2.approve(address(vault), 300e18);
        vault.deposit(vaultId, 300e6);
        vm.stopPrank();

        // Check vault token balances
        assertEq(vaultToken.balanceOf(user1), 100e6);
        assertEq(vaultToken.balanceOf(user2), 200e6);
        assertEq(vaultToken.balanceOf(user3), 300e6);

        // Check ownership percentages
        uint256 pct1 = vault.getOwnershipPercentage(vaultId, user1);
        uint256 pct2 = vault.getOwnershipPercentage(vaultId, user2);
        uint256 pct3 = vault.getOwnershipPercentage(vaultId, user3);
        
        // Calculate expected percentages: (balance * 10000) / totalSupply
        uint256 expectedPct1 = 1666; // 16.66% = 1666/10000
        uint256 expectedPct2 = 3333; // 33.33% = 3333/10000  
        uint256 expectedPct3 = 5000; // 50% = 5000/10000
        
        assertEq(pct1, expectedPct1);
        assertEq(pct2, expectedPct2);
        assertEq(pct3, expectedPct3);

        // --- User 1 redeems all ---
        vm.startPrank(user1);
        vaultToken.approve(address(vault), 100e6);
        vault.redeem(vaultId, 100e6);
        assertEq(vaultToken.balanceOf(user1), 0);
        vm.stopPrank();

        // --- User 2 redeems all ---
        vm.startPrank(user2);
        vaultToken.approve(address(vault), 200e6);
        vault.redeem(vaultId, 200e6);
        assertEq(vaultToken.balanceOf(user2), 0);
        vm.stopPrank();

        // --- User 3 redeems all ---
        vm.startPrank(user3);
        vaultToken.approve(address(vault), 300e6);
        vault.redeem(vaultId, 300e6);
        assertEq(vaultToken.balanceOf(user3), 0);
        vm.stopPrank();

        // After all redeems, vault balances should be zero
        (address[] memory balAssetsAfter, uint256[] memory balsAfter) = vault.getVaultBalances(vaultId);
        for (uint i = 0; i < balsAfter.length; i++) {
            assertEq(balsAfter[i], 0);
        }
    }
}