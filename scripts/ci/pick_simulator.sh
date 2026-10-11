#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime.
set -euo pipefail
xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devs = json.load(sys.stdin)["devices"]
ios = sorted((k for k in devs if "iOS" in k and devs[k]),
             key=lambda k: [int(x) for x in re.findall(r"\d+", k.split("iOS")[-1])], reverse=True)
for rt in ios:
    for d in devs[rt]:
        if d["name"].startswith("iPhone"):
            print(d["udid"]); sys.exit(0)
sys.exit("no available iPhone simulator")
'
