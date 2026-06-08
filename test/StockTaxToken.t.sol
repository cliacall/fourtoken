// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/tokens/StockTaxToken.sol";
import "../src/tokens/OpenFourToken.sol";
import "../src/modules/vault/StocksVaultModule.sol";
import "../src/validators/StockTaxValidator.sol";
import "../src/interfaces/IStockTaxToken.sol";
import "../src/interfaces/IStocksVault.sol";

/// @notice Test harness — bypasses OZ v5 initialization for direct testing
contract StockTaxTokenHarness is StockTaxToken {
    constructor() StockTaxToken() {}

    function testInit(OpenFourToken.InitArgs memory args, StockTaxConfig memory cfg) external {
        vault = args.vault;
        maxSupply = args.maxSupply;
        curveModule = args.curveModule;
        tradeModule = args.tradeModule;
        migrateModule = args.migrateModule;
        tokenModule = args.tokenModule;
        customData = args.customDataModule;
        requestId = args.requestId;
        if (args.maxSupply > 0) _mint(args.vault, args.maxSupply);
        _harnessInitTax(cfg);
    }

    function _harnessInitTax(StockTaxConfig memory c) internal {
        owner = c.creator != address(0) ? c.creator : msg.sender;
        buyFeeRate = c.buyFeeRate; sellFeeRate = c.sellFeeRate;
        rateStocks = c.rateStocks; rateFundsWallet = c.rateFundsWallet;
        rateBurn = c.rateBurn; rateDividend = c.rateDividend;
        rateLiquidity = c.rateLiquidity; rateUnallocated = c.rateUnallocated;
        fundsWallet = c.fundsWallet; stocksVault = c.stocksVault;
        if (c.antiFarmerDuration > 0) {
            antiFarmerEndTime = block.timestamp + c.antiFarmerDuration;
            antiFarmerActive = true;
        }
    }
}

