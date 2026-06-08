// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../tokens/OpenFourToken.sol";
import "../interfaces/IFlapTaxToken.sol";
import "../interfaces/IStocksVault.sol";
import "../interfaces/IOpenFourVault.sol";

/// @title FlapTaxToken
/// @notice Flap.sh-style tax token with Stocks (币股), Funds Wallet, Burn, Dividend, Liquidity allocation.
///         Extends OpenFourToken with tax collection and distribution on bonding + DEX trades.
/// @dev Allocation rates must sum to 1000 (100%). Stocks > 0 forces Dividend = 0.
contract FlapTaxToken is OpenFourToken {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 private constant MAX_BPS = 10_000;     // 100%
    uint256 private constant TAX_PRECISION = 1_000; // allocation base = 1000 (100%)
    uint256 private constant MAX_TAX_RATE = 1_000;  // 10%
    uint256 private constant MAGNITUDE = 1e18;

    // ─── Tax Rates (bps: 0-1000 = 0%-10%) ───
    uint16 public buyFeeRate;
    uint16 public sellFeeRate;

    // ─── Allocation ratios (base 1000) ───
    uint16 public rateStocks;
    uint16 public rateFundsWallet;
    uint16 public rateBurn;
    uint16 public rateDividend;
    uint16 public rateLiquidity;
    uint16 public rateUnallocated;

    // ─── Anti-Farmer ───
    /// @notice Timestamp after which V3 LP provisioning is allowed
    uint256 public antiFarmerEndTime;
    /// @notice Tracks first trade timestamp per chain ID (enforced by core flag)
    bool public antiFarmerSeeded;

    // ─── Fee Accumulators (quote token — BNB/WBNB) ───
    uint256 public feeToStocks;
    uint256 public feeToFundsWallet;
    uint256 public feeToBurn;
    uint256 public feeToDividend;
    uint256 public feeToLiquidity;
    uint256 public totalTaxCollected;
    uint256 public feeDispatched;

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

    // ─── Constants ───
    bytes32 private constant _INIT_STOCKS_SLOT = keccak256("flap.tax.init.stocks");

    // ─── Events ───
    event TaxCollected(address indexed trader, uint256 buyFee, uint256 sellFee, bool isBuy);
    event StocksFeeDeposited(uint256 amount);
    event DividendsClaimed(address indexed user, uint256 amount);
    event FeesDispatched(uint256 stocksAmt, uint256 fundAmt, uint256 burnAmt, uint256 divAmt, uint256 liqAmt);

    // ─── Modifiers ───
    modifier onlyStocksVault() {
        require(msg.sender == stocksVault, "FT: not stocks vault");
        _;
    }

    modifier onlyTaxVault() {
        require(msg.sender == vault, "FT: not vault");
        _;
    }

    // ─── Initializer ───
    function initialize(OpenFourToken.InitArgs calldata args, FlapTaxConfig calldata config)
        external virtual initializer
    {
        __OpenFourToken_init(args);
        __FlapTaxToken_init(config);
    }

    function __FlapTaxToken_init(FlapTaxConfig calldata config) internal {
        require(config.buyFeeRate <= MAX_TAX_RATE, "FT: buy rate >10%");
        require(config.sellFeeRate <= MAX_TAX_RATE, "FT: sell rate >10%");

        uint256 total = uint256(config.rateStocks)
            + config.rateFundsWallet + config.rateBurn
            + config.rateDividend + config.rateLiquidity
            + config.rateUnallocated;
        require(total == TAX_PRECISION, "FT: alloc != 100%");
        require(config.rateStocks == 0 || config.rateDividend == 0, "FT: stocks+dividend");

        require(config.fundsWallet != address(0) || config.rateFundsWallet == 0, "FT: invalid funds wallet");
        require(config.stocksVault != address(0) || config.rateStocks == 0, "FT: invalid stocks vault");

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
        }

        // Mint everything to vault (standard OpenFour pattern)
        // _mint happens in OpenFourToken.__OpenFourToken_init
    }

    // ═══════════════════════════════════════════
    //  Tax Collection (called by Core during bonding / DEX trades)
    // ═══════════════════════════════════════════

    /// @notice Called by the Vault (via Core) on bonding-curve trades to collect quote tax.
    /// @dev The quote amount is msg.value or transfer amount; the vault forwards it here.
    function onBondingTrade(address trader, uint256 quoteAmount, uint256 tokenAmount, bool isBuy)
        external onlyTaxVault
    {
        if (quoteAmount == 0) return;

        uint256 feeRate = isBuy ? buyFeeRate : sellFeeRate;
        if (feeRate == 0) return;

        uint256 tax = quoteAmount * feeRate / MAX_BPS;
        if (tax == 0) return;

        // Seed anti-farmer timer on first trade
        if (!antiFarmerSeeded && antiFarmerEndTime > block.timestamp) {
            antiFarmerSeeded = true;
        }

        totalTaxCollected += tax;
        _allocateTax(tax);

        emit TaxCollected(trader, isBuy ? tax : 0, isBuy ? 0 : tax, isBuy);
    }

    /// @notice Allocate collected tax across categories
    function _allocateTax(uint256 amount) internal {
        uint256 toStocks = amount * rateStocks / TAX_PRECISION;
        uint256 toFunds = amount * rateFundsWallet / TAX_PRECISION;
        uint256 toBurn = amount * rateBurn / TAX_PRECISION;
        uint256 toDividend = amount * rateDividend / TAX_PRECISION;
        uint256 toLiquidity = amount * rateLiquidity / TAX_PRECISION;
        // unallocated stays in contract as surplus

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
    }

    /// @notice Send stocks-allocated fees to the StocksVault
    function _depositToStocks(uint256 amount) internal {
        address sv = stocksVault;
        if (sv == address(0)) return;
        // Forward to StocksVault via its deposit interface
        if (sv.code.length > 0) {
            IStocksVault(sv).depositStocksFee{value: amount}(amount);
        } else {
            payable(sv).transfer(amount);
        }
    }

    // ═══════════════════════════════════════════
    //  Fee Dispatch
    // ═══════════════════════════════════════════

    /// @notice Manually trigger fee dispatch to all destinations.
    /// Can be called by anyone or automatically via the core afterHook.
    function dispatchFees() external {
        uint256 stocksAmt = feeToStocks;
        uint256 fundAmt = feeToFundsWallet;
        uint256 burnAmt = feeToBurn;
        uint256 liqAmt = feeToLiquidity;

        if (fundAmt > 0 && fundsWallet != address(0)) {
            feeToFundsWallet = 0;
            // Use call{value} for safe transfer (send can fail silently)
            (bool ok,) = payable(fundsWallet).call{value: fundAmt}("");
            if (!ok) feeToFundsWallet += fundAmt; // Refund on failure
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
            // Liquidity addition is handled by the migration module
            // Accumulate for now, dispatched on migration
        }

        feeDispatched += (stocksAmt + fundAmt + burnAmt + liqAmt);

        emit FeesDispatched(stocksAmt, fundAmt, burnAmt, liqAmt, 0);
    }

    function _dispatchBurn(uint256 amount) internal {
        // Burn: send BNB to DEAD. On failure, refund to feeToBurn accumulator.
        (bool ok,) = payable(address(0xdead)).call{value: amount}("");
        if (!ok) feeToBurn += amount;
    }

    // ═══════════════════════════════════════════
    //  Dividend Staking
    // ═══════════════════════════════════════════

    function _updateFeePerShare(uint256 amount) internal {
        if (totalShares == 0) {
            feePerShareAccumulated += amount;
            return;
        }
        uint256 share = amount * MAGNITUDE / totalShares;
        feePerShare += share;
        feePerShareAccumulated += amount;
    }

    function _updateUserReward(address user) internal {
        if (totalShares == 0) return;
        uint256 pending = shares[user] * feePerShare / MAGNITUDE - rewardDebt[user];
        if (pending > 0) {
            claimableRewards[user] += pending;
        }
        rewardDebt[user] = shares[user] * feePerShare / MAGNITUDE;
    }

    /// @notice Must be called on every transfer to keep dividend accounting accurate
    function _updateShares(address from, address to, uint256 amount) internal {
        if (from == address(0)) {
            // Mint: increase shares
            _updateUserReward(to);
            totalShares += amount;
            shares[to] += amount;
            rewardDebt[to] = shares[to] * feePerShare / MAGNITUDE;
        } else if (to == address(0)) {
            // Burn: decrease shares
            _updateUserReward(from);
            totalShares -= amount;
            shares[from] -= amount;
            rewardDebt[from] = shares[from] * feePerShare / MAGNITUDE;
        } else {
            // Transfer
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
            if (!ok) claimableRewards[msg.sender] = amount; // Refund on failure
            else emit DividendsClaimed(msg.sender, amount);
        }
    }

    /// @notice External: collect stocks fee directly (called by StocksVault or core)
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
    //  ERC20 Override — track shares on transfer
    // ═══════════════════════════════════════════

    function _update(address from, address to, uint256 value) internal override {
        // Track shares for dividend staking (mint, transfer, burn)
        _updateShares(from, to, value);
        super._update(from, to, value);
    }

    // ═══════════════════════════════════════════
    //  View helpers
    // ═══════════════════════════════════════════

    function isAntiFarmerActive() external view returns (bool) {
        return antiFarmerEndTime > block.timestamp && antiFarmerSeeded;
    }

    function getPendingDividend(address user) external view returns (uint256) {
        uint256 pending = shares[user] * feePerShare / MAGNITUDE - rewardDebt[user];
        return claimableRewards[user] + pending;
    }

    receive() external payable {}
}
