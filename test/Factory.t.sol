// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BharatEquityToken} from "../contracts/BharatEquityToken.sol";
import {BharatEquityTokenFactory} from "../contracts/BharatEquityTokenFactory.sol";
import {BharatEquityMarketplace} from "../contracts/BharatEquityMarketplace.sol";
import {Base} from "./Base.t.sol";

contract FactoryTest is Base {
    function test_RegisterStock() public {
        vm.prank(admin);
        address token = factory.createStockToken("INFY", "Infosys (BharatEquity Demo)", "beINFY", "Infosys", "NSE");

        assertEq(factory.getToken("INFY"), token);
        assertEq(factory.symbolOf(token), "INFY");
        assertTrue(factory.isRegistered(token));
        assertEq(factory.tokenCount(), 3);
        assertEq(factory.allTokens()[2], token);
        BharatEquityToken t = BharatEquityToken(token);
        assertEq(t.symbol(), "beINFY");
        assertTrue(t.hasRole(t.MINTER_ROLE(), address(market)));
        assertTrue(market.isTokenTradable(token));
    }

    function test_EmitsStockTokenCreated() public {
        vm.recordLogs();
        vm.prank(admin);
        address token = factory.createStockToken("SBIN", "SBI (BharatEquity Demo)", "beSBIN", "SBI", "NSE");
        bytes32 sig = keccak256("StockTokenCreated(string,string,address,string,string)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig && logs[i].emitter == address(factory)) found = true;
        }
        assertTrue(found);
        assertEq(factory.getToken("SBIN"), token);
    }

    function test_RevertWhen_DuplicateSymbol() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BharatEquityTokenFactory.SymbolAlreadyRegistered.selector, "RELIANCE"));
        factory.createStockToken("RELIANCE", "x", "x", "x", "NSE");
    }

    function test_RevertWhen_EmptySymbol() public {
        vm.prank(admin);
        vm.expectRevert(BharatEquityTokenFactory.EmptySymbol.selector);
        factory.createStockToken("", "x", "x", "x", "NSE");
    }

    function test_RevertWhen_UnauthorizedRegistration() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        factory.createStockToken("ITC", "x", "x", "x", "NSE");
    }

    function test_LookupUnknown() public view {
        assertEq(factory.getToken("NOPE"), address(0));
        assertFalse(factory.isRegistered(alice));
        assertEq(factory.symbolOf(alice), "");
    }

    function test_SetMarketplaceMigratesMinterRole() public {
        BharatEquityMarketplace next = new BharatEquityMarketplace(admin, factory);
        vm.prank(admin);
        factory.setMarketplace(address(next));
        bytes32 minter = reliance.MINTER_ROLE();
        assertFalse(reliance.hasRole(minter, address(market)));
        assertTrue(reliance.hasRole(minter, address(next)));
        assertTrue(tcs.hasRole(minter, address(next)));
        assertEq(factory.marketplace(), address(next));
    }

    function test_TokenCreatedBeforeMarketplaceGetsRoleLater() public {
        vm.startPrank(admin);
        BharatEquityTokenFactory f = new BharatEquityTokenFactory(admin);
        BharatEquityToken t = BharatEquityToken(f.createStockToken("LT", "L&T", "beLT", "Larsen & Toubro", "NSE"));
        assertFalse(t.hasRole(t.MINTER_ROLE(), address(market)));
        f.setMarketplace(address(market));
        vm.stopPrank();
        assertTrue(t.hasRole(t.MINTER_ROLE(), address(market)));
    }

    function test_RevertWhen_SetMarketplaceZeroOrUnauthorized() public {
        vm.prank(admin);
        vm.expectRevert(BharatEquityTokenFactory.ZeroAddress.selector);
        factory.setMarketplace(address(0));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        factory.setMarketplace(alice);
    }

    function test_RevertWhen_MarketplaceIsEOA() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BharatEquityTokenFactory.NotAContract.selector, bob));
        factory.setMarketplace(bob);
        assertFalse(reliance.hasRole(reliance.MINTER_ROLE(), bob));
    }

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert(BharatEquityTokenFactory.ZeroAddress.selector);
        new BharatEquityTokenFactory(address(0));
    }
}
