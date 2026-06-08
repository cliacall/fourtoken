// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/IOpenFourTradeModule.sol";
import "../interfaces/IOpenFourModuleSchema.sol";
import "../interfaces/ITagDescriptor.sol";
import "../tokens/FlapTaxToken.sol";

/// @title FlapTradeModule
/// @notice Trade module for FlapTaxToken preset.
///         Enforces max buy/sell limits per address and anti-farmer protection.
/// @dev Extends FairLaunch-style trade logic with anti-farmer V3 pool blocking.
contract FlapTradeModule is IOpenFourTradeModule, IOpenFourModuleSchema, ITagDescriptor, Initializable {
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
    bytes4 private _moduleVersion;

    // Anti-farmer: track addresses that added V3 liquidity (blocked during protection period)
    mapping(address => bool) public v3LiquidityProviders;

    event V3LiquidityBlocked(address indexed provider);

    constructor() {
        _moduleVersion = bytes4(keccak256(bytes("v1.0.0")));
    }

    function init(bytes calldata data) external initializer {
        _core = msg.sender;
        TradeConfig memory cfg = abi.decode(data, (TradeConfig));
        require(cfg.buyFeeBps <= 10_000, "FTM: buy fee bps");
        require(cfg.sellFeeBps <= 10_000, "FTM: sell fee bps");
        _config = cfg;
        _initParams = data;
    }

    /// @notice Set the token address (called by core after token creation)
    function setToken(address token_) external {
        require(_token == address(0), "FTM: token set");
        require(msg.sender == _core, "FTM: not core");
        _token = token_;
    }

    /// @notice Evaluate whether a trade is allowed.
    ///         Rejects sells during anti-farmer period if seller added V3 liquidity.
    function evaluate(
        address caller,
        address from,
        address to,
        uint256 quoteAmount,
        uint256 tokenAmount,
        bool isBuy,
        bytes calldata /*data*/
    ) external view override returns (TradeResult memory) {
        require(_token != address(0), "FTM: no token");

        bool allowed = true;
        uint256 minAmt = 0;
        uint256 maxAmt = type(uint256).max;
        string memory reason;

        if (isBuy) {
            // Max buy amount check
            if (_config.maxBuyAmount > 0 && quoteAmount > _config.maxBuyAmount) {
                allowed = false;
                reason = "over max buy";
            }
            // Max per address check
            if (allowed && _config.maxPerAddress > 0) {
                uint256 balance = IERC20(_token).balanceOf(to);
                if (balance + tokenAmount > _config.maxPerAddress) {
                    allowed = false;
                    reason = "over max per address";
                }
            }
        } else {
            // Anti-farmer: block sells from V3 liquidity providers during protection
            if (v3LiquidityProviders[from]) {
                FlapTaxToken taxToken = FlapTaxToken(_token);
                if (taxToken.isAntiFarmerActive()) {
                    allowed = false;
                    reason = "anti-farmer: V3 LP provider";
                }
            }
            // Max sell amount check
            if (allowed && _config.maxSellAmount > 0 && tokenAmount > _config.maxSellAmount) {
                allowed = false;
                reason = "over max sell";
            }
        }

        // Build fee tiers
        FeeTier[] memory fees;
        if ((isBuy && _config.buyFeeBps > 0) || (!isBuy && _config.sellFeeBps > 0)) {
            fees = new FeeTier[](1);
            fees[0] = FeeTier({
                feeBps: isBuy ? _config.buyFeeBps : _config.sellFeeBps,
                recipient: _config.feeRecipient
            });
        }

        return TradeResult(allowed, minAmt, maxAmt, fees, reason);
    }

    /// @notice Mark address as V3 liquidity provider (called externally by core or helper)
    function addV3LiquidityProvider(address provider) external {
        require(msg.sender == _core, "FTM: not core");
        v3LiquidityProviders[provider] = true;
        emit V3LiquidityBlocked(provider);
    }

    // ─── Schema ───
    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory params = new ParamDescriptor[](6);
        params[0] = ParamDescriptor("maxBuyAmount", "Max Buy (quote)", ParamType.UINT256, 0, 0, 0);
        params[1] = ParamDescriptor("maxPerAddress", "Max Tokens per Address", ParamType.UINT256, 0, 0, 0);
        params[2] = ParamDescriptor("maxSellAmount", "Max Sell (tokens)", ParamType.UINT256, 0, 0, 0);
        params[3] = ParamDescriptor("buyFeeBps", "Extra Buy Fee (bps)", ParamType.UINT16, 0, 10000, 0);
        params[4] = ParamDescriptor("sellFeeBps", "Extra Sell Fee (bps)", ParamType.UINT16, 0, 10000, 0);
        params[5] = ParamDescriptor("feeRecipient", "Fee Recipient", ParamType.ADDRESS, 0, 0, 0);
        return ModuleEncodeSchema(params);
    }

    function descriptor() external pure override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "module.trade.flap";
        version = "v1.0.0";
    }
}
