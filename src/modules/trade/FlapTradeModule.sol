// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/IOpenFourTradeModule.sol";
import "../../interfaces/IOpenFourModuleSchema.sol";
import "../../interfaces/ITagDescriptor.sol";
import "../../tokens/FlapTaxToken.sol";
import {OpenFourTypes, ParamDescriptor, ModuleEncodeSchema} from "../../libraries/OpenFourTypes.sol";

/// @title FlapTradeModule
/// @notice Trade module for FlapTaxToken preset.
///         Enforces max buy/sell limits per address and anti-farmer protection.
contract FlapTradeModule is IOpenFourTradeModule, IOpenFourModuleSchema, Initializable {
    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("module.trade.flap")));

    struct TradeConfig {
        uint256 maxBuyAmount;     // Max quote per buy (0 = unlimited)
        uint256 maxPerAddress;    // Max total token holdings per address (0 = unlimited)
        uint256 maxSellAmount;    // Max token amount per sell (0 = unlimited)
        uint16 buyFeeBps;         // Additional buy fee (bps)
        uint16 sellFeeBps;        // Additional sell fee (bps)
        address feeRecipient;     // Fee recipient address
    }

    TradeConfig private _config;
    address private _token;
    address private _core;
    bytes private _initParams;
    string private _moduleVersion;

    // Anti-farmer: track addresses that added V3 liquidity (blocked during protection period)
    mapping(address => bool) public v3LiquidityProviders;

    event V3LiquidityBlocked(address indexed provider);

    constructor() {
        _disableInitializers();
    }

    function init(address token, address fourCore, bytes calldata params, string calldata moduleVersion)
        external override initializer
    {
        require(fourCore != address(0), "FTM: zero fourCore");
        _core = fourCore;
        _token = token;
        TradeConfig memory cfg = abi.decode(params, (TradeConfig));
        require(cfg.buyFeeBps <= 10_000, "FTM: buy fee bps");
        require(cfg.sellFeeBps <= 10_000, "FTM: sell fee bps");
        _config = cfg;
        _initParams = params;
        _moduleVersion = moduleVersion;
    }

    /// @notice Evaluate whether a trade is allowed.
    function evaluate(OpenFourTypes.TradeContext calldata ctx)
        external
        view
        override
        returns (OpenFourTypes.TradeResult memory result)
    {
        require(_token != address(0), "FTM: no token");

        bool allowed = true;
        uint256 minAmt = 0;
        uint256 maxAmt = type(uint256).max;
        string memory reason;

        if (ctx.isBuy) {
            // Max buy amount check
            if (_config.maxBuyAmount > 0 && ctx.curveQuote > _config.maxBuyAmount) {
                allowed = false;
                reason = "over max buy";
            }
            // Max per address check
            if (allowed && _config.maxPerAddress > 0) {
                uint256 balance = IERC20(_token).balanceOf(ctx.trader);
                if (balance + ctx.amount > _config.maxPerAddress) {
                    allowed = false;
                    reason = "over max per address";
                }
            }
        } else {
            // Anti-farmer: block sells from V3 liquidity providers
            if (v3LiquidityProviders[ctx.trader]) {
                FlapTaxToken taxToken = FlapTaxToken(payable(_token));
                if (taxToken.isAntiFarmerActive()) {
                    allowed = false;
                    reason = "anti-farmer: V3 LP provider";
                }
            }
            // Max sell amount check
            if (allowed && _config.maxSellAmount > 0 && ctx.amount > _config.maxSellAmount) {
                allowed = false;
                reason = "over max sell";
            }
        }

        // Build fee tiers
        OpenFourTypes.FeeTier[] memory fees;
        if ((ctx.isBuy && _config.buyFeeBps > 0) || (!ctx.isBuy && _config.sellFeeBps > 0)) {
            fees = new OpenFourTypes.FeeTier[](1);
            fees[0] = OpenFourTypes.FeeTier({
                bps: ctx.isBuy ? _config.buyFeeBps : _config.sellFeeBps,
                recipient: _config.feeRecipient
            });
        }

        return OpenFourTypes.TradeResult(allowed, minAmt, maxAmt, fees, reason);
    }

    /// @notice Get stored init params
    function getInitParams() external view override returns (bytes memory) {
        return _initParams;
    }

    /// @notice Mark address as V3 liquidity provider (called by core)
    function addV3LiquidityProvider(address provider) external {
        require(msg.sender == _core, "FTM: not core");
        v3LiquidityProviders[provider] = true;
        emit V3LiquidityBlocked(provider);
    }

    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory p = new ParamDescriptor[](6);
        p[0] = ParamDescriptor("maxBuyAmount", "uint256", 0, false, "Max Buy (quote)", "0", "Max quote per buy", "0", "");
        p[1] = ParamDescriptor("maxPerAddress", "uint256", 0, false, "Max Per Address", "0", "Max tokens per address", "0", "");
        p[2] = ParamDescriptor("maxSellAmount", "uint256", 0, false, "Max Sell (tokens)", "0", "Max per sell", "0", "");
        p[3] = ParamDescriptor("buyFeeBps", "uint16", 0, false, "Extra Buy Fee", "0", "bps", "0", "10000");
        p[4] = ParamDescriptor("sellFeeBps", "uint16", 0, false, "Extra Sell Fee", "0", "bps", "0", "10000");
        p[5] = ParamDescriptor("feeRecipient", "address", 0, false, "Fee Recipient", "0x0000000000000000000000000000000000000000", "Address", "", "");
        return ModuleEncodeSchema("FlapTrade", 1, p);
    }

    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "module.trade.flap";
        version = _moduleVersion;
    }
}
