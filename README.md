# BharatEquity — Smart Contracts (Monad Testnet)

Simulated stock-exposure tokens for Indian listed companies, bought and sold with native MON at prices
signed by the BharatEquity backend (EIP-712).

> **Disclaimer.** The tokens are demo assets that give *simulated* price exposure. They are not shares, give no
> shareholder rights, and are not settled against NSE/BSE.

| | |
|---|---|
| Network | Monad Testnet, chain ID **10143** (`deploy.sh` and `Deploy.s.sol` refuse any other chain) |
| RPC | `https://testnet-rpc.monad.xyz` |
| Explorer | `https://testnet.monadexplorer.com` |
| Compiler | solc 0.8.28, EVM `cancun`, optimizer 200 runs |
| Libraries | OpenZeppelin Contracts 5.6.1 (npm), forge-std 1.9.7 (`lib/`) |

## 1. Architecture

```
                 ┌──────────────────────────────┐   createStockToken (admin)
                 │  BharatEquityTokenFactory     │──────────────┐
                 │  symbol ⇄ token registry      │              ▼
                 │  DEFAULT_ADMIN of every token │   ┌────────────────────────┐
                 └──────────────┬───────────────┘   │ BharatEquityToken ×N    │
                     setMarketplace(grants MINTER)   │ ERC-20, 18 dec          │
                                ▼                    │ mint / burn: MINTER only│
┌──────────┐ signed quote ┌────────────────────────┐ └────────────────────────┘
│ NestJS   │─────────────▶│ BharatEquityMarketplace│── mint on buy, burn on sell
│ oracle   │   (EIP-712)  │ EIP-712 verify, fees,  │
│ signer   │              │ reserve, pause         │◀── buyStock{value} / sellStock
└──────────┘              └────────────────────────┘        (user wallet)
```

| Contract | Responsibility |
|---|---|
| `BharatEquityToken` | One ERC-20 per stock. Stores `stockSymbol`, `companyName`, `exchange`, `DISCLAIMER`. `mint(to, amt)` and `burn(amt)` are `MINTER_ROLE`-only; `burn` only destroys the caller's own balance, so no role can take tokens from a wallet. |
| `BharatEquityTokenFactory` | Deploys and registers tokens (symbol unique, once). Is the token admin, so it alone assigns `MINTER_ROLE`, and only to the current marketplace. New stocks need no marketplace redeploy. |
| `BharatEquityMarketplace` | Verifies quotes, takes MON, mints/burns, tracks `reserveBalance` and `accruedFees`, pays sellers from the reserve only. |

## 2. Permission model

| Role | Holder | Powers |
|---|---|---|
| Factory `DEFAULT_ADMIN_ROLE` | deployer (→ multisig) | `createStockToken`, `setMarketplace` (moves mint rights; target must be a contract) |
| Token `DEFAULT_ADMIN_ROLE` | factory contract only | grant/revoke `MINTER_ROLE` |
| Token `MINTER_ROLE` | marketplace only | `mint`, `burn` (own balance) |
| Marketplace `DEFAULT_ADMIN_ROLE` | deployer (→ multisig) | `withdrawReserve`, `withdrawFees`, `setFeeBps`, `setMaxFeeBps`, `setMaxQuoteAge`, `setTokenEnabled`, `unpause`, grant/revoke roles |
| Marketplace `PAUSER_ROLE` | deployer | `pause` |
| Marketplace `ORACLE_SIGNER_ROLE` | backend signer key(s) | none on-chain; its signatures authorise quotes |

Signer rotation: `grantRole(ORACLE_SIGNER_ROLE, new)` then `revokeRole(ORACLE_SIGNER_ROLE, old)`. Revocation takes
effect at once: outstanding quotes from the old key fail.

There are no other privileged paths. In particular, the deployer, admin and oracle signer **cannot mint**. Tokens
are created only by a paid buy.

## 3. Pricing, fees, rounding

* Quote `price` = wei of MON per **one whole token** (1e18 units).
  Backend: `price = INR_stock_price / MON_INR_rate × 1e18`. This is integer fixed-point arithmetic; see `monPriceWei()` in `examples/quote-signer.ts`.
* `gross = amount × price / 1e18`, `fee = gross × feeBps / 10 000`.
* **Buy** pays `gross + fee`. `gross` and `fee` both round **up**, so dust can never be minted for free (1 wei at
  1 wei/token costs 2 wei).
* **Sell** receives `gross − fee`. `gross` rounds **down** and `fee` rounds **up**. A sell whose gross rounds to 0 reverts with `ZeroValue`.
  A fuzz test checks that buying and then selling at the same price can never return more MON than was paid.
* Fee: default 50 bps (0.5%). `setFeeBps ≤ maxFeeBps` (default 300) `≤ FEE_HARD_CAP_BPS` (1 000, constant).
* Staleness: `block.timestamp ≤ marketTimestamp + maxQuoteAge` (default 120 s, bounds 10 s–1 h), and also
  `block.timestamp ≤ expiry`.

## 4. Reserve accounting

```
address(this).balance  ≥  reserveBalance + accruedFees        (surplus() = the rest, e.g. forced sends)
buy:           reserveBalance += gross;   accruedFees += fee
sell:          require(gross ≤ reserveBalance)
               reserveBalance -= gross;   accruedFees += fee;   pay gross − fee
fundTreasury:  reserveBalance += msg.value          (anyone)
withdrawFees:  ≤ accruedFees                         (admin)
withdrawReserve: ≤ reserveBalance                    (admin)
```

