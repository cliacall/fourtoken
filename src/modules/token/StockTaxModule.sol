// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../../interfaces/IOpenFourTokenModule.sol";
import "../../interfaces/IOpenFourToken.sol";
import "../../interfaces/IOpenFourModuleSchema.sol";
import "../../interfaces/IStockTaxToken.sol";
import "../../interfaces/ITagDescriptor.sol";
import "../../libraries/OpenFourTypes.sol";
import "../../tokens/StockTaxToken.sol";
import "../../tokens/OpenFourToken.sol";

/// @title StockTaxModule
/// @notice Token module that creates and initializes StockTaxToken instances.
/// @dev Follows OpenFour module pattern: store init params, create token, initialize.
contract StockTaxModule is IOpenFourTokenModule, IOpenFourModuleSchema {
    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("module.token.stock_tax")));
    bytes private _initParams;
    bytes4 private _moduleVersion;

    constructor() {
        _moduleVersion = bytes4(keccak256(bytes("v1.0.0")));
    }

    /// @notice Create a StockTaxToken with the given creation params
    /// @dev Follows the IOpenFourTokenModule interface signature
    function createToken(
        address creator,
        address token,
        address vault,
        address curveModule,
        address tradeModule,
        address migrateModule,
        address customDataModule,
        OpenFourTypes.TokenCreateParams calldata tokenParams,
        string calldata tokenImplVersion,
        string calldata tokenModuleVersion
    ) external override returns (uint256 maxSupply, string memory name, string memory symbol) {
        require(bytes(tokenParams.name).length > 0, "STM: empty name");
        require(bytes(tokenParams.symbol).length > 0, "STM: empty symbol");
        require(tokenParams.maxSupply > 0, "STM: zero supply");
        require(tokenParams.quoteAsset != address(0), "STM: zero quote");

        // Store init params
        _initParams = tokenParams.tokenParams;

        // Create token
        StockTaxToken taxToken = new StockTaxToken();
        token = address(taxToken);

        // Build InitArgs for OpenFourToken
        OpenFourToken.InitArgs memory args = OpenFourToken.InitArgs({
            requestId: tokenParams.requestId,
            name: tokenParams.name,
            symbol: tokenParams.symbol,
            vault: vault,
            maxSupply: tokenParams.maxSupply,
            tokenUri: tokenParams.tokenUri,
            curveModule: curveModule,
            tradeModule: tradeModule,
            migrateModule: migrateModule,
            tokenModule: address(this),
            customDataModule: customDataModule,
            creator: creator,
            quoteAsset: tokenParams.quoteAsset,
            tokenParams: tokenParams.tokenParams,
            tokenImplVersion: tokenImplVersion
        });

        // Decode StockTaxConfig
        StockTaxConfig memory config = abi.decode(tokenParams.tokenParams, (StockTaxConfig));

        // Initialize StockTaxToken (combines OpenFourToken + StockTaxToken init)
        StockTaxToken(payable(token)).initialize(args, config);

        emit TokenCreated(token, tokenParams.name, tokenParams.symbol);
        return (tokenParams.maxSupply, tokenParams.name, tokenParams.symbol);
    }

    /// @notice Returns the raw ABI-encoded init params
    function getInitParams() external view override returns (bytes memory) {
        return _initParams;
    }

    /// @notice Module metadata for frontend schema
    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory params = new ParamDescriptor[](11);

        params[0] = ParamDescriptor("buyFeeRate", "uint16", 0, false, "Buy Tax Rate", "100", "0-1000 bps (0-10%)", "0", "1000");
        params[1] = ParamDescriptor("sellFeeRate", "uint16", 0, false, "Sell Tax Rate", "100", "0-1000 bps (0-10%)", "0", "1000");
        params[2] = ParamDescriptor("rateStocks", "uint16", 0, false, "Stocks Allocation", "0", "Permille (0-1000)", "0", "1000");
        params[3] = ParamDescriptor("rateFundsWallet", "uint16", 0, false, "Funds Wallet Allocation", "0", "Permille", "0", "1000");
        params[4] = ParamDescriptor("rateBurn", "uint16", 0, false, "Burn Allocation", "0", "Permille", "0", "1000");
        params[5] = ParamDescriptor("rateDividend", "uint16", 0, false, "Dividend Allocation", "0", "Permille", "0", "1000");
        params[6] = ParamDescriptor("rateLiquidity", "uint16", 0, false, "Liquidity Allocation", "0", "Permille", "0", "1000");
        params[7] = ParamDescriptor("rateUnallocated", "uint16", 0, false, "Unallocated", "0", "Permille", "0", "1000");
        params[8] = ParamDescriptor("antiFarmerDuration", "uint256", 0, false, "Anti-Farmer Period", "259200", "Seconds", "0", "31536000");
        params[9] = ParamDescriptor("fundsWallet", "address", 0, false, "Funds Wallet", "0x0000000000000000000000000000000000000000", "Address", "", "");
        params[10] = ParamDescriptor("stocksVault", "address", 0, false, "Stocks Vault", "0x0000000000000000000000000000000000000000", "Address", "", "");

        return ModuleEncodeSchema("StockTaxToken", 1, params);
    }

    /// @notice Tag descriptor
    function descriptor() external pure override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "module.token.stock_tax";
        version = "v1.0.0";
    }

    event TokenCreated(address indexed token, string name, string symbol);
}
