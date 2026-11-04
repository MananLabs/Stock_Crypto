// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BharatEquityMarketplace as M} from "../contracts/BharatEquityMarketplace.sol";
import {BharatEquityToken} from "../contracts/BharatEquityToken.sol";
import {BharatEquityTokenFactory} from "../contracts/BharatEquityTokenFactory.sol";
import {Base} from "./Base.t.sol";

/// Malicious trader: re-enters the marketplace from its receive() hook (triggered by refunds/payouts).
contract Reenterer {
    M internal immutable market;
    BharatEquityToken internal immutable token;
    M.Quote internal next;
    bytes internal nextSig;
    bool internal armed;
    bool public reentryBlocked;

    constructor(M m, BharatEquityToken t) {
        market = m;
        token = t;
    }

    function arm(M.Quote memory q, bytes memory sig) external {
        next = q;
        nextSig = sig;
        armed = true;
    }

    function buy(M.Quote calldata q, bytes calldata sig) external payable {
        market.buyStock{value: msg.value}(q, sig, type(uint256).max);
    }

    function sell(M.Quote calldata q, bytes calldata sig) external {
        token.approve(address(market), type(uint256).max);
        market.sellStock(q, sig, 0);
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        M.Quote memory q = next;
        if (q.side == 0) {
            try market.buyStock{value: 0}(q, nextSig, type(uint256).max) {}
            catch (bytes memory err) {
                reentryBlocked = bytes4(err) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
            }
        } else {
            try market.sellStock(q, nextSig, 0) {}
            catch (bytes memory err) {
                reentryBlocked = bytes4(err) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
            }
        }
    }
}

