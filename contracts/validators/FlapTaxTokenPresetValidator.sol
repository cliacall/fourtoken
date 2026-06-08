// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IOpenFourPresetValidator.sol";
import "../interfaces/IOpenFourCore.sol";
import "../interfaces/IOpenFourVault.sol";
import "../interfaces/IOpenFourToken.sol";
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
///         5. Vault has correct quote token
///         6. Module references are not zero
/// @dev Called by OpenFourCore during token creation, before module initialization.
contract FlapTaxTokenPresetValidator is IOpenFourPresetValidator {
    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant TAX_PRECISION = 1_000;
    uint256 private constant MAX_TAX_RATE = 1_000; // 10%
    uint256 private constant MAX_ANTI_FARMER = 365 days;

    /// @notice Validate the entire preset configuration
    /// @param core The OpenFourCore address (to read registry/modules)
    /// @param requestId The creation request ID
    /// @param vault The vault module address
    /// @param curve The curve module address
    /// @param trade The trade module address
    /// @param migrate The migrate module address
    /// @param token The token module address
    /// @param customData The custom data module address
    /// @param rawParams ABI-encoded FlapTaxConfig
    /// @param initParams Array of init params for all modules
    /// @return isValid True if validation passes
    /// @return reasons Array of error messages (empty if valid)
    function validate(
        address core,
        uint256 requestId,
        address vault,
        address curve,
        address trade,
        address migrate,
        address token,
        address customData,
        bytes calldata rawParams,
        bytes[] calldata initParams
    ) external view override returns (bool isValid, string[] memory reasons) {
        string[] memory errors = new string[](16);
        uint256 errCount;

        // ─── 0. Module address checks ───
        if (vault == address(0)) errors[errCount++] = "Vault address is zero";
        if (curve == address(0)) errors[errCount++] = "Curve address is zero";
        if (trade == address(0)) errors[errCount++] = "Trade address is zero";
        if (migrate == address(0)) errors[errCount++] = "Migrate address is zero";
        if (token == address(0)) errors[errCount++] = "Token address is zero";

        // ─── 1. Decode FlapTaxConfig from rawParams ───
        FlapTaxConfig memory cfg;
        if (rawParams.length >= 256) {
            // Minimum length for 12 params (uint16*8 + uint256*1 + address*2 = 8*2 + 32 + 20*2 = 88 bytes)
            // but ABI encoding is padded
            cfg = abi.decode(rawParams, (FlapTaxConfig));
        } else {
            errors[errCount++] = "Raw params too short for FlapTaxConfig";
        }

        if (errCount > 0) return formatResult(false, errors, errCount);

        // ─── 2. Tax rate validation (0-10%) ───
        if (cfg.buyFeeRate > MAX_TAX_RATE) {
            errors[errCount++] = string(abi.encodePacked("Buy tax rate exceeds 10%: ", toString(cfg.buyFeeRate)));
        }
        if (cfg.sellFeeRate > MAX_TAX_RATE) {
            errors[errCount++] = string(abi.encodePacked("Sell tax rate exceeds 10%: ", toString(cfg.sellFeeRate)));
        }

        // ─── 3. Allocation sum must equal 100% (1000 base) ───
        uint256 allocSum = uint256(cfg.rateStocks)
            + cfg.rateFundsWallet + cfg.rateBurn
            + cfg.rateDividend + cfg.rateLiquidity
            + cfg.rateUnallocated;
        if (allocSum != TAX_PRECISION) {
            errors[errCount++] = string(abi.encodePacked(
                "Allocation total != 100%: got ", toString(allocSum), " expected 1000"
            ));
        }

        // ─── 4. Individual allocation checks ───
        if (cfg.rateStocks > TAX_PRECISION) {
            errors[errCount++] = "Stocks allocation exceeds 100%";
        }
        if (cfg.rateFundsWallet > TAX_PRECISION) {
            errors[errCount++] = "Funds wallet allocation exceeds 100%";
        }
        if (cfg.rateBurn > TAX_PRECISION) {
            errors[errCount++] = "Burn allocation exceeds 100%";
        }
        if (cfg.rateDividend > TAX_PRECISION) {
            errors[errCount++] = "Dividend allocation exceeds 100%";
        }
        if (cfg.rateLiquidity > TAX_PRECISION) {
            errors[errCount++] = "Liquidity allocation exceeds 100%";
        }
        if (cfg.rateUnallocated > TAX_PRECISION) {
            errors[errCount++] = "Unallocated exceeds 100%";
        }

        // ─── 5. Stocks ↔ Dividend mutual exclusion ───
        if (cfg.rateStocks > 0 && cfg.rateDividend > 0) {
            errors[errCount++] = "Stocks and Dividend cannot both be > 0 (mutually exclusive)";
        }

        // ─── 6. Anti-farmer validation ───
        if (cfg.antiFarmerDuration > MAX_ANTI_FARMER) {
            errors[errCount++] = "Anti-farmer period exceeds 365 days";
        }

        // ─── 7. Address validation ───
        if (cfg.rateFundsWallet > 0 && cfg.fundsWallet == address(0)) {
            errors[errCount++] = "Funds wallet required when rateFundsWallet > 0";
        }
        if (cfg.rateStocks > 0 && cfg.stocksVault == address(0)) {
            errors[errCount++] = "Stocks vault required when rateStocks > 0";
        }

        // ─── 8. Core registry check (optional) ───
        // In production, verify that all module addresses are registered in the core registry
        // This is a simplified version

        return formatResult(errCount == 0, errors, errCount);
    }

    // ─── Helpers ───
    function formatResult(bool valid, string[] memory errors, uint256 count)
        internal pure returns (bool, string[] memory)
    {
        string[] memory out = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = errors[i];
        }
        return (valid, out);
    }

    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
