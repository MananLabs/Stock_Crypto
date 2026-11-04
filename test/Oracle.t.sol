// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BharatEquityMarketplace as M} from "../contracts/BharatEquityMarketplace.sol";
import {Base} from "./Base.t.sol";

contract OracleTest is Base {
    function _expectUnauthorized(M.Quote memory signed, M.Quote memory submitted, address from) internal {
        bytes memory sig = _sign(signed);
        bytes32 digest = market.hashQuote(submitted);
        address recovered = ecrecover(digest, uint8(sig[64]), _slice(sig, 0), _slice(sig, 32));
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(M.UnauthorizedSigner.selector, recovered));
        if (submitted.side == BUY) market.buyStock{value: 100 ether}(submitted, sig, 100 ether);
        else market.sellStock(submitted, sig, 0);
    }

    function _slice(bytes memory b, uint256 at) internal pure returns (bytes32 r) {
        assembly {
            r := mload(add(add(b, 32), at))
        }
    }

    function test_ValidQuote() public {
        _buy(alice, 1 ether, PRICE);
        assertEq(reliance.balanceOf(alice), 1 ether);
    }

    function test_RevertWhen_SignedByUnknownKey() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q, 0xBAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.UnauthorizedSigner.selector, vm.addr(0xBAD)));
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function test_RevertWhen_UserSignsOwnQuote() public {
        (address eve, uint256 eveKey) = makeAddrAndKey("eve");
        vm.deal(eve, 100 ether);
        M.Quote memory q = _quote(eve, address(reliance), BUY, 1 ether, 1 wei);
        bytes memory sig = _sign(q, eveKey);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(M.UnauthorizedSigner.selector, eve));
        market.buyStock{value: 1 ether}(q, sig, 1 ether);
    }

    function test_RevertWhen_MalformedSignature() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory good = _sign(q);

        bytes memory short = new bytes(10);
        vm.prank(alice);
        vm.expectRevert(M.InvalidSignature.selector);
        market.buyStock{value: 11 ether}(q, short, 11 ether);

        // High-s malleated signature must be rejected.
        bytes32 r = _slice(good, 0);
        bytes32 s = _slice(good, 32);
        uint8 v = uint8(good[64]);
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory malleated = abi.encodePacked(r, bytes32(uint256(n) - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.prank(alice);
        vm.expectRevert(M.InvalidSignature.selector);
        market.buyStock{value: 11 ether}(q, malleated, 11 ether);

        bytes memory badV = abi.encodePacked(r, s, uint8(29));
        vm.prank(alice);
        vm.expectRevert(M.InvalidSignature.selector);
        market.buyStock{value: 11 ether}(q, badV, 11 ether);
    }

    function test_RevertWhen_Expired() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.warp(q.expiry + 1);
        vm.prank(alice);
        vm.expectRevert(M.QuoteExpired.selector);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function test_AcceptsAtExactExpiry() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.warp(q.expiry);
        vm.prank(alice);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function test_RevertWhen_StaleMarketData() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        q.marketTimestamp = block.timestamp - market.maxQuoteAge() - 1;
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(M.StaleMarketData.selector);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function test_RevertWhen_NonceReplayed() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
        vm.expectRevert(abi.encodeWithSelector(M.NonceAlreadyUsed.selector, q.nonce));
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_NonceReusedAcrossUsers() public {
        M.Quote memory a = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        M.Quote memory b = _quote(bob, address(reliance), BUY, 1 ether, PRICE);
        b.nonce = a.nonce;
        bytes memory sa = _sign(a);
        bytes memory sb = _sign(b);
        vm.prank(alice);
        market.buyStock{value: 11 ether}(a, sa, 11 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M.NonceAlreadyUsed.selector, a.nonce));
        market.buyStock{value: 11 ether}(b, sb, 11 ether);
    }

    function test_RevertWhen_WrongUserSubmits() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(bob);
        vm.expectRevert(M.WrongUser.selector);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function test_RevertWhen_UserFieldRewritten() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        M.Quote memory forged = _copy(q);
        forged.user = bob;
        _expectUnauthorized(q, forged, bob);
    }

    function test_RevertWhen_WrongToken() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        M.Quote memory forged = _copy(q);
        forged.token = address(tcs);
        _expectUnauthorized(q, forged, alice);
    }

    function test_RevertWhen_WrongSide() public {
        _fund(100 ether);
        vm.prank(address(market));
        reliance.mint(alice, 5 ether);

        // BUY quote submitted to sellStock.
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(M.WrongSide.selector);
        market.sellStock(q, sig, 0);

        // BUY quote with the side field flipped to SELL: signature no longer matches.
        M.Quote memory flipped = _copy(q);
        flipped.side = SELL;
        vm.prank(alice);
        reliance.approve(address(market), 5 ether);
        _expectUnauthorized(q, flipped, alice);
    }

    function test_RevertWhen_WrongAmount() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        M.Quote memory forged = _copy(q);
        forged.amount = 2 ether;
        _expectUnauthorized(q, forged, alice);

        forged = _copy(q);
        forged.price = 1 wei;
        _expectUnauthorized(q, forged, alice);
    }

    function test_RevertWhen_SignerRevoked() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q);
        bytes32 role = market.ORACLE_SIGNER_ROLE();
        vm.prank(admin);
        market.revokeRole(role, signer);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.UnauthorizedSigner.selector, signer));
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function test_SignerRotation() public {
        uint256 newKey = 0xB0B;
        bytes32 role = market.ORACLE_SIGNER_ROLE();
        vm.startPrank(admin);
        market.grantRole(role, vm.addr(newKey));
        market.revokeRole(role, signer);
        vm.stopPrank();

        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        bytes memory sig = _sign(q, newKey);
        vm.prank(alice);
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
        assertEq(reliance.balanceOf(alice), 1 ether);
    }

    function test_RevertWhen_WrongChain() public {
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        uint256 chain = block.chainid;
        vm.chainId(1);
        bytes memory sig = _sign(q); // digest under chainId 1
        vm.chainId(chain);
        bytes32 digest = market.hashQuote(q);
        address recovered = ecrecover(digest, uint8(sig[64]), _slice(sig, 0), _slice(sig, 32));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.UnauthorizedSigner.selector, recovered));
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function test_RevertWhen_SignedForOtherMarketplace() public {
        M other = new M(admin, factory);
        M.Quote memory q = _quote(alice, address(reliance), BUY, 1 ether, PRICE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, other.hashQuote(q));
        bytes memory sig = abi.encodePacked(r, s, v);
        address recovered = ecrecover(market.hashQuote(q), v, r, s);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.UnauthorizedSigner.selector, recovered));
        market.buyStock{value: 11 ether}(q, sig, 11 ether);
    }

    function _copy(M.Quote memory q) internal pure returns (M.Quote memory c) {
        c = M.Quote(q.user, q.token, q.side, q.amount, q.price, q.nonce, q.marketTimestamp, q.expiry);
    }

    function _fund(uint256 amount) internal {
        vm.prank(admin);
        market.fundTreasury{value: amount}();
    }
}