contract SecurityTest is Base {
    Reenterer internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = new Reenterer(market, reliance);
        vm.deal(address(attacker), 1_000 ether);
    }

    // ------------------------------------------------------------- reentrancy

    function test_ReentrancyOnBuyRefundBlocked() public {
        M.Quote memory q1 = _quote(address(attacker), address(reliance), BUY, 1 ether, PRICE);
        M.Quote memory q2 = _quote(address(attacker), address(reliance), BUY, 1 ether, PRICE);
        attacker.arm(q2, _sign(q2));
        attacker.buy{value: 50 ether}(q1, _sign(q1)); // overpay -> refund -> receive() re-enters

        assertTrue(attacker.reentryBlocked());
        assertEq(reliance.balanceOf(address(attacker)), 1 ether, "only one mint");
        assertFalse(market.usedNonces(q2.nonce));
        _assertSolvent();
    }

    function test_ReentrancyOnSellPayoutBlocked() public {
        M.Quote memory b = _quote(address(attacker), address(reliance), BUY, 2 ether, PRICE);
        (,, uint256 cost) = market.quoteBuy(2 ether, PRICE);
        attacker.buy{value: cost}(b, _sign(b));

        M.Quote memory s1 = _quote(address(attacker), address(reliance), SELL, 1 ether, PRICE);
        M.Quote memory s2 = _quote(address(attacker), address(reliance), SELL, 1 ether, PRICE);
        attacker.arm(s2, _sign(s2));
        attacker.sell(s1, _sign(s1)); // payout -> receive() re-enters sellStock

        assertTrue(attacker.reentryBlocked());
        assertEq(reliance.balanceOf(address(attacker)), 1 ether, "only one burn");
        assertEq(market.reserveBalance(), 10 ether);
        _assertSolvent();
    }

    // ------------------------------------------------------------- privileged access

    function test_RevertWhen_UnauthorizedWithdrawals() public {
        _buy(alice, 1 ether, PRICE);
        address[2] memory callers = [alice, signer];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory err = abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], bytes32(0)
            );
            vm.prank(callers[i]);
            vm.expectRevert(err);
            market.withdrawFees(payable(callers[i]), 0.01 ether);
            vm.prank(callers[i]);
            vm.expectRevert(err);
            market.withdrawReserve(payable(callers[i]), 1 ether);
        }
        assertEq(address(market).balance, 10.05 ether);
    }

    function test_RevertWhen_UnauthorizedRoleGrants() public {
        bytes32 role = market.ORACLE_SIGNER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        market.grantRole(role, alice);
    }

    function test_OnlyPaidBuysMint() public {
        // Signer / admin hold no token mint rights; the only mint path is a paid buy.
        bytes32 minter = reliance.MINTER_ROLE();
        assertFalse(reliance.hasRole(minter, admin));
        assertFalse(reliance.hasRole(minter, signer));
        assertFalse(reliance.hasRole(minter, address(factory)));

        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.InsufficientPayment.selector, 0, 10.05 ether));
        market.buyStock{value: 0}(q, sig, type(uint256).max);
    }

    // ------------------------------------------------------------- rounding

    function test_DustBuyRoundsUp() public {
        (uint256 g, uint256 f, uint256 t) = market.quoteBuy(1, 1);
        assertEq(g, 1);
        assertEq(f, 1);
        assertEq(t, 2);
        uint256 total = _buy(alice, 1, 1);
        assertEq(total, 2);
        assertEq(reliance.balanceOf(alice), 1);
    }

    function test_RevertWhen_DustSellRoundsToZero() public {
        _fund(1 ether);
        _buy(alice, 1, 1);
        M.Quote memory q = _quote(alice, address(reliance), SELL, 1, 1);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        reliance.approve(address(market), 1);
        vm.expectRevert(M.ZeroValue.selector);
        market.sellStock(q, sig, 0);
        vm.stopPrank();
    }

    /// Buying then selling at the same price can never return more MON than was paid.
    function testFuzz_RoundTripNeverProfits(uint256 amount, uint256 price) public {
        amount = bound(amount, 1, 1e27);
        price = bound(price, 1, 1e24);
        (,, uint256 cost) = market.quoteBuy(amount, price);
        vm.deal(alice, cost);
        _buy(alice, amount, price);

        (uint256 gross,, uint256 expected) = market.quoteSell(amount, price);
        M.Quote memory q = _quote(alice, address(reliance), SELL, amount, price);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        reliance.approve(address(market), amount);
        if (gross == 0) {
            vm.expectRevert(M.ZeroValue.selector);
            market.sellStock(q, sig, 0);
        } else {
            uint256 payout = market.sellStock(q, sig, 0);
            assertEq(payout, expected);
            assertLe(payout, cost);
        }
        vm.stopPrank();
        _assertSolvent();
        assertEq(address(market).balance, market.reserveBalance() + market.accruedFees());
    }

    /// Whatever the sell price, the contract either pays from reserve or reverts; it never goes insolvent.
    function testFuzz_SolvencyAcrossPrices(uint256 amount, uint256 buyPrice, uint256 sellPrice, uint256 funding)
        public
    {
        amount = bound(amount, 1e12, 1e24);
        buyPrice = bound(buyPrice, 1e9, 1e22);
        sellPrice = bound(sellPrice, 1e9, 1e23);
        funding = bound(funding, 0, 1e24);
        if (funding > 0) _fund(funding);
        (,, uint256 cost) = market.quoteBuy(amount, buyPrice);
        vm.deal(alice, cost);
        _buy(alice, amount, buyPrice);

        (uint256 gross,,) = market.quoteSell(amount, sellPrice);
        uint256 reserve = market.reserveBalance();
        M.Quote memory q = _quote(alice, address(reliance), SELL, amount, sellPrice);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        reliance.approve(address(market), amount);
        if (gross > reserve) vm.expectRevert(abi.encodeWithSelector(M.InsufficientLiquidity.selector, gross, reserve));
        market.sellStock(q, sig, 0);
        vm.stopPrank();
        _assertSolvent();
    }

    // ------------------------------------------------------------- zero values

    function test_RevertWhen_ZeroAmountOrPrice() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 0, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(M.ZeroAmount.selector);
        market.buyStock{value: 1 ether}(q, sig, 1 ether);

        q = _quote(alice, address(reliance), BUY, 1 ether, 0);
        sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(M.ZeroAmount.selector);
        market.buyStock{value: 1 ether}(q, sig, 1 ether);
    }

    function test_RevertWhen_ZeroAddressOrAmountWithdrawal() public {
        _buy(alice, 1 ether, PRICE);
        vm.startPrank(admin);
        vm.expectRevert(M.ZeroAddress.selector);
        market.withdrawFees(payable(address(0)), 1);
        vm.expectRevert(M.ZeroAddress.selector);
        market.withdrawReserve(payable(address(0)), 1);
        vm.expectRevert(M.ZeroAmount.selector);
        market.withdrawFees(payable(admin), 0);
        vm.expectRevert(M.ZeroAmount.selector);
        market.withdrawReserve(payable(admin), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_ZeroAddressConstructors() public {
        vm.expectRevert(BharatEquityTokenFactory.ZeroAddress.selector);
        new BharatEquityTokenFactory(address(0));
        vm.expectRevert(M.ZeroAddress.selector);
        new M(address(0), factory);
    }

    function _fund(uint256 amount) internal {
        vm.deal(admin, admin.balance + amount);
        vm.prank(admin);
        market.fundTreasury{value: amount}();
    }
}
