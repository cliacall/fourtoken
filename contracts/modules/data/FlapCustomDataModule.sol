// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/IOpenFourCustomDataModule.sol";
import "../interfaces/IOpenFourModuleSchema.sol";
import "../interfaces/ITagDescriptor.sol";

/// @notice Trader statistics tracked by FlapCustomDataModule
struct TraderStats {
    uint256 totalPurchased;
    uint256 totalSold;
    uint256 lastTradeTime;
    uint256 lastTradeBlock;
    bool isV3LiquidityProvider;
}

/// @title FlapCustomDataModule
/// @notice Tracks per-trader stats, migration data, and allocation configuration.
///         Provides hooks for post-trade processing and migration snapshots.
contract FlapCustomDataModule is IOpenFourCustomDataModule, IOpenFourModuleSchema, ITagDescriptor, Initializable {
    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("module.data.flap")));

    address private _core;
    address private _token;
    address private _tradeModule;
    bytes private _initParams;
    bytes4 private _moduleVersion;

    mapping(address => TraderStats) private _traders;
    address[] private _traderList;

    // Migration snapshot
    bool public migrated;
    uint256 public totalRaisedAtMigrate;
    uint256 public totalSaleAtMigrate;

    // Total stats
    uint256 public totalPurchased;
    uint256 public totalSold;
    uint256 public totalTraders;

    constructor() {
        _moduleVersion = bytes4(keccak256(bytes("v1.0.0")));
    }

    /// @notice Initialize with empty data (no params needed)
    function init(bytes calldata data) external initializer {
        _core = msg.sender;
        _initParams = data;
    }

    /// @notice Set token and trade module addresses (called by core after creation)
    function setDependencies(address token_, address tradeModule_) external {
        require(msg.sender == _core, "FCD: not core");
        _token = token_;
        _tradeModule = tradeModule_;
    }

    /// @notice IOpenFourCustomDataModule: called after each bond trade
    function afterHook(
        address trader,
        uint256 quoteAmount,
        uint256 tokenAmount,
        bool isBuy,
        bytes calldata /*data*/
    ) external override {
        require(msg.sender == _core, "FCD: not core");

        TraderStats storage s = _traders[trader];

        // First trade → add to trader list
        if (s.lastTradeTime == 0) {
            _traderList.push(trader);
            totalTraders++;
        }

        if (isBuy) {
            s.totalPurchased += tokenAmount;
            totalPurchased += tokenAmount;
        } else {
            s.totalSold += tokenAmount;
            totalSold += tokenAmount;
        }

        s.lastTradeTime = block.timestamp;
        s.lastTradeBlock = block.number;
    }

    /// @notice IOpenFourCustomDataModule: called on migration
    function onMigrate(bytes calldata /*data*/) external override returns (bytes memory) {
        require(msg.sender == _core, "FCD: not core");
        migrated = true;
        totalRaisedAtMigrate = totalPurchased; // approximate; actual from vault
        totalSaleAtMigrate = totalSold;
        return abi.encode(migrated, totalRaisedAtMigrate, totalSaleAtMigrate);
    }

    // ─── View ───
    function getTraderStats(address trader) external view returns (TraderStats memory) {
        return _traders[trader];
    }

    function getTraderCount() external view returns (uint256) {
        return _traderList.length;
    }

    /// @notice Check if address has purchased tokens (for cross-module reads)
    function totalPurchased(address trader) external view returns (uint256) {
        return _traders[trader].totalPurchased;
    }

    // ─── Schema ───
    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        return ModuleEncodeSchema(new ParamDescriptor[](0));
    }

    function descriptor() external pure override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "module.data.flap";
        version = "v1.0.0";
    }
}
