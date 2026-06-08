// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../../interfaces/IOpenFourTokenModule.sol";
import "../../interfaces/IOpenFourToken.sol";
import "../../interfaces/IOpenFourModuleSchema.sol";
import "../../interfaces/IFlapTaxToken.sol";
import "../../interfaces/ITagDescriptor.sol";
import "../../libraries/OpenFourTypes.sol";
import "../tokens/FlapTaxToken.sol";

/// @title FlapTaxTokenModule
/// @notice Token module that creates and initializes FlapTaxToken instances.
/// @dev Follows OpenFour module pattern: store init params, create token, initialize.
contract FlapTaxTokenModule is IOpenFourTokenModule, IOpenFourModuleSchema, ITagDescriptor {
    bytes32 private constant _TAG_ID = bytes32(keccak256(bytes("module.token.flap_tax")));
    bytes private _initParams;
    bytes4 private _moduleVersion;

    constructor() {
        _moduleVersion = bytes4(keccak256(bytes("v1.0.0")));
    }

    /// @notice Create a FlapTaxToken with the given creation params
    /// @param p TokenCreateParams from OpenFourTypes
    /// @param rawParams ABI-encoded FlapTaxConfig
    /// @return token Address of the created token
    function createToken(OpenFourTypes.TokenCreateParams calldata p, bytes calldata rawParams)
        external
        override
        returns (address token)
    {
        require(bytes(p.name).length > 0, "FTM: empty name");
        require(bytes(p.symbol).length > 0, "FTM: empty symbol");
        require(p.maxSupply > 0, "FTM: zero supply");
        require(p.quoteToken != address(0), "FTM: zero quote");

        // Store init params
        _initParams = rawParams;

        // Decode FlapTaxConfig
        FlapTaxConfig memory config = abi.decode(rawParams, (FlapTaxConfig));

        // Create token
        FlapTaxToken taxToken = new FlapTaxToken();
        token = address(taxToken);

        // Initialize OpenFourToken base
        OpenFourTypes.TokenInitParams memory tip;
        tip.name = p.name;
        tip.symbol = p.symbol;
        tip.owner = p.owner;
        tip.creator = p.creator;
        tip.quoteToken = p.quoteToken;
        tip.maxSupply = p.maxSupply;
        tip.token = token;
        tip.requestId = p.requestId;
        tip.vault = p.vault;
        tip.curve = p.curve;
        tip.trade = p.trade;
        tip.migrate = p.migrate;
        tip.tokenModule = address(this);
        tip.customData = p.customData;

        OpenFourToken(token).__OpenFourToken_init(tip);

        // Initialize FlapTaxToken specifics
        FlapTaxToken(token).initialize(config);

        emit TokenCreated(token, p.name, p.symbol);
    }

    /// @notice Module metadata for frontend schema
    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory params = new ParamDescriptor[](13);

        params[0] = ParamDescriptor("buyFeeRate", "Buy Tax Rate", ParamType.UINT16, 0, 1000, 100);
        params[1] = ParamDescriptor("sellFeeRate", "Sell Tax Rate", ParamType.UINT16, 0, 1000, 100);
        params[2] = ParamDescriptor("rateStocks", "Stocks Allocation %", ParamType.UINT16, 0, 1000, 0);
        params[3] = ParamDescriptor("rateFundsWallet", "Funds Wallet Allocation %", ParamType.UINT16, 0, 1000, 0);
        params[4] = ParamDescriptor("rateBurn", "Burn Allocation %", ParamType.UINT16, 0, 1000, 0);
        params[5] = ParamDescriptor("rateDividend", "Dividend Allocation %", ParamType.UINT16, 0, 1000, 0);
        params[6] = ParamDescriptor("rateLiquidity", "Liquidity Allocation %", ParamType.UINT16, 0, 1000, 0);
        params[7] = ParamDescriptor("rateUnallocated", "Unallocated %", ParamType.UINT16, 0, 1000, 0);
        params[8] = ParamDescriptor("antiFarmerDuration", "Anti-Farmer Period (seconds)", ParamType.UINT256, 0, 31536000, 259200);
        params[9] = ParamDescriptor("fundsWallet", "Funds Wallet Address", ParamType.ADDRESS, 0, 0, 0);
        params[10] = ParamDescriptor("stocksVault", "Stocks Vault Address", ParamType.ADDRESS, 0, 0, 0);
        params[11] = ParamDescriptor("", "", ParamType.UINT16, 0, 0, 0); // padding
        params[12] = ParamDescriptor("", "", ParamType.UINT16, 0, 0, 0);

        return ModuleEncodeSchema(params);
    }

    /// @notice Tag descriptor
    function descriptor() external pure override returns (bytes8 tagId, string memory tag, string memory version) {
        tagId = bytes8(_TAG_ID);
        tag = "module.token.flap_tax";
        version = "v1.0.0";
    }

    event TokenCreated(address indexed token, string name, string symbol);
}
