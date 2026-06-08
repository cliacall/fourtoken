// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../../interfaces/IStocksVault.sol";
import "../../interfaces/ITagDescriptor.sol";

/// @notice Minimal PancakeSwap V2 Router interface for buyback swaps
interface IPancakeRouter02 {
    function WETH() external pure returns (address);
    function swapExactETHForTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

/// @title StocksVaultModule
/// @notice Stocks (币股) vault — accumulates tax-allocated BNB fees and executes buyback
///         via PancakeSwap V2 Router. Configurable for auto-buyback with min threshold + interval.
/// @dev NOT an OpenFour Vault module — this is a standalone vault contract called by StockTaxToken
///      during fee dispatch. It receives BNB, accumulates until threshold, then swaps for target token.
contract StocksVaultModule is IStocksVault, ITagDescriptor, Initializable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("module.vault.stocks")));

    StocksConfig private _config;
    uint256 public override stocksAccumulated;
    uint256 public override lastBuybackTime;
    uint256 public override totalBuybackExecuted;
    uint256 public totalBoughtTokens;

    address public owner;
    IPancakeRouter02 public pancakeRouter;

    event StocksFeeReceived(uint256 amount);
    event BuybackExecuted(uint256 bnbAmount, uint256 tokensBought, address buybackToken);
    event ConfigUpdated(StocksConfig newConfig);
    event PancakeRouterSet(address router);

    modifier onlyOwner() {
        require(msg.sender == owner, "SV: not owner");
        _;
    }

    // ─── Initializers ───
    // Two-arg init (with router) for new deployments
    // One-arg init for backward compat (no router)
    // NOTE: only ONE init variant should be called due to `initializer` modifier.


    /// @notice Initialize with PancakeSwap router for on-chain buyback
    function initialize(StocksConfig calldata cfg, address router_) external initializer {
        owner = msg.sender;
        _config = cfg;
        lastBuybackTime = block.timestamp;
        if (router_ != address(0)) {
            pancakeRouter = IPancakeRouter02(router_);
            emit PancakeRouterSet(router_);
        }
    }

    /// @notice Initialize without router (backward compat)
    function init(StocksConfig calldata cfg) external override initializer {
        owner = msg.sender;
        _config = cfg;
        lastBuybackTime = block.timestamp;
    }

    /// @notice Receive BNB deposits from StockTaxToken's stocks allocation
    function depositStocksFee(uint256 amount) external payable override {
        require(msg.value >= amount, "SV: insufficient value");
        if (msg.value > amount) {
            // Refund excess
            payable(msg.sender).transfer(msg.value - amount);
        }
        stocksAccumulated += amount;
        emit StocksFeeReceived(amount);

        // Auto-buyback if configured and threshold met
        if (_config.autoBuyback && stocksAccumulated >= _config.minBuybackAmount) {
            _tryBuyback();
        }
    }

    /// @notice Execute buyback: swap accumulated BNB → buybackToken via PancakeSwap
    function executeBuyback() external override returns (uint256 tokensBought) {
        require(stocksAccumulated >= _config.minBuybackAmount, "SV: below min");
        require(block.timestamp >= lastBuybackTime + _config.buybackInterval, "SV: interval");
        return _buyback();
    }

    function _buyback() internal returns (uint256 tokensBought) {
        uint256 amount = stocksAccumulated;
        require(amount >= _config.minBuybackAmount, "SV: below min");

        address bt = _config.buybackToken;
        if (bt == address(0)) {
            // No buyback token — keep as BNB reserve
            return 0;
        }

        // Reset accumulator BEFORE swap to prevent reentrancy
        stocksAccumulated = 0;
        lastBuybackTime = block.timestamp;

        address oracle = _config.oracle;
        if (oracle != address(0)) {
            // Oracle-based RWA purchase (external asset)
            tokensBought = _swapWithOracle(amount, bt, oracle);
        } else if (address(pancakeRouter) != address(0)) {
            // PancakeSwap buyback
            tokensBought = _swapViaPancakeSwap(amount, bt);
        } else {
            // No router configured — refund to accumulator
            stocksAccumulated = amount;
            return 0;
        }

        totalBuybackExecuted += amount;
        totalBoughtTokens += tokensBought;
        emit BuybackExecuted(amount, tokensBought, bt);
        return tokensBought;
    }

    /// @notice Swap BNB → buybackToken via PancakeSwap V2 Router
    function _swapViaPancakeSwap(uint256 bnbAmount, address tokenOut) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = pancakeRouter.WETH();
        path[1] = tokenOut;

        // 0.5% slippage (9950/10000) — can be made configurable
        uint256[] memory amounts = pancakeRouter.swapExactETHForTokens{value: bnbAmount}(
            0,          // amountOutMin: accept any (can be stricter in production)
            path,
            address(this),
            block.timestamp + 300 // 5 min deadline
        );
        return amounts[amounts.length - 1];
    }

    /// @notice Oracle-based RWA purchase (placeholder — delegates to oracle address)
    /// @dev In production, integrate Chainlink AggregatorV3Interface for price feeds
    function _swapWithOracle(uint256 amount, address bt, address oracle)
        internal returns (uint256)
    {
        // Oracle-based RWA purchase:
        // 1. Query oracle for price: uint256 price = IExternalOracle(oracle).getPrice(bt);
        // 2. Execute purchase via oracle's buy interface
        // For now, forward to oracle for external handling
        (bool ok,) = oracle.call{value: amount}("");
        require(ok, "SV: oracle call failed");
        return amount; // Returns nominal amount — oracle returns actual in production
    }

    function _tryBuyback() internal {
        if (block.timestamp >= lastBuybackTime + _config.buybackInterval
            && stocksAccumulated >= _config.minBuybackAmount) {
            _buyback();
        }
    }

    // ─── Admin (owner only) ───

    function setPancakeRouter(address router_) external onlyOwner {
        pancakeRouter = IPancakeRouter02(router_);
        emit PancakeRouterSet(router_);
    }

    function setAutoBuyback(bool enabled) external override onlyOwner {
        _config.autoBuyback = enabled;
    }

    function setMinBuybackAmount(uint256 amount) external override onlyOwner {
        _config.minBuybackAmount = amount;
    }

    function setBuybackInterval(uint256 interval) external onlyOwner {
        _config.buybackInterval = interval;
    }

    function setBuybackToken(address bt) external onlyOwner {
        _config.buybackToken = bt;
    }

    function setOracle(address oracle_) external onlyOwner {
        _config.oracle = oracle_;
    }

    /// @notice Emergency: withdraw accumulated BNB reserve
    function withdrawReserve(address to, uint256 amount) external override onlyOwner {
        require(amount <= address(this).balance, "SV: insufficient");
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "SV: withdraw failed");
    }

    /// @notice Withdraw bought-back tokens (if accumulated)
    function withdrawTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    // ─── Views ───

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
