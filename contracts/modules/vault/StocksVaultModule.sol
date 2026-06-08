// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../interfaces/IStocksVault.sol";
import "../interfaces/ITagDescriptor.sol";

/// @title StocksVaultModule
/// @notice Flap.sh Stocks (币股) vault — accumulates tax-allocated fees and executes buyback.
///         Can be configured to buy RWA assets externally or perform on-chain buyback.
/// @dev Module that receives stocks-allocated BNB tax and manages buyback logic.
contract StocksVaultModule is IStocksVault, ITagDescriptor, Initializable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("module.vault.stocks")));

    StocksConfig private _config;
    uint256 public override stocksAccumulated;
    uint256 public override lastBuybackTime;
    uint256 public override totalBuybackExecuted;

    address public owner;

    event StocksFeeReceived(uint256 amount);
    event BuybackExecuted(uint256 amount, uint256 tokensBought, address buybackToken);
    event ConfigUpdated(StocksConfig newConfig);

    modifier onlyOwner() {
        require(msg.sender == owner, "SV: not owner");
        _;
    }

    function init(StocksConfig calldata config) external override initializer {
        owner = msg.sender;
        _config = config;
        lastBuybackTime = block.timestamp;
    }

    /// @notice Receive deposits from FlapTaxToken's stocks allocation
    function depositStocksFee(uint256 amount) external payable override {
        require(msg.value == amount || amount > 0, "SV: value mismatch");
        stocksAccumulated += amount;
        emit StocksFeeReceived(amount);

        // Auto-buyback if configured
        if (_config.autoBuyback && amount >= _config.minBuybackAmount) {
            _tryBuyback();
        }
    }

    /// @notice Execute buyback: swap accumulated BNB for buyback token
    function executeBuyback() external override returns (uint256 tokensBought) {
        return _buyback();
    }

    function _buyback() internal returns (uint256) {
        require(block.timestamp >= lastBuybackTime + _config.buybackInterval, "SV: interval");
        uint256 amount = stocksAccumulated;
        require(amount >= _config.minBuybackAmount, "SV: below min");

        stocksAccumulated = 0;
        lastBuybackTime = block.timestamp;

        address bt = _config.buybackToken;
        if (bt == address(0)) {
            // No buyback token configured — keep as BNB reserve
            stocksAccumulated = amount;
            return 0;
        }

        address oracle = _config.oracle;
        uint256 bought;

        if (oracle != address(0)) {
            // Use oracle for RWA pricing (external call, simplified)
            // In production, integrate Chainlink or similar
            bought = _swapWithOracle(amount, bt, oracle);
        } else {
            // Simple on-chain buyback: swap via DEX (simplified)
            bought = _simpleBuyback(amount, bt);
        }

        totalBuybackExecuted += bought;
        emit BuybackExecuted(amount, bought, bt);
        return bought;
    }

    function _tryBuyback() internal {
        if (block.timestamp >= lastBuybackTime + _config.buybackInterval
            && stocksAccumulated >= _config.minBuybackAmount) {
            _buyback();
        }
    }

    /// @notice Placeholder for oracle-based RWA purchase
    function _swapWithOracle(uint256 amount, address buybackToken, address oracle)
        internal returns (uint256)
    {
        // In production: call oracle to get price, execute swap
        // For now, simple transfer to oracle for external handling
        payable(oracle).send(amount);
        return amount; // Returns nominal amount
    }

    /// @notice Simple buyback via PancakeSwap or similar
    /// @dev This is a simplified version; production would use exact router calls
    function _simpleBuyback(uint256 amount, address buybackToken) internal returns (uint256) {
        // In production, use PancakeSwap Router to swap BNB → token
        // For now, just track as pending buyback
        return 0;
    }

    // ─── Admin ───

    function setAutoBuyback(bool enabled) external override onlyOwner {
        _config.autoBuyback = enabled;
    }

    function setMinBuybackAmount(uint256 amount) external override onlyOwner {
        _config.minBuybackAmount = amount;
    }

    function withdrawReserve(address to, uint256 amount) external override onlyOwner {
        require(amount <= address(this).balance, "SV: insufficient");
        payable(to).send(amount);
    }

    function config() external view override returns (StocksConfig memory) {
        return _config;
    }

    function buybackToken() external view override returns (address) {
        return _config.buybackToken;
    }

    // ─── Tag ───
    function descriptor() external pure override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "module.vault.stocks";
        version = "v1.0.0";
    }

    receive() external payable {}
}
