#!/usr/bin/env bash
# Runs each local package's tests on an iOS simulator via xcodebuild (the platform the app ships on).
set -euo pipefail
cd "$(dirname "$0")/../.."
UDID="${SIMULATOR_UDID:-$(scripts/ci/pick_simulator.sh)}"
for dir in Packages/*/; do
  name=$(basename "$dir")
  schemes=$(cd "$dir" && xcodebuild -list -json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join((d.get("workspace") or d.get("project") or {}).get("schemes", [])))')
  scheme=$(grep -x "${name}-Package" <<<"$schemes" || echo "$name")
  echo "::group::xcodebuild test $name ($scheme)"
  (cd "$dir" && xcodebuild test -scheme "$scheme" -destination "id=$UDID" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO | xcbeautify --renderer github-actions)
  echo "::endgroup::"
done
