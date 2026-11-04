// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {BharatEquityToken} from "../contracts/BharatEquityToken.sol";
import {BharatEquityTokenFactory} from "../contracts/BharatEquityTokenFactory.sol";
import {BharatEquityMarketplace} from "../contracts/BharatEquityMarketplace.sol";

abstract contract Base is Test {
    BharatEquityTokenFactory internal factory;
    BharatEquityMarketplace internal market;
    BharatEquityToken internal reliance;
    BharatEquityToken internal tcs;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    uint256 internal constant PRICE = 10 ether; // 10 MON per whole token
    uint8 internal constant BUY = 0;
    uint8 internal constant SELL = 1;

    uint256 private _nonce = 1;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        signer = vm.addr(signerKey);

        vm.startPrank(admin);
        factory = new BharatEquityTokenFactory(admin);
        market = new BharatEquityMarketplace(admin, factory);
        factory.setMarketplace(address(market));
        market.grantRole(market.ORACLE_SIGNER_ROLE(), signer);
        reliance = BharatEquityToken(
            factory.createStockToken(
                "RELIANCE", "Reliance Industries (BharatEquity Demo)", "beRELIANCE", "Reliance Industries", "NSE"
            )
        );
        tcs = BharatEquityToken(
            factory.createStockToken("TCS", "Tata Consultancy Services (BharatEquity Demo)", "beTCS", "TCS", "NSE")
        );
        vm.stopPrank();

        vm.deal(admin, 1_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    function _quote(address user, address token, uint8 side, uint256 amount, uint256 price)
        internal
        returns (BharatEquityMarketplace.Quote memory q)
    {
        q = BharatEquityMarketplace.Quote({
            user: user,
            token: token,
            side: side,
            amount: amount,
            price: price,
            nonce: _nonce++,
            marketTimestamp: block.timestamp,
            expiry: block.timestamp + 60
        });
    }

    function _sign(BharatEquityMarketplace.Quote memory q, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, market.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _sign(BharatEquityMarketplace.Quote memory q) internal view returns (bytes memory) {
        return _sign(q, signerKey);
    }

    /// Buys `amount` RELIANCE for `user` at `price`, paying exactly the quoted total.
    function _buy(address user, uint256 amount, uint256 price) internal returns (uint256 total) {
        BharatEquityMarketplace.Quote memory q = _quote(user, address(reliance), BUY, amount, price);
        (,, total) = market.quoteBuy(amount, price);
        bytes memory sig = _sign(q); // sign before prank: _sign makes an external call
        vm.prank(user);
        market.buyStock{value: total}(q, sig, total);
    }

    function _sell(address user, uint256 amount, uint256 price) internal returns (uint256 payout) {
        BharatEquityMarketplace.Quote memory q = _quote(user, address(reliance), SELL, amount, price);
        vm.startPrank(user);
        reliance.approve(address(market), amount);
        payout = market.sellStock(q, _sign(q), 0);
        vm.stopPrank();
    }

    function _assertSolvent() internal view {
        assertGe(address(market).balance, market.reserveBalance() + market.accruedFees(), "insolvent");
    }
}
