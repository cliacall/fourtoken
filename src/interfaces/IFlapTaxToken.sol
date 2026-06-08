// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice FlapTaxToken configuration passed during token creation
struct FlapTaxConfig {
    // Tax rates in bps (0-1000 = 0%-10%)
    uint16 buyFeeRate;
    uint16 sellFeeRate;
    // Allocation ratios, must sum to 1000 (100%)
    uint16 rateStocks;
    uint16 rateFundsWallet;
    uint16 rateBurn;
    uint16 rateDividend;
    uint16 rateLiquidity;
    uint16 rateUnallocated;
    // Anti-farmer: seconds after first trade during which V3 LP is blocked
    uint256 antiFarmerDuration;
    // Addresses
    address fundsWallet;
    address stocksVault;
}

/// @notice Interface for FlapTaxToken
interface IFlapTaxToken {
    function initialize(FlapTaxConfig calldata config) external;
    function buyFeeRate() external view returns (uint16);
    function sellFeeRate() external view returns (uint16);
    function rateStocks() external view returns (uint16);
    function rateFundsWallet() external view returns (uint16);
    function rateBurn() external view returns (uint16);
    function rateDividend() external view returns (uint16);
    function rateLiquidity() external view returns (uint16);
    function rateUnallocated() external view returns (uint16);
    function antiFarmerEndTime() external view returns (uint256);
    function fundsWallet() external view returns (address);
    function stocksVault() external view returns (address);
    function feeToStocks() external view returns (uint256);
    function feeToFundsWallet() external view returns (uint256);
    function feeToBurn() external view returns (uint256);
    function feeToDividend() external view returns (uint256);
    function feeToLiquidity() external view returns (uint256);
    function totalTaxCollected() external view returns (uint256);
    function onBondingTrade(address trader, uint256 quoteAmount, uint256 tokenAmount, bool isBuy) external;
    function collectStocksFee() external;
    function dispatchFees() external;
}
