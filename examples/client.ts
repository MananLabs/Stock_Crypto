// viem helpers for the BharatEquity frontend (wallet side) and backend (read side).
import {
  createPublicClient,
  http,
  maxUint256,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type Transport,
  type WalletClient,
} from "viem";
import { monadTestnet } from "viem/chains";
import { BharatEquityMarketplaceAbi, BharatEquityTokenAbi, BharatEquityTokenFactoryAbi } from "../abis/index.ts";
import type { Quote } from "./quote-signer.ts";

export type Wallet = WalletClient<Transport, Chain, Account>;

export const publicClient = createPublicClient({ chain: monadTestnet, transport: http() });

export const explorerTx = (hash: Hex) => `${monadTestnet.blockExplorers.default.url}/tx/${hash}`;
export const explorerAddress = (a: Address) => `${monadTestnet.blockExplorers.default.url}/address/${a}`;

/** Every registered stock with the user's balance, in one multicall. */
export async function readPortfolio(factory: Address, user: Address) {
  const tokens = await publicClient.readContract({ address: factory, abi: BharatEquityTokenFactoryAbi, functionName: "allTokens" });
  const calls = tokens.flatMap((t) => [
    { address: t, abi: BharatEquityTokenAbi, functionName: "stockSymbol" } as const,
    { address: t, abi: BharatEquityTokenAbi, functionName: "balanceOf", args: [user] } as const,
  ]);
  const res = await publicClient.multicall({ contracts: calls, allowFailure: false });
  return tokens.map((token, i) => ({ token, symbol: res[2 * i] as string, balance: res[2 * i + 1] as bigint }));
}

export async function readMarketState(marketplace: Address) {
  const c = { address: marketplace, abi: BharatEquityMarketplaceAbi } as const;
  const [reserve, fees, feeBps, maxQuoteAge, paused, balance] = await Promise.all([
    publicClient.readContract({ ...c, functionName: "reserveBalance" }),
    publicClient.readContract({ ...c, functionName: "accruedFees" }),
    publicClient.readContract({ ...c, functionName: "feeBps" }),
    publicClient.readContract({ ...c, functionName: "maxQuoteAge" }),
    publicClient.readContract({ ...c, functionName: "paused" }),
    publicClient.getBalance({ address: marketplace }),
  ]);
  return { reserve, fees, feeBps, maxQuoteAge, paused, balance };
}

/**
 * Buy with a backend-signed quote. `slippageBps` is applied on top of the exact on-chain cost as the
 * maxPayment guard; only the exact cost is charged, any excess value is refunded by the contract.
 */
export async function buyStock(wallet: Wallet, marketplace: Address, quote: Quote, signature: Hex, slippageBps = 0n) {
  const [, , total] = await publicClient.readContract({
    address: marketplace, abi: BharatEquityMarketplaceAbi, functionName: "quoteBuy", args: [quote.amount, quote.price],
  });
  const maxPayment = total + (total * slippageBps) / 10_000n;
  const { request } = await publicClient.simulateContract({
    account: wallet.account, address: marketplace, abi: BharatEquityMarketplaceAbi,
    functionName: "buyStock", args: [quote, signature, maxPayment], value: total,
  });
  const hash = await wallet.writeContract(request);
  return { hash, total, url: explorerTx(hash), receipt: publicClient.waitForTransactionReceipt({ hash }) };
}

/** Sell with a backend-signed quote; approves the marketplace first if the allowance is short. */
export async function sellStock(wallet: Wallet, marketplace: Address, quote: Quote, signature: Hex, minPayout = 0n) {
  const owner = wallet.account.address;
  const allowance = await publicClient.readContract({
    address: quote.token, abi: BharatEquityTokenAbi, functionName: "allowance", args: [owner, marketplace],
  });
  let approveHash: Hex | undefined;
  if (allowance < quote.amount) {
    approveHash = await wallet.writeContract({
      address: quote.token, abi: BharatEquityTokenAbi, functionName: "approve", args: [marketplace, maxUint256],
    });
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
  }
  const { request, result: payout } = await publicClient.simulateContract({
    account: wallet.account, address: marketplace, abi: BharatEquityMarketplaceAbi,
    functionName: "sellStock", args: [quote, signature, minPayout],
  });
  const hash = await wallet.writeContract(request);
  return { hash, approveHash, payout, url: explorerTx(hash), receipt: publicClient.waitForTransactionReceipt({ hash }) };
}

/** Add MON to the sell reserve (anyone may fund). */
export async function fundTreasury(wallet: Wallet, marketplace: Address, amountWei: bigint) {
  const hash = await wallet.writeContract({
    address: marketplace, abi: BharatEquityMarketplaceAbi, functionName: "fundTreasury", value: amountWei,
  });
  return { hash, url: explorerTx(hash), receipt: publicClient.waitForTransactionReceipt({ hash }) };
}
