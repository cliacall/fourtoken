// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Stocks Vault — accumulates tax-allocated stocks fees and executes buyback
interface IStocksVault {
    struct StocksConfig {
        address buybackToken;      // Token to buy back (usually quote token)
        address oracle;            // Optional oracle for RWA pricing
        uint256 minBuybackAmount;  // Min amount to trigger buyback
        uint256 buybackInterval;   // Min seconds between buybacks
        bool autoBuyback;          // Auto-execute buyback when threshold met
    }

    function init(StocksConfig calldata config) external;
    function depositStocksFee(uint256 amount) external payable;
    function executeBuyback() external returns (uint256 tokensBought);
    function stocksAccumulated() external view returns (uint256);
    function lastBuybackTime() external view returns (uint256);
    function totalBuybackExecuted() external view returns (uint256);
    function buybackToken() external view returns (address);
    function setAutoBuyback(bool enabled) external;
    function setMinBuybackAmount(uint256 amount) external;
    function withdrawReserve(address to, uint256 amount) external;
    function config() external view returns (StocksConfig memory);
}
