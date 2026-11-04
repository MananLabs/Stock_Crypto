// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BharatEquityToken} from "../contracts/BharatEquityToken.sol";
import {BharatEquityTokenFactory} from "../contracts/BharatEquityTokenFactory.sol";
import {BharatEquityMarketplace} from "../contracts/BharatEquityMarketplace.sol";

/// @notice Deploys BharatEquity to Monad Testnet ONLY (chain 10143). Run via script/deploy.sh.
/// Env:
///   ORACLE_SIGNER_ADDRESS  (required) public address of the backend quote signer
///   INITIAL_RESERVE_WEI    (optional) MON to seed the sell reserve, default 0
/// The deployer key comes from a Foundry keystore (--account), never from env/plaintext.
contract Deploy is Script {
    uint256 internal constant MONAD_TESTNET = 10143;
    string internal constant OUT = "./deployments/monad-testnet.json";

    struct Listing {
        string symbol;
        string company;
    }

    function listings() internal pure returns (Listing[10] memory) {
        return [
            Listing("RELIANCE", "Reliance Industries"),
            Listing("TCS", "Tata Consultancy Services"),
            Listing("INFY", "Infosys"),
            Listing("HDFCBANK", "HDFC Bank"),
            Listing("ICICIBANK", "ICICI Bank"),
            Listing("SBIN", "State Bank of India"),
            Listing("ITC", "ITC"),
            Listing("TATAMOTORS", "Tata Motors"),
            Listing("LT", "Larsen & Toubro"),
            Listing("BHARTIARTL", "Bharti Airtel")
        ];
    }

    function run() external {
        require(block.chainid == MONAD_TESTNET, "Refusing to deploy: chain is not Monad Testnet (10143)");
        address oracleSigner = vm.envAddress("ORACLE_SIGNER_ADDRESS");
        uint256 initialReserve = vm.envOr("INITIAL_RESERVE_WEI", uint256(0));
        require(oracleSigner != address(0), "ORACLE_SIGNER_ADDRESS is zero");

        (, address deployer,) = vm.readCallers();
        require(oracleSigner != deployer, "Use a dedicated oracle signer key, not the deployer");
        require(deployer.balance > initialReserve + 1 ether, "Deployer balance too low for deployment + reserve");

        console2.log("Network:        Monad Testnet (chain %s)", block.chainid);
        console2.log("Deployer/admin:", deployer);
        console2.log("Oracle signer: ", oracleSigner);
        console2.log("Deployer MON:  ", deployer.balance);
        console2.log("Initial reserve (wei):", initialReserve);
        console2.log("Deploying: BharatEquityTokenFactory, BharatEquityMarketplace, 10 BharatEquityToken");

        Listing[10] memory stocks = listings();
        address[10] memory tokens;

        vm.startBroadcast(deployer);
        BharatEquityTokenFactory factory = new BharatEquityTokenFactory(deployer);
        BharatEquityMarketplace market = new BharatEquityMarketplace(deployer, factory);
        factory.setMarketplace(address(market));
        market.grantRole(market.ORACLE_SIGNER_ROLE(), oracleSigner);
        for (uint256 i; i < stocks.length; ++i) {
            tokens[i] = factory.createStockToken(
                stocks[i].symbol,
                string.concat(stocks[i].company, " (BharatEquity Demo)"),
                string.concat("be", stocks[i].symbol),
                stocks[i].company,
                "NSE"
            );
        }
        if (initialReserve > 0) market.fundTreasury{value: initialReserve}();
        vm.stopBroadcast();

        // ---- post-deploy configuration checks (simulated state; script/CheckDeployment re-checks on-chain)
        require(factory.marketplace() == address(market), "marketplace not set");
        require(market.hasRole(market.ORACLE_SIGNER_ROLE(), oracleSigner), "signer missing");
        require(market.hasRole(market.DEFAULT_ADMIN_ROLE(), deployer), "admin missing");
        require(factory.tokenCount() == stocks.length, "token count");
        for (uint256 i; i < stocks.length; ++i) {
            BharatEquityToken t = BharatEquityToken(tokens[i]);
            require(t.hasRole(t.MINTER_ROLE(), address(market)), "market not minter");
            require(!t.hasRole(t.MINTER_ROLE(), deployer), "deployer must not mint");
            require(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(factory)), "factory not token admin");
            require(factory.getToken(stocks[i].symbol) == tokens[i], "registry mismatch");
        }

        _write(deployer, oracleSigner, factory, market, stocks, tokens);
    }

    function _write(
        address deployer,
        address oracleSigner,
        BharatEquityTokenFactory factory,
        BharatEquityMarketplace market,
        Listing[10] memory stocks,
        address[10] memory tokens
    ) internal {
        string memory tk = "tokens";
        string memory tokensJson;
        for (uint256 i; i < stocks.length; ++i) {
            tokensJson = vm.serializeAddress(tk, stocks[i].symbol, tokens[i]);
        }
        string memory root = "root";
        vm.serializeString(root, "network", "monad-testnet");
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "explorer", "https://testnet.monadexplorer.com");
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "oracleSigner", oracleSigner);
        vm.serializeAddress(root, "factory", address(factory));
        vm.serializeAddress(root, "marketplace", address(market));
        vm.serializeUint(root, "feeBps", market.feeBps());
        vm.serializeUint(root, "maxQuoteAge", market.maxQuoteAge());
        vm.serializeUint(root, "deployedAt", block.timestamp);
        string memory json = vm.serializeString(root, "tokens", tokensJson);
        vm.writeJson(json, OUT);
        console2.log("Addresses written to", OUT);
    }
}
