#!/usr/bin/env bash
# BharatEquity -> Monad Testnet deployment. Refuses any other chain.
# Usage: DEPLOYER_ACCOUNT=bharatequity-deployer ORACLE_SIGNER_ADDRESS=0x... [INITIAL_RESERVE_WEI=...] ./script/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${MONAD_RPC_URL:-https://testnet-rpc.monad.xyz}"
ACCOUNT="${DEPLOYER_ACCOUNT:-bharatequity-deployer}"
EXPECTED_CHAIN=10143
OUT=deployments/monad-testnet.json
: "${ORACLE_SIGNER_ADDRESS:?set ORACLE_SIGNER_ADDRESS (public address of the backend quote signer)}"
export ORACLE_SIGNER_ADDRESS INITIAL_RESERVE_WEI="${INITIAL_RESERVE_WEI:-0}"

for bin in forge cast jq; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done

echo "==> 1/7 RPC connectivity + chain id ($RPC)"
CHAIN=$(cast chain-id --rpc-url "$RPC")
[[ "$CHAIN" == "$EXPECTED_CHAIN" ]] || { echo "ABORT: chain id $CHAIN != $EXPECTED_CHAIN (Monad Testnet)"; exit 1; }
echo "    chain id $CHAIN, block $(cast block-number --rpc-url "$RPC")"

echo "==> 2/7 Deployer (keystore account '$ACCOUNT')"
DEPLOYER=$(cast wallet address --account "$ACCOUNT")
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
echo "    deployer $DEPLOYER"
echo "    balance  $(cast from-wei "$BAL") MON"
echo "    oracle   $ORACLE_SIGNER_ADDRESS"
echo "    reserve  $(cast from-wei "$INITIAL_RESERVE_WEI") MON"

echo "==> 3/7 fmt + build + tests (must all pass)"
forge fmt --check
forge build
forge test

echo "==> 4/7 Plan: BharatEquityTokenFactory -> BharatEquityMarketplace -> setMarketplace -> grant ORACLE_SIGNER_ROLE"
echo "          -> register RELIANCE TCS INFY HDFCBANK ICICIBANK SBIN ITC TATAMOTORS LT BHARTIARTL -> fund reserve"
read -r -p "Deploy to Monad Testnet (chain $CHAIN)? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "aborted"; exit 1; }

echo "==> 5/7 Broadcast"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow

echo "==> 6/7 Confirm receipts"
RUN=broadcast/Deploy.s.sol/$EXPECTED_CHAIN/run-latest.json
FAILED=$(jq '[.receipts[] | select(.status != "0x1")] | length' "$RUN")
TOTAL=$(jq '.receipts | length' "$RUN")
if [[ "$FAILED" != "0" || "$TOTAL" == "0" ]]; then
  mv "$OUT" "$OUT.unconfirmed" 2>/dev/null || true
  echo "ABORT: $FAILED of $TOTAL transactions failed; addresses moved to $OUT.unconfirmed"; exit 1
fi
jq -r '.receipts[] | "    \(.transactionHash)  block \(.blockNumber)"' "$RUN"

echo "==> 7/7 On-chain configuration check + ABI export"
forge script script/CheckDeployment.s.sol:CheckDeployment --rpc-url "$RPC"
./script/export-abis.sh
echo
echo "Deployed. Addresses: $OUT"
echo "Marketplace: https://testnet.monadexplorer.com/address/$(jq -r .marketplace "$OUT")"
echo "Next: ./script/verify.sh  (source verification on Monad Explorer via Sourcify)"
