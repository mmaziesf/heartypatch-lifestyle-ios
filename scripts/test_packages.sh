#!/usr/bin/env bash
# Runs `swift test` for every local package. Works on macOS (Xcode toolchain) and Linux (swift.org toolchain).
# SwiftUI views compile only on Apple platforms; everything else, including AppModel, is tested everywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
ORDER=(HPLCore HPLStore HPLHealth HPLIngest HPLInference HPLPipeline HPLBridge HPLCloud HPLUI)
for p in "${ORDER[@]}"; do
  echo "::group::swift test $p"
  extra=()
  # SwiftData segfaults when many stores are opened/used in parallel tests (macOS CI run 38129994082); keep HPLStore serial.
  [[ "$p" == HPLStore ]] && extra=(--no-parallel)
  swift test --package-path "Packages/$p" ${extra[@]+"${extra[@]}"} "$@"
  echo "::endgroup::"
done
echo "All ${#ORDER[@]} packages passed."
