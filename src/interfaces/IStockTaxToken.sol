// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice StockTaxToken configuration passed during token creation
struct StockTaxConfig {
    uint16 buyFeeRate;       // 0-1000 bps (0-10%)
    uint16 sellFeeRate;
    uint16 rateStocks;       // permille (0-1000)
    uint16 rateFundsWallet;
    uint16 rateBurn;
    uint16 rateDividend;
    uint16 rateLiquidity;
    uint16 rateUnallocated;
    uint256 antiFarmerDuration; // seconds, 0 = disabled
    address fundsWallet;
    address stocksVault;
    address creator;         // optional: token owner for governance
}

/// @notice Interface for StockTaxToken
interface IStockTaxToken {
    function initialize(StockTaxConfig calldata config) external;
    function buyFeeRate() external view returns (uint16);
    function sellFeeRate() external view returns (uint16);
    function rateStocks() external view returns (uint16);
    function rateFundsWallet() external view returns (uint16);
    function rateBurn() external view returns (uint16);
    function rateDividend() external view returns (uint16);
    function rateLiquidity() external view returns (uint16);
    function rateUnallocated() external view returns (uint16);
    function antiFarmerEndTime() external view returns (uint256);
    function antiFarmerActive() external view returns (bool);
    function fundsWallet() external view returns (address);
    function stocksVault() external view returns (address);
    function feeToStocks() external view returns (uint256);
    function feeToFundsWallet() external view returns (uint256);
    function feeToBurn() external view returns (uint256);
    function feeToDividend() external view returns (uint256);
    function feeToLiquidity() external view returns (uint256);
    function totalTaxCollected() external view returns (uint256);
    function unallocatedBalance() external view returns (uint256);
    function owner() external view returns (address);
    function onBondingTrade(address trader, uint256 quoteAmount, uint256 tokenAmount, bool isBuy) external;
    function collectStocksFee() external;
    function dispatchFees() external;
    function sweepUnallocated(address to, uint256 amount) external;
    function scheduleTaxRateChange(uint16 newBuyRate, uint16 newSellRate) external;
    function applyTaxRateChange() external;
}
