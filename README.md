# HeartyPatch Lifestyle (M7)

Local-first iOS app: Apple Watch / HealthKit + your confirmed blood work (+ Ray-Ban meal logs later) → an on-device daily summary → coaching-style lifestyle notes and self-experiments.

> **Not medical advice.** HeartyPatch Lifestyle provides general wellness information and self-experiment ideas based on data you choose to share with it. It is not a medical device and does not diagnose, treat, cure, or prevent any disease or provide medical advice. Lab values are shown as printed on your report; we do not interpret them. Talk to a qualified clinician about any health concern or before changing medications, diet, or exercise in significant ways. If you think you may have a medical emergency, call your local emergency number.

- Architecture: [`docs/architecture.md`](docs/architecture.md) (one-page: [`docs/architecture-SUMMARY.md`](docs/architecture-SUMMARY.md))
- Milestone: **M0 done; M1 (HealthKit daily aggregates) code landed, awaiting on-device validation. M2 (lab import) scaffold landed; accuracy gate needs real redacted reports. M3 (on-device notes: Apple Foundation Models + rules fallback, output guard, eval harness) scaffold landed; FM eval needs an Apple Intelligence device. M4 (note actions, "Why am I seeing this?", persistent history + JSON export, 7/14-day N-of-1 experiments) landed. M5 (glasses bridge: HMAC-signed `.hplevent` inbox, QR pairing, Meals tab with confirm/edit/manual add, no photos, confirmed meals in the daily summary) landed; aligned with the user's [rayban-vlm-poc](https://github.com/mmaziesf/rayban-vlm-poc) "Glance" producer, whose export side is still to build. M6 (opt-in anonymized cloud analysis: EgressGate, allowlist anonymizer + independent payload audit, preview-before-send with SHA-256, consent in Settings, local egress log) landed with an on-device demo analyzer; no endpoint is configured, so nothing leaves the device yet. M7 (polish + TestFlight prep: verified Delete all, Export all, privacy copy and consents, app-switcher shield, optional daily reminder, App Store copy + CI claims check, privacy manifest, signing/TestFlight checklist) landed; external TestFlight needs an Apple Developer account and device passes.** See [`docs/m1-healthkit.md`](docs/m1-healthkit.md), [`docs/m2-labs.md`](docs/m2-labs.md), [`docs/m3-llm.md`](docs/m3-llm.md), [`docs/m4-insights.md`](docs/m4-insights.md), [`docs/m5-glasses.md`](docs/m5-glasses.md), [`docs/m6-cloud.md`](docs/m6-cloud.md) and [`docs/m7-release.md`](docs/m7-release.md) (+ [`docs/testflight-checklist.md`](docs/testflight-checklist.md), [`docs/privacy-policy.md`](docs/privacy-policy.md), [`docs/copy-review.md`](docs/copy-review.md)).

## What M0 does

| Exit criterion (§11, §14) | Where |
|---|---|
| 9 local Swift packages (§9.1) | `Packages/HPL*` |
| CI: schemas, lint, Linux + macOS `swift test`, iOS simulator build + tests | `.github/workflows/ci.yml` |
| `hpl.daily_summary.v1` + `hpl.event.v1` JSON Schemas, round-trip tests | `Spec/`, `Fixtures/`, `Packages/HPLCore/Tests` |
| Tab shell (Today / Labs / Meals / Insights / Settings) + disclaimer acknowledged once, shown in Settings | `Packages/HPLUI`, `App/` |
| Rules-only engine: fixture → rules → engine → output guard → Today | `HPLPipeline`, `HPLInference` |
| No PHI in logs (CI grep) + SwiftLint `no_print` | `scripts/check_no_phi_logging.sh`, `.swiftlint.yml` |

