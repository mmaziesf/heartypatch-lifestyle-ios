#!/usr/bin/env bash
# Architecture §7.4 / §10: only HPLCloud's HTTPSCloudTransport may use networking APIs. Fails CI if anything else does.
set -euo pipefail
cd "$(dirname "$0")/.."
ALLOWED="Packages/HPLCloud/Sources/HPLCloud/HTTPSCloudTransport.swift"
PATTERN='URLSession|URLRequest|NWConnection|NWPathMonitor|import Network|FoundationNetworking|CFNetwork|CFStream|Socket\(|WebSocket|dataTask|uploadTask|downloadTask|BGURLSession'
hits=$(grep -rnE "$PATTERN" App Packages/*/Sources --include=*.swift | grep -v "^$ALLOWED:" || true)
if [[ -n "$hits" ]]; then
  echo "Networking outside $ALLOWED (only EgressGate's transport may talk to the network):"
  echo "$hits"
  exit 1
fi
echo "Egress boundary check passed (networking only in $ALLOWED)."
