// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../tokens/OpenFourToken.sol";
import "../interfaces/IStockTaxToken.sol";
import "../interfaces/IStocksVault.sol";
import "../interfaces/IOpenFourVault.sol";

/// @title StockTaxToken
/// @notice On-chain tax token with Stocks (币股), Funds Wallet, Burn, Dividend, Liquidity.
///         Extends OpenFourToken with tax collection and distribution on bonding + DEX trades.
/// @dev Allocation rates must sum to 1000 (100%). Stocks > 0 forces Dividend = 0.
contract StockTaxToken is OpenFourToken {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant TAX_PRECISION = 1_000;
    uint256 private constant MAX_TAX_RATE = 1_000;
    uint256 private constant MAGNITUDE = 1e18;
    uint256 private constant TIMELOCK = 2 days;

    // ─── Ownership ───
    address public owner;

    // ─── Tax Rates (bps: 0-1000 = 0%-10%) ───
    uint16 public buyFeeRate;
    uint16 public sellFeeRate;
    // Pending rate changes with timelock
    uint16 public pendingBuyFeeRate;
    uint16 public pendingSellFeeRate;
    uint256 public rateChangeUnlockTime;

    // ─── Allocation ratios (base 1000) ───
    uint16 public rateStocks;
    uint16 public rateFundsWallet;
    uint16 public rateBurn;
    uint16 public rateDividend;
    uint16 public rateLiquidity;
    uint16 public rateUnallocated;

    // ─── Anti-Farmer ───
    uint256 public antiFarmerEndTime;
    bool public antiFarmerActive;

    // ─── Fee Accumulators ───
    uint256 public feeToStocks;
    uint256 public feeToFundsWallet;
    uint256 public feeToBurn;
    uint256 public feeToDividend;
    uint256 public feeToLiquidity;
    uint256 public totalTaxCollected;
    uint256 public feeDispatched;
    uint256 public unallocatedBalance; // sweepable surplus

    // ─── Addresses ───
    address public fundsWallet;
    address public stocksVault;

    // ─── Dividend Staking ───
    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public claimableRewards;
    uint256 public totalShares;
    uint256 public feePerShare;
    uint256 public feePerShareAccumulated;
    uint256 public dividendDust; // accumulated precision dust

    // ─── Events ───
    event TaxCollected(address indexed trader, uint256 buyFee, uint256 sellFee, bool isBuy);
    event StocksFeeDeposited(uint256 amount);
    event DividendsClaimed(address indexed user, uint256 amount);
    event FeesDispatched(uint256 stocksAmt, uint256 fundAmt, uint256 burnAmt, uint256 divAmt, uint256 liqAmt);
    event TaxRateChangeScheduled(uint16 newBuyRate, uint16 newSellRate, uint256 unlockTime);
    event TaxRateChangeApplied(uint16 buyRate, uint16 sellRate);
    event UnallocatedSwept(address to, uint256 amount);

    // ─── Modifiers ───
    modifier onlyOwner() {
        require(msg.sender == owner, "ST: not owner");
        _;
    }

    // ─── Initializer ───
    function initialize(OpenFourToken.InitArgs calldata args, StockTaxConfig calldata config)
        external virtual initializer
    {
        __OpenFourToken_init(args);
        __StockTaxToken_init(config);
    }

    function __StockTaxToken_init(StockTaxConfig calldata config) internal {
        require(config.buyFeeRate <= MAX_TAX_RATE, "ST: buy rate >10%");
        require(config.sellFeeRate <= MAX_TAX_RATE, "ST: sell rate >10%");

        uint256 total = uint256(config.rateStocks)
            + config.rateFundsWallet + config.rateBurn
            + config.rateDividend + config.rateLiquidity
            + config.rateUnallocated;
        require(total == TAX_PRECISION, "ST: alloc != 100%");
        require(config.rateStocks == 0 || config.rateDividend == 0, "ST: stocks+dividend");

        require(config.fundsWallet != address(0) || config.rateFundsWallet == 0, "ST: invalid funds wallet");
        require(config.stocksVault != address(0) || config.rateStocks == 0, "ST: invalid stocks vault");

        owner = config.creator != address(0) ? config.creator : msg.sender;
        buyFeeRate = config.buyFeeRate;
        sellFeeRate = config.sellFeeRate;
        rateStocks = config.rateStocks;
        rateFundsWallet = config.rateFundsWallet;
        rateBurn = config.rateBurn;
        rateDividend = config.rateDividend;
        rateLiquidity = config.rateLiquidity;
        rateUnallocated = config.rateUnallocated;
        fundsWallet = config.fundsWallet;
        stocksVault = config.stocksVault;

        if (config.antiFarmerDuration > 0) {
            antiFarmerEndTime = block.timestamp + config.antiFarmerDuration;
            antiFarmerActive = true;
        }
    }

    // ═══════════════════════════════════════════
    //  Tax Rate Management (timelocked)
    // ═══════════════════════════════════════════

    /// @notice Schedule a tax rate change (takes effect after TIMELOCK)
    function scheduleTaxRateChange(uint16 newBuyRate, uint16 newSellRate) external onlyOwner {
        require(newBuyRate <= MAX_TAX_RATE, "ST: buy rate >10%");
        require(newSellRate <= MAX_TAX_RATE, "ST: sell rate >10%");
        pendingBuyFeeRate = newBuyRate;
        pendingSellFeeRate = newSellRate;
        rateChangeUnlockTime = block.timestamp + TIMELOCK;
        emit TaxRateChangeScheduled(newBuyRate, newSellRate, rateChangeUnlockTime);
    }

    /// @notice Apply the scheduled rate change after timelock expires
    function applyTaxRateChange() external {
        require(rateChangeUnlockTime > 0, "ST: no pending change");
        require(block.timestamp >= rateChangeUnlockTime, "ST: timelock active");
        buyFeeRate = pendingBuyFeeRate;
        sellFeeRate = pendingSellFeeRate;
        rateChangeUnlockTime = 0;
        emit TaxRateChangeApplied(buyFeeRate, sellFeeRate);
    }

    // ═══════════════════════════════════════════
    //  Tax Collection
    // ═══════════════════════════════════════════

    function onBondingTrade(address trader, uint256 quoteAmount, uint256 /*tokenAmount*/, bool isBuy)
        external onlyVault
    {
        if (quoteAmount == 0) return;

        uint256 feeRate = isBuy ? buyFeeRate : sellFeeRate;
        if (feeRate == 0) return;

        uint256 tax = quoteAmount * feeRate / MAX_BPS;
        if (tax == 0) return;

        totalTaxCollected += tax;
        _allocateTax(tax);

        emit TaxCollected(trader, isBuy ? tax : 0, isBuy ? 0 : tax, isBuy);
    }

    function _allocateTax(uint256 amount) internal {
        uint256 toStocks = amount * rateStocks / TAX_PRECISION;
        uint256 toFunds = amount * rateFundsWallet / TAX_PRECISION;
        uint256 toBurn = amount * rateBurn / TAX_PRECISION;
        uint256 toDividend = amount * rateDividend / TAX_PRECISION;
        uint256 toLiquidity = amount * rateLiquidity / TAX_PRECISION;
        uint256 unallocated = amount - toStocks - toFunds - toBurn - toDividend - toLiquidity;

        if (toStocks > 0) {
            feeToStocks += toStocks;
            _depositToStocks(toStocks);
        }
        if (toFunds > 0) feeToFundsWallet += toFunds;
        if (toBurn > 0) feeToBurn += toBurn;
        if (toDividend > 0) {
            feeToDividend += toDividend;
            _updateFeePerShare(toDividend);
        }
        if (toLiquidity > 0) feeToLiquidity += toLiquidity;
        if (unallocated > 0) unallocatedBalance += unallocated;
    }

    function _depositToStocks(uint256 amount) internal {
        address sv = stocksVault;
        if (sv == address(0)) return;
        if (sv.code.length > 0) {
            IStocksVault(sv).depositStocksFee{value: amount}(amount);
        } else {
            payable(sv).transfer(amount);
        }
    }

    // ═══════════════════════════════════════════
    //  Fee Dispatch
    // ═══════════════════════════════════════════

    function dispatchFees() external {
        uint256 stocksAmt = feeToStocks;
        uint256 fundAmt = feeToFundsWallet;
        uint256 burnAmt = feeToBurn;
        uint256 liqAmt = feeToLiquidity;

        if (fundAmt > 0 && fundsWallet != address(0)) {
            feeToFundsWallet = 0;
            (bool ok,) = payable(fundsWallet).call{value: fundAmt}("");
            if (!ok) feeToFundsWallet += fundAmt;
        }

        if (stocksAmt > 0 && stocksVault != address(0)) {
            feeToStocks = 0;
            if (stocksVault.code.length > 0) {
                IStocksVault(stocksVault).depositStocksFee{value: stocksAmt}(stocksAmt);
            } else {
                payable(stocksVault).transfer(stocksAmt);
            }
        }

        if (burnAmt > 0) {
            feeToBurn = 0;
            _dispatchBurn(burnAmt);
        }

        if (liqAmt > 0) {
            feeToLiquidity = 0;
        }

        feeDispatched += (stocksAmt + fundAmt + burnAmt + liqAmt);
        emit FeesDispatched(stocksAmt, fundAmt, burnAmt, liqAmt, 0);
    }

    function _dispatchBurn(uint256 amount) internal {
        (bool ok,) = payable(address(0xdead)).call{value: amount}("");
        if (!ok) feeToBurn += amount;
    }

    // ═══════════════════════════════════════════
    //  Governance: sweep unallocated funds
    // ═══════════════════════════════════════════

    /// @notice Sweep accumulated unallocated balance to a destination.
    ///         Can be used to re-route surplus via governance decision.
    function sweepUnallocated(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ST: zero sweep addr");
        require(amount <= unallocatedBalance, "ST: insufficient unallocated");
        unallocatedBalance -= amount;
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "ST: sweep failed");
        emit UnallocatedSwept(to, amount);
    }

    // ═══════════════════════════════════════════
    //  Dividend Staking (precision-fixed)
    // ═══════════════════════════════════════════

    /// @dev Accumulates feePerShare with dust tracking to prevent precision loss.
    ///      When amount < totalShares, the integer division truncates to 0.
    ///      We accumulate the truncated dust and roll it into the next update.
    function _updateFeePerShare(uint256 amount) internal {
        if (totalShares == 0) {
            dividendDust += amount;
            return;
        }
        // Add accumulated dust to this round's amount
        uint256 effective = amount + dividendDust;
        uint256 share = effective * MAGNITUDE / totalShares;
        if (share > 0) {
            feePerShare += share;
            dividendDust = 0;
            feePerShareAccumulated += amount;
        } else {
            // amount too small relative to totalShares — save as dust
            dividendDust = effective;
        }
    }

    function _updateUserReward(address user) internal {
        if (totalShares == 0) return;
        uint256 pending = shares[user] * feePerShare / MAGNITUDE - rewardDebt[user];
        if (pending > 0) {
            claimableRewards[user] += pending;
        }
        rewardDebt[user] = shares[user] * feePerShare / MAGNITUDE;
    }

    function _updateShares(address from, address to, uint256 amount) internal {
        if (from == address(0)) {
            _updateUserReward(to);
            totalShares += amount;
            shares[to] += amount;
            rewardDebt[to] = shares[to] * feePerShare / MAGNITUDE;
        } else if (to == address(0)) {
            _updateUserReward(from);
            totalShares -= amount;
            shares[from] -= amount;
            rewardDebt[from] = shares[from] * feePerShare / MAGNITUDE;
        } else {
            _updateUserReward(from);
            _updateUserReward(to);
            shares[from] -= amount;
            shares[to] += amount;
            rewardDebt[from] = shares[from] * feePerShare / MAGNITUDE;
            rewardDebt[to] = shares[to] * feePerShare / MAGNITUDE;
        }
    }

    function claimDividends() external {
        _updateUserReward(msg.sender);
        uint256 amount = claimableRewards[msg.sender];
        if (amount > 0) {
            claimableRewards[msg.sender] = 0;
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) claimableRewards[msg.sender] = amount;
            else emit DividendsClaimed(msg.sender, amount);
        }
    }

    function collectStocksFee() external {
        uint256 amount = feeToStocks;
        if (amount > 0) {
            feeToStocks = 0;
            if (stocksVault != address(0)) {
                if (stocksVault.code.length > 0) {
                    IStocksVault(stocksVault).depositStocksFee{value: amount}(amount);
                } else {
                    payable(stocksVault).transfer(amount);
                }
            }
        }
    }

    // ═══════════════════════════════════════════
    //  Anti-Farmer: block transfers during protection
    // ═══════════════════════════════════════════

    /// @notice Override _update to enforce anti-farmer transfer blocking.
    ///         During the protection period, transfers to/from V3 LP addresses
    ///         are blocked to keep trading within the bonding curve.
    function _update(address from, address to, uint256 value) internal override {
        // Anti-farmer: block transfers involving migrated DEX pools during protection
        if (antiFarmerActive && block.timestamp < antiFarmerEndTime) {
            if (_blocksBeforeMigration(from, to)) {
                revert("ST: transfer blocked (anti-farmer)");
            }
        }
        _updateShares(from, to, value);
        super._update(from, to, value);
    }

    // ═══════════════════════════════════════════
    //  View helpers
    // ═══════════════════════════════════════════

    function isAntiFarmerActive() external view returns (bool) {
        return antiFarmerActive && block.timestamp < antiFarmerEndTime;
    }

    function getPendingDividend(address user) external view returns (uint256) {
        uint256 pending = shares[user] * feePerShare / MAGNITUDE - rewardDebt[user];
        return claimableRewards[user] + pending;
    }

    receive() external payable {}
}
