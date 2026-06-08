// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../../interfaces/IOpenFourCustomDataModule.sol";
import "../../interfaces/IOpenFourModuleSchema.sol";
import {ParamDescriptor, ModuleEncodeSchema} from "../../libraries/OpenFourTypes.sol";

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
contract FlapCustomDataModule is IOpenFourCustomDataModule, IOpenFourModuleSchema, Initializable {
    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("module.data.flap")));

    address private _core;
    address private _token;
    bytes private _initParams;
    string private _moduleVersion;

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
        _disableInitializers();
    }

    /// @notice Initialize with empty data
    function init(address token, address fourCore, bytes calldata params, string calldata moduleVersion)
        external override initializer
    {
        _token = token;
        _core = fourCore;
        _initParams = params;
        _moduleVersion = moduleVersion;
    }

    /// @notice Called after each bond trade to track trader stats
    function afterHook(OpenFourTypes.TradeHookContext calldata ctx)
        external override
    {
        require(msg.sender == _core, "FCD: not core");

        TraderStats storage s = _traders[ctx.trader];

        // First trade -> add to trader list
        if (s.lastTradeTime == 0) {
            _traderList.push(ctx.trader);
            totalTraders++;
        }

        if (ctx.isBuy) {
            s.totalPurchased += ctx.executedAmount;
            totalPurchased += ctx.executedAmount;
        } else {
            s.totalSold += ctx.executedAmount;
            totalSold += ctx.executedAmount;
        }

        s.lastTradeTime = ctx.timestamp;
        s.lastTradeBlock = ctx.blockNumber;
    }

    /// @notice Called on migration
    function onMigrate(OpenFourTypes.MigrateHookContext calldata ctx)
        external override
    {
        require(msg.sender == _core, "FCD: not core");
        migrated = true;
        totalRaisedAtMigrate = ctx.totalRaised;
        totalSaleAtMigrate = 0; // Can be computed from trader stats
    }

    // --- View ---
    function getTraderStats(address trader) external view returns (TraderStats memory) {
        return _traders[trader];
    }

    function getTraderCount() external view returns (uint256) {
        return _traderList.length;
    }

    function getTotalPurchased(address trader) external view returns (uint256) {
        return _traders[trader].totalPurchased;
    }

    // --- Schema ---
    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        return ModuleEncodeSchema("FlapCustomData", 1, new ParamDescriptor[](0));
    }

    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "module.data.flap";
        version = _moduleVersion;
    }
}
