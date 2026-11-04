// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BharatEquityToken} from "../contracts/BharatEquityToken.sol";
import {BharatEquityTokenFactory} from "../contracts/BharatEquityTokenFactory.sol";
import {BharatEquityMarketplace} from "../contracts/BharatEquityMarketplace.sol";

/// @notice Read-only, against the live RPC: confirms every address in deployments/monad-testnet.json has code
///         and the permission model is exactly as intended. Never broadcasts.
contract CheckDeployment is Script {
    string[10] internal SYMBOLS =
        ["RELIANCE", "TCS", "INFY", "HDFCBANK", "ICICIBANK", "SBIN", "ITC", "TATAMOTORS", "LT", "BHARTIARTL"];

    function run() external view {
        require(block.chainid == 10143, "Not Monad Testnet");
        string memory json = vm.readFile("./deployments/monad-testnet.json");
        BharatEquityTokenFactory factory = BharatEquityTokenFactory(vm.parseJsonAddress(json, ".factory"));
        BharatEquityMarketplace market = BharatEquityMarketplace(vm.parseJsonAddress(json, ".marketplace"));
        address deployer = vm.parseJsonAddress(json, ".deployer");
        address signer = vm.parseJsonAddress(json, ".oracleSigner");

        require(address(factory).code.length > 0, "factory has no code");
        require(address(market).code.length > 0, "marketplace has no code");
        require(address(market.factory()) == address(factory), "market.factory mismatch");
        require(factory.marketplace() == address(market), "factory.marketplace mismatch");
        require(market.hasRole(market.ORACLE_SIGNER_ROLE(), signer), "oracle signer not authorised");
        require(market.hasRole(market.DEFAULT_ADMIN_ROLE(), deployer), "admin missing");
        require(!market.paused(), "marketplace paused");

        for (uint256 i; i < SYMBOLS.length; ++i) {
            address a = vm.parseJsonAddress(json, string.concat(".tokens.", SYMBOLS[i]));
            BharatEquityToken t = BharatEquityToken(a);
            require(a.code.length > 0, string.concat(SYMBOLS[i], ": no code"));
            require(factory.getToken(SYMBOLS[i]) == a, string.concat(SYMBOLS[i], ": registry mismatch"));
            require(t.hasRole(t.MINTER_ROLE(), address(market)), string.concat(SYMBOLS[i], ": market not minter"));
            require(!t.hasRole(t.MINTER_ROLE(), deployer), string.concat(SYMBOLS[i], ": deployer can mint"));
            require(market.isTokenTradable(a), string.concat(SYMBOLS[i], ": not tradable"));
            console2.log(SYMBOLS[i], a);
        }
        console2.log("factory    ", address(factory));
        console2.log("marketplace", address(market));
        console2.log("reserve (wei)", market.reserveBalance());
        console2.log("fees (wei)   ", market.accruedFees());
        console2.log("Deployment check: OK");
    }
}
