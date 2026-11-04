// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BharatEquityToken} from "../contracts/BharatEquityToken.sol";
import {Base} from "./Base.t.sol";

contract TokenTest is Base {
    function test_Deployment() public view {
        assertEq(reliance.name(), "Reliance Industries (BharatEquity Demo)");
        assertEq(reliance.symbol(), "beRELIANCE");
        assertEq(reliance.decimals(), 18);
        assertEq(reliance.totalSupply(), 0);
        assertEq(reliance.stockSymbol(), "RELIANCE");
        assertEq(reliance.companyName(), "Reliance Industries");
        assertEq(reliance.exchange(), "NSE");
        assertTrue(reliance.hasRole(reliance.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertTrue(reliance.hasRole(reliance.MINTER_ROLE(), address(market)));
        assertFalse(reliance.hasRole(reliance.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert(BharatEquityToken.ZeroAddress.selector);
        new BharatEquityToken("n", "s", "S", "C", "NSE", address(0));
    }

    function test_MintByMarketplace() public {
        vm.prank(address(market));
        reliance.mint(alice, 5 ether);
        assertEq(reliance.balanceOf(alice), 5 ether);
        assertEq(reliance.totalSupply(), 5 ether);
    }

    function test_RevertWhen_UnauthorizedMint() public {
        bytes32 role = reliance.MINTER_ROLE();
        address[3] memory callers = [alice, admin, signer];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], role)
            );
            reliance.mint(callers[i], 1 ether);
        }
    }

    function test_BurnOwnBalance() public {
        vm.startPrank(address(market));
        reliance.mint(address(market), 3 ether);
        reliance.burn(2 ether);
        vm.stopPrank();
        assertEq(reliance.balanceOf(address(market)), 1 ether);
        assertEq(reliance.totalSupply(), 1 ether);
    }

    function test_RevertWhen_UnauthorizedBurn() public {
        vm.prank(address(market));
        reliance.mint(alice, 1 ether);
        bytes32 role = reliance.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        reliance.burn(1 ether);
    }

    function test_MarketplaceCannotBurnOthersTokens() public {
        vm.startPrank(address(market));
        reliance.mint(alice, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(market), 0, 1 ether)
        );
        reliance.burn(1 ether);
        vm.stopPrank();
        assertEq(reliance.balanceOf(alice), 1 ether);
    }

    function test_HumanAdminCannotGrantMinter() public {
        bytes32 minter = reliance.MINTER_ROLE();
        bytes32 adminRole = reliance.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole)
        );
        reliance.grantRole(minter, admin);
    }

    function test_Transfers() public {
        vm.prank(address(market));
        reliance.mint(alice, 4 ether);

        vm.prank(alice);
        assertTrue(reliance.transfer(bob, 1 ether));
        assertEq(reliance.balanceOf(bob), 1 ether);

        vm.prank(alice);
        reliance.approve(bob, 2 ether);
        vm.prank(bob);
        assertTrue(reliance.transferFrom(alice, bob, 2 ether));
        assertEq(reliance.balanceOf(alice), 1 ether);
        assertEq(reliance.balanceOf(bob), 3 ether);
        assertEq(reliance.allowance(alice, bob), 0);
    }
}
