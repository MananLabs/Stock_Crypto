// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {BharatEquityToken} from "./BharatEquityToken.sol";

/// @title BharatEquityTokenFactory
/// @notice Deploys and registers one BharatEquityToken per stock symbol. The factory is DEFAULT_ADMIN of
///         every token it creates and is the only party that can grant/revoke the token MINTER_ROLE,
///         which it gives exclusively to the current marketplace.
/// @dev Privileged functions (DEFAULT_ADMIN_ROLE of the factory):
///        - createStockToken: register a new stock (symbol unique, immutable once registered)
///        - setMarketplace:   point all tokens' MINTER_ROLE at a (new) marketplace
contract BharatEquityTokenFactory is AccessControl {
    address public marketplace;

    mapping(bytes32 symbolHash => address token) private _tokenBySymbol;
    mapping(address token => string symbol) private _symbolByToken;
    address[] private _tokens;

    event StockTokenCreated(
        string indexed symbolIndexed, string symbol, address indexed token, string name, string companyName
    );
    event MarketplaceUpdated(address indexed previous, address indexed current);

    error ZeroAddress();
    error EmptySymbol();
    error NotAContract(address account);
    error SymbolAlreadyRegistered(string symbol);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Privileged. Deploys a token for `symbol`; grants MINTER_ROLE to the marketplace if one is set.
    /// @param symbol      Registry key, e.g. "RELIANCE" (case-sensitive, must be unique).
    /// @param tokenName   ERC-20 name, e.g. "Reliance Industries (BharatEquity Demo)".
    /// @param tokenSymbol ERC-20 symbol, e.g. "beRELIANCE".
    function createStockToken(
        string memory symbol,
        string memory tokenName,
        string memory tokenSymbol,
        string memory companyName,
        string memory exchange
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address token) {
        if (bytes(symbol).length == 0) revert EmptySymbol();
        bytes32 key = keccak256(bytes(symbol));
        if (_tokenBySymbol[key] != address(0)) revert SymbolAlreadyRegistered(symbol);

        BharatEquityToken t =
            new BharatEquityToken(tokenName, tokenSymbol, symbol, companyName, exchange, address(this));
        token = address(t);
        _tokenBySymbol[key] = token;
        _symbolByToken[token] = symbol;
        _tokens.push(token);
        if (marketplace != address(0)) t.grantRole(t.MINTER_ROLE(), marketplace);

        emit StockTokenCreated(symbol, symbol, token, tokenName, companyName);
    }

    /// @notice Privileged. Moves MINTER_ROLE on every registered token from the old marketplace to `newMarketplace`.
    /// @dev Loops over all tokens; fine for the expected tens of listings. This is the most powerful admin action:
    ///      whoever controls the factory admin decides which contract may mint. Use a multisig in production.
    function setMarketplace(address newMarketplace) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMarketplace == address(0)) revert ZeroAddress();
        if (newMarketplace.code.length == 0) revert NotAContract(newMarketplace); // EOAs must never get mint rights
        address old = marketplace;
        marketplace = newMarketplace;
        for (uint256 i; i < _tokens.length; ++i) {
            BharatEquityToken t = BharatEquityToken(_tokens[i]);
            bytes32 role = t.MINTER_ROLE();
            if (old != address(0)) t.revokeRole(role, old);
            t.grantRole(role, newMarketplace);
        }
        emit MarketplaceUpdated(old, newMarketplace);
    }

    // ----------------------------------------------------------------- views

    function getToken(string calldata symbol) external view returns (address) {
        return _tokenBySymbol[keccak256(bytes(symbol))];
    }

    function symbolOf(address token) external view returns (string memory) {
        return _symbolByToken[token];
    }

    function isRegistered(address token) public view returns (bool) {
        return bytes(_symbolByToken[token]).length != 0;
    }

    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    function allTokens() external view returns (address[] memory) {
        return _tokens;
    }
}
