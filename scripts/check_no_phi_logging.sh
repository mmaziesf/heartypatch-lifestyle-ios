#!/usr/bin/env bash
# Fails if modules that touch health data use print() / NSLog / debugPrint, or Logger interpolation without .private.
# Architecture §10 / §14 step 5. Applies to HPLHealth, HPLIngest, HPLStore, HPLCloud (and HPLBridge: raw events).
set -euo pipefail
cd "$(dirname "$0")/.."
DIRS=(Packages/HPLHealth/Sources Packages/HPLIngest/Sources Packages/HPLStore/Sources Packages/HPLCloud/Sources Packages/HPLBridge/Sources)
fail=0
if grep -rnE '(^|[^[:alnum:]_.])(print|debugPrint|NSLog|dump)[[:space:]]*\(' "${DIRS[@]}" --include='*.swift'; then
  echo "error: print/debugPrint/NSLog/dump is forbidden in health-data modules" >&2; fail=1
fi
# Any Logger call with \( interpolation must mark every interpolation privacy: .private (or .sensitive).
while IFS= read -r line; do
  interps=$(grep -o '\\(' <<<"$line" | wc -l)
  privs=$(grep -oE 'privacy:[[:space:]]*\.(private|sensitive)' <<<"$line" | wc -l)
  if (( interps > privs )); then echo "$line"; fail=1; fi
done < <(grep -rnE '\b(logger|log|Logger\([^)]*\))\.(debug|info|notice|log|error|warning|fault|critical|trace)\(' "${DIRS[@]}" --include='*.swift' | grep '\\(' || true)
(( fail )) && { echo "error: non-private log interpolation in health-data modules" >&2; exit 1; }
echo "PHI logging check passed (${#DIRS[@]} modules)."
