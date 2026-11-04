#!/usr/bin/env bash
# Verifies all deployed contracts on Monad Testnet via Monad's Sourcify instance (no API key needed).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=deployments/monad-testnet.json
VERIFY=(--chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org)

forge verify-contract "$(jq -r .factory $OUT)" contracts/BharatEquityTokenFactory.sol:BharatEquityTokenFactory "${VERIFY[@]}"
forge verify-contract "$(jq -r .marketplace $OUT)" contracts/BharatEquityMarketplace.sol:BharatEquityMarketplace "${VERIFY[@]}"
for addr in $(jq -r '.tokens[]' $OUT); do
  forge verify-contract "$addr" contracts/BharatEquityToken.sol:BharatEquityToken "${VERIFY[@]}"
done
