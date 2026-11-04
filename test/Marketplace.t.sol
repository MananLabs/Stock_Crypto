// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BharatEquityMarketplace as M} from "../contracts/BharatEquityMarketplace.sol";
import {BharatEquityTokenFactory} from "../contracts/BharatEquityTokenFactory.sol";
import {Base} from "./Base.t.sol";

/// Note: signatures and role getters are computed BEFORE vm.prank, since any external call consumes the prank.
contract MarketplaceTest is Base {
    // ------------------------------------------------------------- buy

    function test_Buy() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 2 ether, PRICE);
        bytes memory sig = _sign(q);
        uint256 before = alice.balance;

        vm.expectEmit(address(market));
        emit M.StockPurchased(alice, address(reliance), q.nonce, 2 ether, PRICE, 20 ether, 0.1 ether, q.marketTimestamp);
        vm.prank(alice);
        uint256 total = market.buyStock{value: 25 ether}(q, sig, 21 ether); // overpay, expect refund

        assertEq(total, 20.1 ether);
        assertEq(before - alice.balance, 20.1 ether, "excess refunded");
        assertEq(reliance.balanceOf(alice), 2 ether);
        assertEq(market.reserveBalance(), 20 ether);
        assertEq(market.accruedFees(), 0.1 ether);
        assertEq(address(market).balance, 20.1 ether);
        assertTrue(market.usedNonces(q.nonce));
    }

    function test_RevertWhen_Underpaying() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 2 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.InsufficientPayment.selector, 20 ether, 20.1 ether));
        market.buyStock{value: 20 ether}(q, sig, 21 ether);
    }

    function test_RevertWhen_BuySlippageExceeded() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 2 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.SlippageExceeded.selector, 20.1 ether, 20 ether));
        market.buyStock{value: 21 ether}(q, sig, 20 ether);
    }

    // ------------------------------------------------------------- sell

    function test_Sell() public {
        _buy(alice, 2 ether, PRICE);
        M.Quote memory q = _quote(alice, address(reliance), SELL, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        uint256 before = alice.balance;

        vm.startPrank(alice);
        reliance.approve(address(market), 1 ether);
        vm.expectEmit(address(market));
        emit M.StockSold(alice, address(reliance), q.nonce, 1 ether, PRICE, 10 ether, 0.05 ether, q.marketTimestamp);
        uint256 payout = market.sellStock(q, sig, 9.95 ether);
        vm.stopPrank();

        assertEq(payout, 9.95 ether);
        assertEq(alice.balance - before, 9.95 ether);
        assertEq(reliance.balanceOf(alice), 1 ether);
        assertEq(reliance.totalSupply(), 1 ether, "burned");
        assertEq(reliance.balanceOf(address(market)), 0);
        assertEq(market.reserveBalance(), 10 ether);
        assertEq(market.accruedFees(), 0.15 ether);
        _assertSolvent();
        assertEq(address(market).balance, market.reserveBalance() + market.accruedFees());
    }

    function test_RevertWhen_SellSlippage() public {
        _buy(alice, 1 ether, PRICE);
        M.Quote memory q = _quote(alice, address(reliance), SELL, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        reliance.approve(address(market), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(M.SlippageExceeded.selector, 9.95 ether, 10 ether));
        market.sellStock(q, sig, 10 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_SellingMoreThanBalance() public {
        _fund(100 ether);
        _buy(alice, 1 ether, PRICE);
        M.Quote memory q = _quote(alice, address(reliance), SELL, 2 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        reliance.approve(address(market), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        market.sellStock(q, sig, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_SellWithoutApproval() public {
        _buy(alice, 1 ether, PRICE);
        M.Quote memory q = _quote(alice, address(reliance), SELL, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(market), 0, 1 ether)
        );
        market.sellStock(q, sig, 0);
    }

    function test_RevertWhen_InsufficientLiquidity() public {
        _buy(alice, 1 ether, PRICE); // reserve = 10 MON
        // Price doubles: payout would need 20 MON gross but only 10 is reserved.
        M.Quote memory q = _quote(alice, address(reliance), SELL, 1 ether, 2 * PRICE);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        reliance.approve(address(market), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(M.InsufficientLiquidity.selector, 20 ether, 10 ether));
        market.sellStock(q, sig, 0);
        vm.stopPrank();

        _fund(10 ether); // treasury top-up unlocks the sale
        _sell(alice, 1 ether, 2 * PRICE);
        assertEq(market.reserveBalance(), 0);
        _assertSolvent();
    }

    function test_FeesAreNeverUsedForPayouts() public {
        _buy(alice, 1 ether, PRICE); // reserve 10, fees 0.05
        vm.prank(admin);
        market.withdrawReserve(payable(admin), 10 ether);
        assertEq(address(market).balance, 0.05 ether);

        M.Quote memory q = _quote(alice, address(reliance), SELL, 0.001 ether, PRICE); // gross 0.01 < fees held
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        reliance.approve(address(market), 0.001 ether);
        vm.expectRevert(abi.encodeWithSelector(M.InsufficientLiquidity.selector, 0.01 ether, 0));
        market.sellStock(q, sig, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- fees

    function test_FeeCalculation() public view {
        (uint256 g, uint256 f, uint256 t) = market.quoteBuy(3 ether, 1234.5678 ether);
        assertEq(g, 3703.7034 ether);
        assertEq(f, 18.518517 ether);
        assertEq(t, g + f);
        (g, f, t) = market.quoteSell(3 ether, 1234.5678 ether);
        assertEq(g, 3703.7034 ether);
        assertEq(f, 18.518517 ether);
        assertEq(t, g - f);
    }

    function test_SetFee() public {
        vm.startPrank(admin);
        market.setFeeBps(100);
        assertEq(market.feeBps(), 100);
        vm.expectRevert(abi.encodeWithSelector(M.FeeTooHigh.selector, 301, 300));
        market.setFeeBps(301);
        market.setMaxFeeBps(1_000);
        market.setFeeBps(1_000);
        vm.expectRevert(abi.encodeWithSelector(M.FeeTooHigh.selector, 1_001, 1_000));
        market.setMaxFeeBps(1_001);
        vm.expectRevert(abi.encodeWithSelector(M.FeeTooHigh.selector, 1_000, 999));
        market.setMaxFeeBps(999); // below current fee
        market.setFeeBps(0);
        vm.stopPrank();

        uint256 total = _buy(alice, 1 ether, PRICE);
        assertEq(total, 10 ether);
        assertEq(market.accruedFees(), 0);
    }

    function test_RevertWhen_UnauthorizedConfig() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        market.setFeeBps(0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        market.setMaxQuoteAge(60);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        market.setTokenEnabled(address(reliance), false);
        vm.stopPrank();
    }

    function test_MaxQuoteAgeBounds() public {
        vm.startPrank(admin);
        market.setMaxQuoteAge(300);
        assertEq(market.maxQuoteAge(), 300);
        vm.expectRevert(abi.encodeWithSelector(M.InvalidQuoteAge.selector, 9));
        market.setMaxQuoteAge(9);
        vm.expectRevert(abi.encodeWithSelector(M.InvalidQuoteAge.selector, 3601));
        market.setMaxQuoteAge(3601);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- treasury

    function test_FundTreasury() public {
        vm.expectEmit(address(market));
        emit M.TreasuryFunded(admin, 50 ether, 50 ether);
        _fund(50 ether);
        assertEq(market.reserveBalance(), 50 ether);
        assertEq(market.availableLiquidity(), 50 ether);

        vm.prank(admin);
        vm.expectRevert(M.ZeroAmount.selector);
        market.fundTreasury{value: 0}();
    }

    function test_RevertWhen_PlainTransfer() public {
        vm.prank(alice);
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok, "no receive(): MON must go through fundTreasury or a buy");
    }

    function test_WithdrawFees() public {
        _buy(alice, 2 ether, PRICE); // fees 0.1
        uint256 before = bob.balance;
        vm.prank(admin);
        market.withdrawFees(payable(bob), 0.04 ether);
        assertEq(bob.balance - before, 0.04 ether);
        assertEq(market.accruedFees(), 0.06 ether);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(M.ExceedsBalance.selector, 1 ether, 0.06 ether));
        market.withdrawFees(payable(bob), 1 ether);
        assertEq(market.reserveBalance(), 20 ether, "reserve untouched");
        _assertSolvent();
    }

    function test_WithdrawReserve() public {
        _fund(30 ether);
        vm.prank(admin);
        market.withdrawReserve(payable(bob), 10 ether);
        assertEq(market.reserveBalance(), 20 ether);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(M.ExceedsBalance.selector, 21 ether, 20 ether));
        market.withdrawReserve(payable(bob), 21 ether);
    }

    function test_SurplusIsTrackedSeparately() public {
        _fund(5 ether);
        vm.deal(address(market), address(market).balance + 1 ether); // forced send
        assertEq(market.surplus(), 1 ether);
        assertEq(market.reserveBalance(), 5 ether);
    }

    // ------------------------------------------------------------- pause / enable

    function test_PauseAndUnpause() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(admin);
        market.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);

        M.Quote memory s = _quote(alice, address(reliance), SELL, 1 ether, PRICE);
        bytes memory ssig = _sign(s);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.sellStock(s, ssig, 0);

        _fund(1 ether); // treasury still usable while paused
        vm.prank(admin);
        market.unpause();
        vm.prank(alice);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
        assertEq(reliance.balanceOf(alice), 1 ether);
    }

    function test_RevertWhen_UnauthorizedPause() public {
        bytes32 role = market.PAUSER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        market.pause();
    }

    function test_DisabledToken() public {
        vm.prank(admin);
        market.setTokenEnabled(address(reliance), false);
        assertFalse(market.isTokenTradable(address(reliance)));

        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.TokenIsDisabled.selector, address(reliance)));
        market.buyStock{value: 11 ether}(q, sig, 11 ether);

        vm.prank(admin);
        market.setTokenEnabled(address(reliance), true);
        vm.prank(alice);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
        assertTrue(market.isTokenTradable(address(tcs)), "other tokens unaffected");
    }

    function test_RevertWhen_UnregisteredToken() public {
        M.Quote memory q = _quote(alice, bob, BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.TokenNotRegistered.selector, bob));
        market.buyStock{value: 11 ether}(q, sig, 11 ether);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(M.TokenNotRegistered.selector, bob));
        market.setTokenEnabled(bob, true);
    }

    function test_MultiTokenTrading() public {
        M.Quote memory q = _quote(bob, address(tcs), BUY, 3 ether, 48 ether);
        bytes memory sig = _sign(q);
        vm.prank(bob);
        market.buyStock{value: 200 ether}(q, sig, 200 ether);
        assertEq(tcs.balanceOf(bob), 3 ether);
        assertEq(reliance.balanceOf(bob), 0);
    }

    function test_ConstructorRejectsZero() public {
        vm.expectRevert(M.ZeroAddress.selector);
        new M(address(0), factory);
        vm.expectRevert(M.ZeroAddress.selector);
        new M(admin, BharatEquityTokenFactory(address(0)));
    }

    function _fund(uint256 amount) internal {
        vm.prank(admin);
        market.fundTreasury{value: amount}();
    }
}
