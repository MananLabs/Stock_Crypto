# Backend & Frontend Integration

Addresses: `blockchain/deployments/monad-testnet.json`. ABIs: `blockchain/abis/` (`index.ts` exports
`BharatEquityMarketplaceAbi`, `BharatEquityTokenAbi`, `BharatEquityTokenFactoryAbi` typed `as const` for viem).
Chain: `import { monadTestnet } from "viem/chains"` (id 10143).

## Flow

```
Frontend                         NestJS backend                         Monad Testnet
   │ POST /quotes {symbol, side,     │                                      │
   │   amount, user}                 │ Upstox LTP (INR) + MON/INR rate      │
   │────────────────────────────────▶│ price = monPriceWei(inr, monInr)     │
   │                                 │ sign EIP-712 Quote (oracle key)      │
   │◀──── {quote, signature} ────────│                                      │
   │ buyStock{value}(quote, sig, maxPayment) / approve + sellStock ───────▶│
   │◀──────────── tx hash → receipt → explorer link ───────────────────────│
```

## Backend: signing quotes (NestJS + viem)

`examples/quote-signer.ts` is a drop-in for an injectable service:

```ts
import { QuoteSigner, monPriceWei, Side } from "./quote-signer";

@Injectable()
export class QuoteService {
  private signer = new QuoteSigner(process.env.ORACLE_SIGNER_PRIVATE_KEY as Hex, deployments.marketplace);

  async quote(user: Address, symbol: string, side: "BUY" | "SELL", amount: bigint) {
    const { ltp, timestamp } = await this.upstox.ltp(symbol);       // INR as decimal string, unix seconds
    const monInr = await this.rates.monInr();                       // decimal string
    return this.signer.sign({
      user, token: deployments.tokens[symbol], side: Side[side], amount,
      price: monPriceWei(ltp, monInr), marketTimestamp: BigInt(timestamp),
    }); // -> { quote, signature }, 60 s expiry, random 256-bit nonce
  }
}
```

Backend rules:
* **Key custody.** Read `ORACLE_SIGNER_PRIVATE_KEY` from a secret store. Never log it or return it in a response.
* **Market timestamp.** Set `marketTimestamp` from the actual market-data time. The contract rejects data older
  than `maxQuoteAge` (default 120 s). If the market is closed, either refuse quotes or quote off the last close
  with a fresh timestamp, and say so in the UI.
* **Amounts.** Use 18 decimals: `parseUnits("0.5", 18)` means half a token.
* **Optional pre-check.** Before signing a sell, check `availableLiquidity()` so the user doesn't sign a
  transaction that will revert.

### Typed data (for other signers / debugging)

```ts
domain = { name: "BharatEquityMarketplace", version: "1", chainId: 10143, verifyingContract: marketplace }
types  = { Quote: [
  { name: "user", type: "address" }, { name: "token", type: "address" }, { name: "side", type: "uint8" },
  { name: "amount", type: "uint256" }, { name: "price", type: "uint256" }, { name: "nonce", type: "uint256" },
  { name: "marketTimestamp", type: "uint256" }, { name: "expiry", type: "uint256" } ] }
```

`marketplace.hashQuote(quote)` returns the exact digest the signer must sign, so you can compare it with viem's
`hashTypedData`.

## Frontend: reading and trading (`examples/client.ts`)

| Need | Call |
|---|---|
| Token balances | `readPortfolio(factory, user)`: one multicall over `factory.allTokens()` |
| Reserve / fees / pause | `readMarketState(marketplace)` |
| Exact cost before buying | `marketplace.quoteBuy(amount, price)` → `(gross, fee, total)` |
| Exact payout before selling | `marketplace.quoteSell(amount, price)` → `(gross, fee, payout)` |
| Buy | `buyStock(wallet, marketplace, quote, sig, slippageBps)`: simulate, then send with `value = total` |
| Sell | `sellStock(wallet, marketplace, quote, sig, minPayout)`: approves if needed, then sells |
| Fund reserve | `fundTreasury(wallet, marketplace, wei)` |
| Confirmation | `publicClient.waitForTransactionReceipt({ hash })` → `status: "success" \| "reverted"` |
| Explorer link | `https://testnet.monadexplorer.com/tx/<hash>` (`explorerTx(hash)`) |

`wallet` is any viem `WalletClient` with an account, e.g. MetaMask:

```ts
const wallet = createWalletClient({ chain: monadTestnet, transport: custom(window.ethereum!) });
await wallet.switchChain({ id: monadTestnet.id }).catch(() => wallet.addChain({ chain: monadTestnet }));
const [account] = await wallet.requestAddresses();
```

### Example transactions

```ts
// Buy 0.5 RELIANCE (quote from backend)
const { quote, signature } = await api.post("/quotes", { user, symbol: "RELIANCE", side: "BUY", amount: "0.5" });
const buy = await buyStock(wallet, marketplace, quote, signature, 50n);   // 0.5% slippage headroom
toast(`Submitted ${buy.url}`); const r = await buy.receipt;              // r.status === "success"

// Sell 0.25 RELIANCE
const s = await api.post("/quotes", { user, symbol: "RELIANCE", side: "SELL", amount: "0.25" });
const sell = await sellStock(wallet, marketplace, s.quote, s.signature, s.expectedPayout * 995n / 1000n);

// Treasury funding (ops)
await fundTreasury(wallet, marketplace, parseEther("5"));
```

### Revert reasons to map to UI messages

| Error | Meaning |
|---|---|
| `QuoteExpired`, `StaleMarketData` | Request a fresh quote |
| `NonceAlreadyUsed` | Quote already used |
| `InsufficientLiquidity(required, available)` | Reserve too low; try a smaller sell |
| `SlippageExceeded(actual, limit)` | Price moved beyond the user's limit |
| `InsufficientPayment` | `value` was less than the cost |
| `TokenIsDisabled`, `EnforcedPause` | Trading halted by admin |
| `WrongUser`, `WrongSide`, `UnauthorizedSigner`, `InvalidSignature` | Bad or tampered quote |
| `ERC20InsufficientBalance` / `ERC20InsufficientAllowance` | Not enough tokens, or approval missing |

viem decodes these automatically when `simulateContract` is given the ABI.

## End-to-end check after deployment

```bash
cd blockchain
ORACLE_SIGNER_PRIVATE_KEY=... TRADER_PRIVATE_KEY=... FUND_RESERVE_MON=1 node examples/e2e-demo.ts
```

Funds the reserve, buys 0.02 RELIANCE, sells 0.01 and prints each Monad Explorer link with its receipt status.
Run it with env vars from your local shell or a secret manager. Don't paste keys into chat.