Fees are never used to pay sellers. If the reserve can't cover a sell's gross value, the sell reverts with
`InsufficientLiquidity(required, available)`. It never pays out partially. The contract has no `receive()`, so
MON can only enter through `buyStock` or `fundTreasury`.

**Liquidity caveat (by design):** outstanding tokens are not fully collateralised. If prices rise, the reserve
from buys may not cover every holder. Keep the reserve topped up with `fundTreasury` and watch `availableLiquidity()`.

## 5. Quote signing (EIP-712)

```
Domain  { name: "BharatEquityMarketplace", version: "1", chainId: 10143, verifyingContract: <marketplace> }
Quote(address user,address token,uint8 side,uint256 amount,uint256 price,uint256 nonce,uint256 marketTimestamp,uint256 expiry)
side: 0 = BUY, 1 = SELL
```

The marketplace checks these in order (`_consumeQuote`): `user == msg.sender` → side matches the function →
token registered and enabled → amount and price > 0 → not expired → market data fresh → nonce unused →
signature well-formed (OZ `tryRecover`, rejects high-s) → signer holds `ORACLE_SIGNER_ROLE` → mark nonce used.

The chain ID is bound through the domain separator, not as a struct field. That keeps the struct minimal, and a
quote signed for another chain or another marketplace deployment recovers a different signer and is rejected.
Nonces are global, so the backend should use random 256-bit values. `test/Oracle.t.sol::QuoteVectorTest` checks
a digest and signature produced by viem against the contract, so the backend schema and the contract can't drift
apart unnoticed.

## 6. Security review summary

| Area | Status |
|---|---|
| Reentrancy | `nonReentrant` on buy, sell and both withdrawals. State changes happen before MON transfers. Tests use a hostile receiver that re-enters on refund and on payout. |
| Replay | Global nonce mapping, expiry, staleness window, EIP-712 domain (chain + contract). |
| Quote binding | User, token, side, amount, price and nonce are all signed. Tampering with any field gives an unauthorised signer. A BUY quote sent to `sellStock` reverts `WrongSide`. |
| Mint control | Only the marketplace holds `MINTER_ROLE`. The factory refuses to hand it to an EOA. `burn` can't touch other wallets. |
| Withdrawals | Admin only, limited by the tracked balances, zero address and zero amount rejected. |
| Pause | Stops buys and sells. Treasury functions keep working so funds can be recovered. |

**Trust assumptions to communicate (hackathon MVP):**
1. **Oracle key = pricing authority.** A leaked signer key can sign absurd prices: buy at 1 wei, sell at the
   maximum, and drain the reserve. Mitigations: keep the key in a KMS/secret store, rotate it, `pause()` on alert,
   and keep the reserve small. A production hardening option is per-trade notional caps or on-chain price
   deviation bounds.
2. **Admin is powerful.** It can withdraw the reserve (which blocks sells), change fees up to the cap, and
   repoint the marketplace. Use a multisig and a timelock beyond the hackathon.
3. **Monad charges gas by gas *limit*.** Use `simulateContract` or estimates (as the examples do) rather than
   large fixed limits.

## 7. Build, test, deploy

```bash
cd blockchain
npm ci                                   # OpenZeppelin, viem, solc-js
forge fmt && forge build && forge test -vvv

# one-time: create keystores locally (key never leaves your machine, never goes into chat)
cast wallet new                          # oracle signer: put its private key in the backend secret store
cast wallet import bharatequity-deployer --interactive   # deployer: paste key into the local prompt

# fund the deployer from https://faucet.monad.xyz, then:
ORACLE_SIGNER_ADDRESS=0x... INITIAL_RESERVE_WEI=$(cast to-wei 2) ./script/deploy.sh
./script/verify.sh                       # Sourcify verification on Monad Explorer
```

`deploy.sh` does the following in order:
1. Checks RPC connectivity and that the chain ID is 10143.
2. Prints the deployer address and balance.
3. Runs `forge fmt --check`, `forge build` and `forge test`, and stops if any fail.
4. Prints the deployment plan and asks for confirmation.
5. Broadcasts the deployment with the keystore account.
6. Confirms that every receipt has status `0x1`. If any failed, it moves the address file to `*.unconfirmed`.
7. Re-checks all permissions on-chain (`CheckDeployment.s.sol`) and exports the ABIs.

Outputs:
* `deployments/monad-testnet.json`: factory, marketplace, signer and per-symbol token addresses
* `abis/*.json` and `abis/index.ts` (viem-ready, `as const`)
* `broadcast/Deploy.s.sol/10143/run-latest.json`: raw transaction hashes and receipts

Deploy order (`script/Deploy.s.sol`):
1. Deploy the factory.
2. Deploy the marketplace.
3. `factory.setMarketplace`.
4. Grant `ORACLE_SIGNER_ROLE`.
5. Register the 10 stocks.
6. Optionally fund the reserve.
7. Assert the configuration and write the JSON.

Without Foundry, `node tools/solc-check.mjs --abi contracts test script` compile-checks everything with solc-js and
regenerates the ABIs.

After deployment, `node examples/e2e-demo.ts` (see `docs/INTEGRATION.md`) runs a real fund → buy → sell
cycle and prints Monad Explorer links.
