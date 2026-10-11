#!/usr/bin/env bash
# Runs `swift test` for every local package. Works on macOS (Xcode toolchain) and Linux (swift.org toolchain).
# SwiftUI views compile only on Apple platforms; everything else, including AppModel, is tested everywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
ORDER=(HPLCore HPLStore HPLHealth HPLIngest HPLInference HPLPipeline HPLBridge HPLCloud HPLUI)
for p in "${ORDER[@]}"; do
  echo "::group::swift test $p"
  swift test --package-path "Packages/$p" "$@"
  echo "::endgroup::"
done
echo "All ${#ORDER[@]} packages passed."
