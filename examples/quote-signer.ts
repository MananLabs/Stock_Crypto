// Oracle quote signing for the NestJS backend (viem). Drop into an @Injectable() service.
//
// The signer key lives ONLY in the backend's secret store (env / KMS). Never ship it to the frontend.
import { parseEther, parseUnits, type Address, type Hex } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

export const MONAD_TESTNET_CHAIN_ID = 10143;

export const QUOTE_TYPES = {
  Quote: [
    { name: "user", type: "address" },
    { name: "token", type: "address" },
    { name: "side", type: "uint8" },
    { name: "amount", type: "uint256" },
    { name: "price", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "marketTimestamp", type: "uint256" },
    { name: "expiry", type: "uint256" },
  ],
} as const;

export const Side = { BUY: 0, SELL: 1 } as const;

export interface Quote {
  user: Address;
  token: Address;
  side: 0 | 1;
  amount: bigint; // 18-decimal token units
  price: bigint; // wei of MON per 1e18 token units
  nonce: bigint;
  marketTimestamp: bigint; // unix seconds of the Upstox data point
  expiry: bigint; // unix seconds
}

export const quoteDomain = (marketplace: Address, chainId = MONAD_TESTNET_CHAIN_ID) =>
  ({ name: "BharatEquityMarketplace", version: "1", chainId, verifyingContract: marketplace }) as const;

/**
 * MON price per whole token, in wei, from INR quotes using fixed-point decimals (no floats).
 *   priceWei = inrStockPrice / monInrRate * 1e18
 * Pass prices as decimal strings exactly as received (e.g. "2948.60", "85.5").
 * Rounds down; the contract rounds buy cost up and sell proceeds down on top of this.
 */
export function monPriceWei(inrStockPrice: string, monInrRate: string): bigint {
  const stock = parseUnits(inrStockPrice, 18); // INR * 1e18
  const rate = parseUnits(monInrRate, 18); // INR per MON * 1e18
  if (rate === 0n) throw new Error("MON/INR rate is zero");
  return (stock * 10n ** 18n) / rate;
}

/** 256-bit random nonce: collision-free without backend state. */
export function randomNonce(): bigint {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return BigInt("0x" + Buffer.from(b).toString("hex"));
}

export class QuoteSigner {
  private readonly account: PrivateKeyAccount;
  private readonly marketplace: Address;
  private readonly chainId: number;
  private readonly ttlSeconds: bigint;

  constructor(privateKey: Hex, marketplace: Address, chainId = MONAD_TESTNET_CHAIN_ID, ttlSeconds = 60n) {
    this.account = privateKeyToAccount(privateKey);
    this.marketplace = marketplace;
    this.chainId = chainId;
    this.ttlSeconds = ttlSeconds;
  }

  get address() {
    return this.account.address;
  }

  async sign(q: Omit<Quote, "nonce" | "expiry"> & Partial<Pick<Quote, "nonce" | "expiry">>) {
    const quote: Quote = {
      ...q,
      nonce: q.nonce ?? randomNonce(),
      expiry: q.expiry ?? BigInt(Math.floor(Date.now() / 1000)) + this.ttlSeconds,
    };
    const signature = await this.account.signTypedData({
      domain: quoteDomain(this.marketplace, this.chainId),
      types: QUOTE_TYPES,
      primaryType: "Quote",
      message: quote,
    });
    return { quote, signature };
  }
}

// ----------------------------------------------------------------------------
// Example (NestJS controller body), run: node examples/quote-signer.ts
// ----------------------------------------------------------------------------
if (import.meta.url === `file://${process.argv[1]}`) {
  // Throwaway key for the demo only (anvil #0). Real deployments read ORACLE_SIGNER_PRIVATE_KEY from a secret store.
  const signer = new QuoteSigner(
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x000000000000000000000000000000000000bEEF",
  );
  const price = monPriceWei("2948.60", "85.50"); // RELIANCE ₹2948.60, 1 MON = ₹85.50
  const now = BigInt(Math.floor(Date.now() / 1000));
  const user = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
  const token = "0x0000000000000000000000000000000000001234";

  const buy = await signer.sign({ user, token, side: Side.BUY, amount: parseEther("0.5"), price, marketTimestamp: now });
  const sell = await signer.sign({ user, token, side: Side.SELL, amount: parseEther("0.25"), price, marketTimestamp: now });
  console.log({ signer: signer.address, priceWei: price, buy, sell });
}