contract StockTaxTokenTest is Test {
    StockTaxTokenHarness token;
    StocksVaultModule stocksVault;

    address owner = address(0x100);
    address vault = address(0x200);
    address fundsWallet = address(0x300);
    address alice = address(0xA);
    address bob = address(0xB);

    function setUp() public {
        vm.startPrank(owner);

        stocksVault = new StocksVaultModule();
        stocksVault.init(IStocksVault.StocksConfig({
            buybackToken: address(0), oracle: address(0),
            minBuybackAmount: 1 ether, buybackInterval: 1 hours,
            autoBuyback: false
        }));

        token = new StockTaxTokenHarness();

        StockTaxConfig memory cfg = StockTaxConfig({
            buyFeeRate: 100, sellFeeRate: 100, rateStocks: 300,
            rateFundsWallet: 200, rateBurn: 100, rateDividend: 0,
            rateLiquidity: 300, rateUnallocated: 100,
            antiFarmerDuration: 3 days, fundsWallet: fundsWallet,
            stocksVault: address(stocksVault), creator: owner
        });

        token.testInit(OpenFourToken.InitArgs({
            requestId: 1, name: "Test", symbol: "TST", vault: vault,
            maxSupply: 1_000_000 ether, tokenUri: "",
            curveModule: address(0x1), tradeModule: address(0x2),
            migrateModule: address(0x3), tokenModule: address(this),
            customDataModule: address(0), creator: owner,
            quoteAsset: address(0),
            tokenParams: abi.encode(cfg), tokenImplVersion: "v1.0.0"
        }), cfg);

        vm.deal(address(token), 100 ether);
        vm.deal(vault, 100 ether);
        vm.stopPrank();

        vm.label(owner, "owner"); vm.label(vault, "vault");
        vm.label(alice, "alice"); vm.label(bob, "bob");
    }

    // ─── Tax Allocation ───
    function test_allocationSumsTo100() public view {
        assertEq(uint256(token.rateStocks()) + token.rateFundsWallet() + token.rateBurn()
            + token.rateDividend() + token.rateLiquidity() + token.rateUnallocated(), 1000);
    }

    function test_taxCollection() public {
        vm.prank(vault);
        token.onBondingTrade(alice, 1 ether, 100 ether, true); // 1 BNB buy, 1% tax
        assertEq(token.totalTaxCollected(), 1 ether * 100 / 10_000);
        uint256 expectedStocks = 1 ether * 100 / 10_000 * 300 / 1000;
        assertEq(address(stocksVault).balance, expectedStocks);
    }

    // ─── Tax Rate Timelock ───
    function test_timelockSchedule() public {
        vm.prank(owner);
        token.scheduleTaxRateChange(500, 500);
        assertEq(token.pendingBuyFeeRate(), 500);
        assertGt(token.rateChangeUnlockTime(), block.timestamp);
    }

    function test_timelockApply() public {
        vm.prank(owner);
        token.scheduleTaxRateChange(500, 500);
        vm.warp(token.rateChangeUnlockTime() + 1);
        token.applyTaxRateChange();
        assertEq(token.buyFeeRate(), 500);
    }

    function test_timelockOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("ST: not owner");
        token.scheduleTaxRateChange(500, 500);
    }

    // ─── Anti-Farmer ───
    function test_antiFarmerActive() public view {
        assertTrue(token.antiFarmerActive());
    }

    function test_antiFarmerExpires() public {
        vm.warp(token.antiFarmerEndTime() + 1);
        assertFalse(token.isAntiFarmerActive());
    }

    // ─── Sweep Unallocated ───
    function test_sweepUnallocated() public {
        vm.prank(vault);
        token.onBondingTrade(bob, 1 ether, 100 ether, true);
        uint256 bal = token.unallocatedBalance();
        assertGt(bal, 0);

        uint256 before = owner.balance;
        vm.prank(owner);
        token.sweepUnallocated(owner, bal);
        assertGt(owner.balance, before);
    }

    function test_sweepOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("ST: not owner");
        token.sweepUnallocated(alice, 1);
    }

    // ─── Validator ───
    function test_validatorPass() public {
        StockTaxValidator v = new StockTaxValidator();
        StockTaxConfig memory cfg = StockTaxConfig({
            buyFeeRate: 100, sellFeeRate: 100, rateStocks: 300,
            rateFundsWallet: 200, rateBurn: 100, rateDividend: 0,
            rateLiquidity: 300, rateUnallocated: 100,
            antiFarmerDuration: 3 days, fundsWallet: fundsWallet,
            stocksVault: address(stocksVault), creator: owner
        });
        v.validate(1, OpenFourTypes.TokenInitParams({
            name:"T",symbol:"T",tokenUri:"",maxSupply:1000 ether,
            saleAmount:100 ether,raiseAmount:0,quoteAsset:address(0),
            tokenSalt:bytes32(0),tokenParams:abi.encode(cfg),
            vaultParams:"",curveParams:"",tradeParams:"",
            migrateParams:"",customDataParams:""
        }));
    }

    function test_validatorBadSum() public {
        StockTaxValidator v = new StockTaxValidator();
        StockTaxConfig memory cfg = StockTaxConfig({
            buyFeeRate: 100, sellFeeRate: 100, rateStocks: 800,
            rateFundsWallet: 200, rateBurn: 200, rateDividend: 0,
            rateLiquidity: 200, rateUnallocated: 100, // sum=1500
            antiFarmerDuration: 3 days, fundsWallet: fundsWallet,
            stocksVault: address(stocksVault), creator: owner
        });
        vm.expectRevert("STV: alloc != 100%");
        v.validate(1, OpenFourTypes.TokenInitParams({
            name:"T",symbol:"T",tokenUri:"",maxSupply:1000 ether,
            saleAmount:100 ether,raiseAmount:0,quoteAsset:address(0),
            tokenSalt:bytes32(0),tokenParams:abi.encode(cfg),
            vaultParams:"",curveParams:"",tradeParams:"",
            migrateParams:"",customDataParams:""
        }));
    }

    function test_validatorStocksDividend() public {
        StockTaxValidator v = new StockTaxValidator();
        StockTaxConfig memory cfg = StockTaxConfig({
            buyFeeRate: 100, sellFeeRate: 100, rateStocks: 400,
            rateFundsWallet: 100, rateBurn: 100, rateDividend: 400,
            rateLiquidity: 0, rateUnallocated: 0,
            antiFarmerDuration: 3 days, fundsWallet: fundsWallet,
            stocksVault: address(stocksVault), creator: owner
        });
        vm.expectRevert("STV: stocks & dividend both set");
        v.validate(1, OpenFourTypes.TokenInitParams({
            name:"T",symbol:"T",tokenUri:"",maxSupply:1000 ether,
            saleAmount:100 ether,raiseAmount:0,quoteAsset:address(0),
            tokenSalt:bytes32(0),tokenParams:abi.encode(cfg),
            vaultParams:"",curveParams:"",tradeParams:"",
            migrateParams:"",customDataParams:""
        }));
    }

    receive() external payable {}
}
