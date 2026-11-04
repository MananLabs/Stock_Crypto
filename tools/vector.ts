// Prints a fixed EIP-712 vector consumed by test/QuoteVector.t.sol.
import { hashTypedData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { QUOTE_TYPES, quoteDomain } from "../examples/quote-signer.ts";

const domain = quoteDomain("0x000000000000000000000000000000000000bEEF");
const message = {
  user: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", token: "0x0000000000000000000000000000000000001234",
  side: 0, amount: 5n * 10n ** 17n, price: 34486549707602339181n, nonce: 42n, marketTimestamp: 1_800_000_000n, expiry: 1_800_000_060n,
} as const;
const acct = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
console.log("digest", hashTypedData({ domain, types: QUOTE_TYPES, primaryType: "Quote", message }));
console.log("sig   ", await acct.signTypedData({ domain, types: QUOTE_TYPES, primaryType: "Quote", message }));