**Data honesty:** Without Apple Health connected (or on a device without HealthKit), Today runs on `Fixtures/daily_summary/d0.synthetic.json` (`"provenance": "synthetic_fixture"`), and the screen shows an **EXAMPLE DATA: not yours** banner. Every valid fixture filename must contain `.synthetic.` (CI enforces this).

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
scripts/check_egress_boundary.sh       # networking only in HPLCloud/HTTPSCloudTransport.swift
python3 scripts/check_store_copy.py    # App Store text: wellness framing, disclaimer, limits; privacy manifest
python3 scripts/hpl_event_sign.py verify Fixtures/signed/*.hplevent   # reference producer: sign / verify / Glance entry -> event
swiftlint lint --strict
```

The SwiftUI views (`HPLUI/Views.swift`) compile only on Apple platforms. Everything else, including `AppModel`, the disclaimer gate, and the end-to-end rules path, is tested on Linux too.

## Layout

```
App/                 @main SwiftUI entry, PrivacyInfo.xcprivacy, app icon (target defined in project.yml)
Metadata/app-store/  App Store / TestFlight text (fastlane deliver layout), checked in CI
Packages/
  HPLCore            DailySummaryV1, HPLEventV1, MealLog + MealRepository, SHA-256/HMAC, JSONValue, Recommendation, Consent, Disclaimer, labeled fixtures
  HPLStore           SwiftData store (aggregates, sync anchors, consents, labs, notes + experiments, meals + event receipts; FileProtection complete) + in-memory impls
  HPLHealth          HealthKit read: auth, statistics/anchored/observer queries, sleep + HRV aggregators, HealthSyncEngine
  HPLIngest          Lab import: PDFKit/Vision extraction, rules parser, analyte dictionary, review session, SHA-256 dedupe (M2)
  HPLInference       InsightEngine, FoundationModelsEngine, RulesOnlyEngine, prompt contract + sanitizer, NotesOutputV1, OutputGuard
  HPLPipeline        SummaryBuilder (aggregates + labs + confirmed meals -> DailySummary v1, 28d baselines), MealSummary, RulesEngine (13 rules), DailyPipeline (fallback/rewrite/report/context), EvalHarness + 50 EvalFixtures, NoteLedger, ExperimentTracker
  HPLBridge          Glasses bridge: signed .hplevent EventInbox (HMAC, age/skew, persistent dedupe, pause), pairing + Keychain, MealAssembler
  HPLCloud           Opt-in cloud analysis: Anonymizer -> CloudPayloadV1, PayloadAudit, EgressGate (consent/preview/hash), demo + HTTPS transports, egress log
  HPLUI              AppModel, LabsModel, InsightsModel, MealsModel, CloudModel, ReminderModel, export/delete-all + SwiftUI (Today, Labs, Meals, Insights, Settings › Glasses meals / Cloud analysis)
Spec/                hpl.daily_summary.v1, hpl.event.v1, hpl.signed_event.v1, hpl.cloud_payload.v1, hpl.cloud_insights.v1 (JSON Schema 2020-12)
Fixtures/            synthetic valid fixtures + deliberately invalid ones
scripts/             test/validate/CI helpers
```

## Deviations from the architecture doc

- `DailySummaryV1` adds a required `provenance` field (`device` | `synthetic_fixture`) so test data can never pass as real.
- The fixture's `sleep.total_min` is 352 instead of the doc example's 382, so the short-sleep rule fires. `rule_hits` is computed by the pipeline, not stored in the fixture.
- Null and absent are treated as equivalent for optional fields; Swift omits nil on encode.
- The project uses XcodeGen (`project.yml`) instead of a committed `.xcworkspace`/`.pbxproj`, which keeps diffs reviewable and makes fresh clones reproducible in CI.
- `InsightEngine.extractLabRows` (LLM assist) is not used; M2 is rules-only. See [`docs/m2-labs.md`](docs/m2-labs.md).
- M0 consent storage was UserDefaults (disclaimer acknowledgement only). Since M1, consents live in the SwiftData store; the app migrates the old key once on launch.
- M1 deviations and on-device checks: [`docs/m1-healthkit.md`](docs/m1-healthkit.md).
- M5: signatures travel in an `hpl.signed_event.v1` wrapper per line of an `.hplevent` file, not HTTP headers. File inbox signatures may be up to 7 days old (5 min future skew); replay is stopped by persistent `event_id` receipts. New `meal.logged` event type (single-shot producers such as Glance), optional item `confidence`, optional `producer.processing`. No photos are imported at all. Details: [`docs/m5-glasses.md`](docs/m5-glasses.md).
- M6: the cloud payload cap is 16 KB (not 8 KB) so 28 daily rows with meals fit. The app ships an on-device demo analyzer instead of an endpoint; no proxy or App Attest yet. Details: [`docs/m6-cloud.md`](docs/m6-cloud.md).
- M7: the daily notification is a fixed-time, content-free reminder rather than "post when the pipeline finds something"; no backup-exclusion toggle yet (default: included, disclosed). Details: [`docs/m7-release.md`](docs/m7-release.md).
