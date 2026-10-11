# HeartyPatch Lifestyle (M0)

Local-first iOS app: Apple Watch / HealthKit + your confirmed blood work (+ Ray-Ban meal logs later) → an on-device daily summary → coaching-style lifestyle notes and self-experiments.

> **Not medical advice.** HeartyPatch Lifestyle provides general wellness information and self-experiment ideas based on data you choose to share with it. It is not a medical device and does not diagnose, treat, cure, or prevent any disease or provide medical advice. Lab values are shown as printed on your report; we do not interpret them. Talk to a qualified clinician about any health concern or before changing medications, diet, or exercise in significant ways. If you think you may have a medical emergency, call your local emergency number.

- Architecture: [`docs/architecture.md`](docs/architecture.md) (one-page: [`docs/architecture-SUMMARY.md`](docs/architecture-SUMMARY.md))
- Milestone: **M0**. Skeleton, contracts, disclaimer gate, rules-only path. No HealthKit yet.

## What M0 does

| Exit criterion (§11, §14) | Where |
|---|---|
| 9 local Swift packages (§9.1) | `Packages/HPL*` |
| CI: schemas, lint, Linux + macOS `swift test`, iOS simulator build + tests | `.github/workflows/ci.yml` |
| `hpl.daily_summary.v1` + `hpl.event.v1` JSON Schemas, round-trip tests | `Spec/`, `Fixtures/`, `Packages/HPLCore/Tests` |
| Tab shell (Today / Labs / Meals / Insights / Settings) + disclaimer acknowledged once, shown in Settings | `Packages/HPLUI`, `App/` |
| Rules-only engine: fixture → rules → engine → output guard → Today | `HPLPipeline`, `HPLInference` |
| No PHI in logs (CI grep) + SwiftLint `no_print` | `scripts/check_no_phi_logging.sh`, `.swiftlint.yml` |

**Data honesty:** M0 has no HealthKit. Today runs on `Fixtures/daily_summary/d0.synthetic.json` (`"provenance": "synthetic_fixture"`), and the screen shows a **SYNTHETIC FIXTURE** banner. Every valid fixture filename must contain `.synthetic.` (CI enforces this).

## Open in Xcode

Requires Xcode 26+ (iOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd heartypatch-lifestyle
xcodegen generate                      # creates HeartyPatchLifestyle.xcodeproj (git-ignored)
open HeartyPatchLifestyle.xcodeproj
```

Pick the **HeartyPatchLifestyle** scheme and an iPhone simulator, then Run. First launch shows the disclaimer; after you acknowledge it, you land on the tabs. To run on a device, set your team under Signing & Capabilities (or `DEVELOPMENT_TEAM` in `project.yml`).

To work on a single module, open its folder directly: `open Packages/HPLCore/Package.swift`.

## Test

```bash
scripts/test_packages.sh               # swift test, all 9 packages (macOS or Linux)
python3 scripts/validate_specs.py      # schemas valid; good fixtures pass; bad fixtures fail  (pip install jsonschema)
python3 scripts/test_spec_roundtrip.py # Python mirror of the Swift round-trip tests
scripts/check_no_phi_logging.sh        # no print/NSLog/public Logger interpolation in health modules
swiftlint lint --strict
```

The SwiftUI views (`HPLUI/Views.swift`) compile only on Apple platforms. Everything else, including `AppModel`, the disclaimer gate, and the end-to-end rules path, is tested on Linux too.

## Layout

```
App/                 @main SwiftUI entry (target defined in project.yml)
Packages/
  HPLCore            DailySummaryV1, HPLEventV1, JSONValue, Recommendation, Consent, Disclaimer, labeled fixtures
  HPLStore           ConsentRepository impls (M0: UserDefaults; M1: SwiftData, FileProtection complete)
  HPLHealth          HealthKit boundary (M1). Stub, no fake samples
  HPLIngest          Lab OCR/parse/confirm (M2). Stub
  HPLInference       InsightEngine protocol, RulesOnlyEngine, OutputGuard
  HPLPipeline        RulesEngine (3 rules), DailyPipeline with fallback to rules-only
  HPLBridge          EventInbox: decode, idempotency, unknown-type ignore (HMAC in M5)
  HPLCloud           EgressGate, hard-disabled until M6
  HPLUI              AppModel + SwiftUI shell
Spec/                hpl.daily_summary.v1.schema.json, hpl.event.v1.schema.json (JSON Schema 2020-12)
Fixtures/            synthetic valid fixtures + deliberately invalid ones
scripts/             test/validate/CI helpers
```

## Deviations from the architecture doc

- `DailySummaryV1` adds a required `provenance` field (`device` | `synthetic_fixture`) so test data can never pass as real.
- The fixture's `sleep.total_min` is 352 instead of the doc example's 382, so the short-sleep rule fires. `rule_hits` is computed by the pipeline, not stored in the fixture.
- Null and absent are treated as equivalent for optional fields; Swift omits nil on encode.
- The project uses XcodeGen (`project.yml`) instead of a committed `.xcworkspace`/`.pbxproj`, which keeps diffs reviewable and makes fresh clones reproducible in CI.
- `InsightEngine.extractLabRows` is deferred to M2.
- M0 consent storage is UserDefaults, which holds only the disclaimer acknowledgement and no health data. It moves to SwiftData in M1.
