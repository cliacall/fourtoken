// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/ITagDescriptor.sol";
import "../libraries/OpenFourTypes.sol";

/// @title StockTaxPreset
/// @notice Preset orchestrator for on-chain Tax Token with Stocks (币股) functionality.
///         Defines the module composition, validator, and preset metadata.
/// @dev This contract is registered with OpenFourCore to allow users to create StockTaxToken instances
///      through a single preset selection rather than selecting individual modules.
contract StockTaxPreset is ITagDescriptor {
    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("preset.stock_tax")));

    // ─── Preset Configuration ───
    error InvalidPresetConfiguration(string reason);

    struct PresetConfig {
        uint256 presetId;
        address validator;
        address tokenModule;
        address vaultModule;
        address curveModule;
        address tradeModule;
        address migrateModule;
        address customDataModule;
    }

    PresetConfig private _config;
    string private _version;

    event PresetConfigured(uint256 indexed presetId, address indexed tokenModule);
    event PresetModulesUpdated(uint256 indexed presetId);

    constructor(PresetConfig memory cfg, string memory version_) {
        require(cfg.tokenModule != address(0), "SP: zero token module");
        require(cfg.vaultModule != address(0), "SP: zero vault module");
        require(cfg.curveModule != address(0), "SP: zero curve module");
        require(cfg.tradeModule != address(0), "SP: zero trade module");
        require(cfg.presetId != 0, "SP: zero presetId");

        _config = cfg;
        _version = version_;
        emit PresetConfigured(cfg.presetId, cfg.tokenModule);
    }

    // ─── Getters ───

    /// @notice Returns the preset ID
    function presetId() external view returns (uint256) {
        return _config.presetId;
    }

    /// @notice Returns the preset name tag
    function presetName() public pure returns (string memory) {
        return "StockTaxToken";
    }

    /// @notice Returns human-readable description
    function presetDescription() public pure returns (string memory) {
        return unicode"on-chain Tax Token with Stocks (币股), Burn, Dividend, and Liquidity allocation";
    }

    /// @notice Returns the validator contract for this preset
    function validator() external view returns (address) {
        return _config.validator;
    }

    /// @notice Returns all module addresses used by this preset
    function getModules() external view returns (OpenFourTypes.Preset memory) {
        return OpenFourTypes.Preset({
            id: _config.presetId,
            name: presetName(),
            description: presetDescription(),
            version: _version,
            active: true,
            createEnabled: true,
            validator: _config.validator,
            tokenModuleId: bytes32(keccak256(bytes("module.token.stock_tax"))),
            vaultModuleId: bytes32(keccak256(bytes("module.vault.standard"))),
            curveModuleId: bytes32(keccak256(bytes("module.curve.fixed_price"))),
            tradeModuleId: bytes32(keccak256(bytes("module.trade.guarded"))),
            migrateModuleId: bytes32(keccak256(bytes("module.migrate.timed"))),
            tokenImplId: bytes32(keccak256(bytes("token.flap_tax"))),
            customDataId: bytes32(keccak256(bytes("module.data.tracker"))),
            author: address(this)
        });
    }

    // ─── ITagDescriptor ───
    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "preset.stock_tax";
        version = _version;
    }
}
