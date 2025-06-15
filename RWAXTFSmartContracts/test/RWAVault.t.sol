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

contract RWAVaultTest is Test {
    RWAVault vault;
    ERC20Mock usdc;
    ERC20Mock rwa1;
    ERC20Mock rwa2;
    PriceFeedMock feed1;
    PriceFeedMock feed2;

    address user = address(0x1234);

    function setUp() public {
        vault = new RWAVault();
        usdc = new ERC20Mock("USD Coin", "USDC", 6, 1_000_000e6);
        rwa1 = new ERC20Mock("RWA1", "RWA1", 18, 1_000_000e18);
        rwa2 = new ERC20Mock("RWA2", "RWA2", 18, 1_000_000e18);

        // Price: 1 RWA1 = 2 USDC (6 decimals), 1 RWA2 = 1 USDC
        feed1 = new PriceFeedMock(2e6, 6);
        feed2 = new PriceFeedMock(1e6, 6);

        // Give user tokens
        usdc._mint(user, 1_000e6);
        rwa1._mint(user, 1_000e18);
        rwa2._mint(user, 1_000e18);
    }

    function testCreateVault() public {
        address[] memory assets = new address[](2);
        assets[0] = address(rwa1);
        assets[1] = address(rwa2);

        address[] memory feeds = new address[](2);
        feeds[0] = address(feed1);
        feeds[1] = address(feed2);

        uint256[] memory pcts = new uint256[](2);
        pcts[0] = 6000; // 60%
        pcts[1] = 4000; // 40%

        uint256 vaultId = vault.createVault(
            assets, feeds, pcts, address(usdc), 6, "VaultToken", "VT"
        );
        (address vaultToken,, uint256[] memory outPcts,,) = vault.getVaultDetails(vaultId);

        assertEq(vaultToken != address(0), true);
        assertEq(outPcts[0], 6000);
        assertEq(outPcts[1], 4000);
    }

    function testDepositAndRedeem() public {
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

        // Approve tokens
        vm.startPrank(user);
        usdc.approve(address(vault), 100e6);
        rwa1.approve(address(vault), 100e18);
        rwa2.approve(address(vault), 100e18);

        // Deposit 100 USDC
        vault.deposit(vaultId, 100e6);

        // Check balances
        (address[] memory balAssets, uint256[] memory bals) = vault.getVaultBalances(vaultId);
        assertEq(bals[0], 100e6); // USDC

        // RWA1: 50 USDC worth, price 2 USDC per RWA1, so 25 RWA1 (18 decimals)
        // RWA2: 50 USDC worth, price 1 USDC per RWA2, so 50 RWA2 (18 decimals)
        assertEq(bals[1], 25e18);
        assertEq(bals[2], 50e18);

        // Vault token balance
        VaultToken vaultToken = VaultToken(vaultTokenAddr);
        assertEq(vaultToken.balanceOf(user), 100e6);

        // Redeem all shares
        vaultToken.approve(address(vault), 100e6);
        vault.redeem(vaultId, 100e6);

        // After redeem, balances should be zero
        // You probably want to check getVaultBalances, not getVaultDetails here:
        (address[] memory balAssetsAfter, uint256[] memory balsAfter) = vault.getVaultBalances(vaultId);
        assertEq(vaultToken.balanceOf(user), 0);
        assertEq(balsAfter[0], 0); // USDC
        assertEq(balsAfter[1], 0); // RWA1
        assertEq(balsAfter[2], 0); // RWA2
        vm.stopPrank();
    }

    function testGetOwnershipPercentage() public {
        // Setup vault and deposit
        address[] memory assets = new address[](1);
        assets[0] = address(rwa1);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed1);
        uint256[] memory pcts = new uint256[](1);
        pcts[0] = 10000;

        uint256 vaultId = vault.createVault(
            assets, feeds, pcts, address(usdc), 6, "VaultToken", "VT"
        );
        vm.startPrank(user);
        usdc.approve(address(vault), 100e6);
        rwa1.approve(address(vault), 50e18);
        vault.deposit(vaultId, 100e6);

        uint256 pct = vault.getOwnershipPercentage(vaultId, user);
        assertEq(pct, 10000); // 100%
        vm.stopPrank();
    }
}