/// Cross-implementation check: digest and signature produced by viem (tools/vector.ts) must verify on-chain.
contract QuoteVectorTest is Base {
    function test_ViemVectorMatches() public {
        vm.chainId(10143);
        address at = 0x000000000000000000000000000000000000bEEF;
        deployCodeTo("BharatEquityMarketplace.sol:BharatEquityMarketplace", abi.encode(admin, address(factory)), at);
        M m = M(at);

        M.Quote memory q = M.Quote({
            user: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            token: 0x0000000000000000000000000000000000001234,
            side: 0,
            amount: 0.5 ether,
            price: 34486549707602339181,
            nonce: 42,
            marketTimestamp: 1_800_000_000,
            expiry: 1_800_000_060
        });
        bytes32 expected = 0xdff71fd94bc9de4f875f6e6cd652588a5a21a784e0b492314c17d73dd3cad4ed;
        assertEq(m.hashQuote(q), expected, "digest mismatch with viem");

        bytes memory sig =
            hex"41ddca68bde8f264c51c362b17d4b861f967f060baac23fdc765727ff166a4c827a11494d7d7e4e246785a9e1bcd560f10f9315dc38eb97e215dcc74013189661b";
        bytes32 r;
        bytes32 s;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
        }
        assertEq(ecrecover(expected, uint8(sig[64]), r, s), 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    }
}
