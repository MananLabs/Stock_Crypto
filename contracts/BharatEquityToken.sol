// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title BharatEquityToken
/// @notice ERC-20 demo token giving SIMULATED price exposure to one Indian listed company.
/// @dev NOT a share. Confers no ownership, voting, dividend or any other shareholder right in the
///      referenced company and is not settled against NSE/BSE. One contract per stock.
///      Supply only changes through MINTER_ROLE (the marketplace):
///        - mint(to, amount): issue tokens to a buyer
///        - burn(amount):     destroy tokens the caller itself holds (never someone else's)
contract BharatEquityToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    string public constant DISCLAIMER =
        "Simulated stock-exposure demo token. Not a share or security; confers no shareholder rights.";

    /// @notice Registry symbol of the referenced stock, e.g. "RELIANCE".
    string public stockSymbol;
    /// @notice Display name of the referenced company, e.g. "Reliance Industries".
    string public companyName;
    /// @notice Primary listing venue of the referenced company, e.g. "NSE".
    string public exchange;

    error ZeroAddress();

    /// @param admin Receives DEFAULT_ADMIN_ROLE (the factory), which manages MINTER_ROLE.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory stockSymbol_,
        string memory companyName_,
        string memory exchange_,
        address admin
    ) ERC20(name_, symbol_) {
        if (admin == address(0)) revert ZeroAddress();
        stockSymbol = stockSymbol_;
        companyName = companyName_;
        exchange = exchange_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Privileged: MINTER_ROLE only. Called by the marketplace after a paid, quote-verified buy.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Privileged: MINTER_ROLE only. Burns tokens held by the caller (marketplace pulls them first).
    function burn(uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(msg.sender, amount);
    }
}
