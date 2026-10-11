#!/usr/bin/env python3
"""App Store / TestFlight copy check (architecture §13, M7 "App Store copy reviewed for claims").

- Metadata/app-store/<locale>/*.txt must pass the same blocklist the app's OutputGuard uses (parsed from
  OutputGuard.swift so the two can't drift), after removing the canonical disclaimer (parsed from Disclaimer.swift),
  plus store-specific overclaims ("anonymous", "HIPAA", "FDA", "detect", ...).
- description.txt must contain the disclaimer verbatim.
- App Store length limits: name/subtitle 30, keywords 100, promotional text 170, description 4000.
- App/PrivacyInfo.xcprivacy must parse, declare no tracking and no collected data (nothing leaves the device).
"""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
META = ROOT / "Metadata" / "app-store"
LIMITS = {"name.txt": 30, "subtitle.txt": 30, "keywords.txt": 100, "promotional_text.txt": 170, "description.txt": 4000}
OVERCLAIMS = ["anonymous", "anonymized", "hipaa", "fda", "clinically", "medical-grade", "detect", "early warning", "guarantee",
              "100%", "heart health", "prevent", "doctor-approved", "certified"]


def swift_blocklist():
    src = (ROOT / "Packages/HPLInference/Sources/HPLInference/OutputGuard.swift").read_text(encoding="utf-8")
    block = re.search(r"blockedPhrases: \[String\] = \[(.*?)\]", src, re.S)
    return re.findall(r'"([^"]+)"', block.group(1))


def disclaimer():
    src = (ROOT / "Packages/HPLCore/Sources/HPLCore/Disclaimer.swift").read_text(encoding="utf-8")
    body = re.search(r'text = """\n(.*?)\n\s*"""', src, re.S).group(1)
    return "".join(line.strip().rstrip("\\") if line.rstrip().endswith("\\") else line.strip() for line in body.splitlines())


def main() -> int:
    failures = []
    phrases = swift_blocklist()
    canon = disclaimer()
    locales = [p for p in META.iterdir() if p.is_dir()]
    if not locales:
        failures.append("no Metadata/app-store/<locale>/ folders")
    for loc in locales:
        desc = (loc / "description.txt").read_text(encoding="utf-8")
        if canon not in desc:
            failures.append(f"{loc.name}/description.txt: must include the disclaimer verbatim")
        for f in sorted(loc.glob("*.txt")):
            text = f.read_text(encoding="utf-8").strip()
            if f.name in LIMITS and len(text) > LIMITS[f.name]:
                failures.append(f"{loc.name}/{f.name}: {len(text)} chars > {LIMITS[f.name]}")
            if f.name.endswith("_url.txt"):
                continue
            lower = text.replace(canon, " ").lower()
            for p in phrases + OVERCLAIMS:
                if p.lower() in lower:
                    failures.append(f"{loc.name}/{f.name}: blocked phrase {p!r}")
            print(f"ok   {loc.name}/{f.name}")

    manifest = plistlib.loads((ROOT / "App/PrivacyInfo.xcprivacy").read_bytes())
    if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains"):
        failures.append("PrivacyInfo.xcprivacy: tracking must be false with no domains")
    if manifest.get("NSPrivacyCollectedDataTypes"):
        failures.append("PrivacyInfo.xcprivacy: collected data types must be empty while nothing leaves the device")
    print("ok   App/PrivacyInfo.xcprivacy")

    if failures:
        print("\n".join(["", "FAILURES:"] + failures), file=sys.stderr)
        return 1
    print(f"\nStore copy check passed ({len(phrases)} guard phrases + {len(OVERCLAIMS)} overclaim terms).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
