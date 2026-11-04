// End-to-end demo on Monad Testnet: fund reserve -> buy RELIANCE -> sell half. Prints real tx hashes.
//
// Run locally (keys are read from env, never printed):
//   ORACLE_SIGNER_PRIVATE_KEY=... TRADER_PRIVATE_KEY=... node examples/e2e-demo.ts
// The trader needs testnet MON (faucet: https://faucet.monad.xyz). FUND_RESERVE_MON (default 0) tops up liquidity.
import fs from "node:fs";
import { createWalletClient, formatEther, http, parseEther, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { monadTestnet } from "viem/chains";
import { buyStock, fundTreasury, publicClient, readMarketState, readPortfolio, sellStock } from "./client.ts";
import { monPriceWei, QuoteSigner, Side } from "./quote-signer.ts";

const env = (k: string) => process.env[k] ?? (() => { throw new Error(`missing env ${k}`); })();
const dep = JSON.parse(fs.readFileSync(new URL("../deployments/monad-testnet.json", import.meta.url), "utf8")) as {
  factory: Address; marketplace: Address; tokens: Record<string, Address>;
};

if ((await publicClient.getChainId()) !== 10143) throw new Error("RPC is not Monad Testnet");

const trader = createWalletClient({ account: privateKeyToAccount(env("TRADER_PRIVATE_KEY") as Hex), chain: monadTestnet, transport: http() });
const oracle = new QuoteSigner(env("ORACLE_SIGNER_PRIVATE_KEY") as Hex, dep.marketplace);
const me = trader.account.address;
const token = dep.tokens.RELIANCE;

// In production these come from Upstox + a MON/INR feed in the NestJS backend.
const price = monPriceWei("2948.60", "85.50");
const now = () => BigInt(Math.floor(Date.now() / 1000));
console.log(`trader ${me}  balance ${formatEther(await publicClient.getBalance({ address: me }))} MON`);
console.log(`RELIANCE price ${formatEther(price)} MON/token (illustrative INR 2948.60 @ 85.50)`);

const fund = process.env.FUND_RESERVE_MON;
if (fund && fund !== "0") {
  const f = await fundTreasury(trader, dep.marketplace, parseEther(fund));
  console.log(`fundTreasury ${fund} MON  ${f.url}  status=${(await f.receipt).status}`);
}

const buyAmount = parseEther("0.02");
const b = await oracle.sign({ user: me, token, side: Side.BUY, amount: buyAmount, price, marketTimestamp: now() });
const buy = await buyStock(trader, dep.marketplace, b.quote, b.signature, 50n);
console.log(`buy  0.02 RELIANCE for ${formatEther(buy.total)} MON  ${buy.url}  status=${(await buy.receipt).status}`);

const s = await oracle.sign({ user: me, token, side: Side.SELL, amount: buyAmount / 2n, price, marketTimestamp: now() });
const sell = await sellStock(trader, dep.marketplace, s.quote, s.signature);
if (sell.approveHash) console.log(`approve  https://testnet.monadexplorer.com/tx/${sell.approveHash}`);
console.log(`sell 0.01 RELIANCE for ${formatEther(sell.payout)} MON  ${sell.url}  status=${(await sell.receipt).status}`);

const holdings = (await readPortfolio(dep.factory, me)).filter((h) => h.balance > 0n);
console.log("holdings", holdings.map((h) => `${h.symbol}=${formatEther(h.balance)}`).join(" "));
const st = await readMarketState(dep.marketplace);
console.log(`reserve ${formatEther(st.reserve)} MON  fees ${formatEther(st.fees)} MON`);
