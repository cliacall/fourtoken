// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IOpenFourPresetValidator.sol";
import "../interfaces/IFlapTaxToken.sol";
import "../interfaces/IStocksVault.sol";
import "../libraries/OpenFourTypes.sol";

/// @title FlapTaxTokenPresetValidator
/// @notice Preset validator for FlapTaxToken preset.
///         Validates:
///         1. Tax rate 0-10% (0-1000 bps)
///         2. All allocation percentages sum to 100% (1000 base)
///         3. Anti-farmer parameters are legal
///         4. Stocks > 0 → Dividend must be 0 (mutual exclusion)
///         5. Address references are non-zero
/// @dev Called by OpenFourCore during token creation, before module initialization.
contract FlapTaxTokenPresetValidator is IOpenFourPresetValidator {
    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant TAX_PRECISION = 1_000;
    uint256 private constant MAX_TAX_RATE = 1_000; // 10%
    uint256 private constant MAX_ANTI_FARMER = 365 days;

    /// @notice Validate the entire preset configuration
    /// @param presetId The preset ID (unused, for interface compatibility)
    /// @param params TokenInitParams containing tokenParams with ABI-encoded FlapTaxConfig
    function validate(
        uint256 presetId,
        OpenFourTypes.TokenInitParams calldata params
    ) external view override {
        // Decode FlapTaxConfig from tokenParams
        require(params.tokenParams.length >= 256, "FlapVal: params too short");
        FlapTaxConfig memory cfg = abi.decode(params.tokenParams, (FlapTaxConfig));

        // 1. Tax rate validation (0-10%)
        require(cfg.buyFeeRate <= MAX_TAX_RATE, "FlapVal: buy tax > 10%");
        require(cfg.sellFeeRate <= MAX_TAX_RATE, "FlapVal: sell tax > 10%");

        // 2. Allocation sum must equal 100% (1000 base)
        uint256 allocSum = uint256(cfg.rateStocks)
            + cfg.rateFundsWallet + cfg.rateBurn
            + cfg.rateDividend + cfg.rateLiquidity
            + cfg.rateUnallocated;
        require(allocSum == TAX_PRECISION, "FlapVal: alloc != 100%");

        // 3. Individual allocation caps
        require(cfg.rateStocks <= TAX_PRECISION, "FlapVal: stocks > 100%");
        require(cfg.rateFundsWallet <= TAX_PRECISION, "FlapVal: funds > 100%");
        require(cfg.rateBurn <= TAX_PRECISION, "FlapVal: burn > 100%");
        require(cfg.rateDividend <= TAX_PRECISION, "FlapVal: dividend > 100%");
        require(cfg.rateLiquidity <= TAX_PRECISION, "FlapVal: liquidity > 100%");
        require(cfg.rateUnallocated <= TAX_PRECISION, "FlapVal: unallocated > 100%");

        // 4. Stocks ↔ Dividend mutual exclusion
        require(
            cfg.rateStocks == 0 || cfg.rateDividend == 0,
            "FlapVal: stocks & dividend both set"
        );

        // 5. Anti-farmer validation
        require(cfg.antiFarmerDuration <= MAX_ANTI_FARMER, "FlapVal: anti-farmer > 365d");

        // 6. Address validation
        if (cfg.rateFundsWallet > 0) {
            require(cfg.fundsWallet != address(0), "FlapVal: fundsWallet required");
        }
        if (cfg.rateStocks > 0) {
            require(cfg.stocksVault != address(0), "FlapVal: stocksVault required");
        }
    }
}
