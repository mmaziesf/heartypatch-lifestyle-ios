# M7: polish and TestFlight prep

Status: **code and docs landed. External TestFlight needs an Apple Developer account plus device passes** (see the end of this doc).

## What landed

| Area | What | Where |
|---|---|---|
| Delete all (§10) | Wipes the database (every model: aggregates, **HealthKit anchors**, consents, labs, notes, experiments, meals, receipts, pairings, egress log), lab report files, Keychain pairing secrets (all under the service, including orphans), `hpl.*` preferences and legacy consents, scheduled and delivered reminders, the "Open in" inbox and the temp dir. Each target is re-read afterwards and the result shown ("checked: nothing is left", or which part failed). The app then rebuilds on the empty store and starts at onboarding again. HealthKit data and the iOS permission are untouched; the copy says where to revoke access. | `HPLCore/DataWipe.swift`, `SwiftDataStore.eraseAll/recordCount`, `PairingSecretStore.removeAll/count`, `LabFileStore.removeAll/count`, `AppModel.deleteAll`, `App/…App.swift` |
| Export all (§9.2) | `hpl.export_all.v1` JSON: consents, aggregates, lab documents, panels and results, meals, notes, experiments, cloud egress. Excludes report files and secrets. | `HPLUI/DataExport.swift`, Settings |
| Privacy copy | Settings › Privacy & your data (7 true statements, export, delete), Settings › Consents (scope, version, dates), About (version, wellness line) | `PrivacyCopy.swift`, `SettingsSections.swift`, `docs/privacy-policy.md` |
| App-switcher shield (§10) | A cover view whenever the scene isn't active, so snapshots don't show health numbers | `PrivacyShieldView` |
| Daily reminder (M4 notification) | Off by default. One repeating local notification at a time you choose, with content-free text. Permission is asked when you turn it on, and "denied" shows guidance. | `Reminders.swift`, Settings › Notifications |
| App Store framing | `Metadata/app-store/en-US/*` (fastlane-deliver layout), CI check `scripts/check_store_copy.py`, written review `docs/copy-review.md` | |
| TestFlight prep | `App/PrivacyInfo.xcprivacy` (no tracking, no collected data, UserDefaults CA92.1; CI asserts it is bundled), placeholder 1024 app icon, `MARKETING_VERSION 0.7.0`, CI **Release device build** (unsigned), `scripts/ExportOptions-appstore.plist`, `docs/testflight-checklist.md` | |
| Accessibility | Today metric rows and consent rows read as one VoiceOver element | |

## Tests

- `HPLCoreTests.DataWipeTests`: the directory target empties folders but keeps the directory; a failing target doesn't stop the others and is reported; unverifiable counts as not clean.
- `HPLStoreTests.WipeTests` (Apple platforms): after `eraseAll` every model type has 0 rows, HealthKit anchors are gone, and the store is still empty after reopening.
- `HPLUITests.YourDataTests`: delete-all clears the DB, files, secrets, preferences and reminders and verifies; delete-all is unavailable without a wiper or in a degraded (locked) launch; the export contains everything but no secrets; the reminder is opt-in, persisted and content-free, and permission denial is handled; the copy passes the blocklist and overclaim checks.

## M7 exit criteria (§11)

| Criterion | Status |
|---|---|
| Delete-all verified to leave no files or Keychain items | **Code + tests done**; each run verifies itself. Needs one device pass (Keychain is not exercised in CI). |
| Written review of all user-facing copy against §13 | Done: `docs/copy-review.md`, with CI checks for the app and the store text. |
| App Privacy details filled accurately | Answers prepared ("Data Not Collected"); entering them needs App Store Connect. |
| App Store copy reviewed for claims | Done (`Metadata/app-store`, CI check). |
| Accessibility (Dynamic Type, VoiceOver on charts) | Partial. There are no charts yet (the labs trend chart isn't built). Rows are combined for VoiceOver. Dynamic Type and VoiceOver need a device pass. |
| Empty and error states | Present for Today, Labs, Meals, Insights and Cloud. Review on device. |
| Cold start < 1.5 s | **Unmeasured**: needs a device (Instruments › App Launch). |
| TestFlight external build approved; 10 testers × 2 weeks, no P0 | Needs an Apple Developer account. Follow `docs/testflight-checklist.md`. |

## Needs Apple Developer account

1. Program enrollment, App ID `com.hpl.lifestyle` with HealthKit (+ background delivery) and Data Protection, and a team in `project.yml` or Xcode.
2. App Store Connect app record: name (after a trademark check), category Health & Fitness, age rating, privacy policy URL (publish `docs/privacy-policy.md`), App Privacy "Data Not Collected".
3. Signed archive and upload (Xcode or `xcodebuild archive` + `-exportArchive` with `scripts/ExportOptions-appstore.plist` and your team ID), export compliance (already `NO` in Info.plist).
4. TestFlight internal group, then an external group with Beta App Review (notes in `Metadata/app-store/en-US/review_notes.txt`).
5. Lawyer review before external testing (§13).

## Needs a physical device

- HealthKit permission sheet, 90-day backfill, background delivery and observer wakes (M1 checks in `docs/m1-healthkit.md`).
- Delete all: Keychain items are actually removed; the protected-store reopen and HealthKit re-backfill work after the wipe; the Health-access path in the copy is correct on iOS 26.
- Reminder permission prompt, delivery at the chosen time, lock-screen content.
- App-switcher shield appearance.
- Foundation Models notes (needs an Apple Intelligence device; M3 eval).
- Lab import with real redacted reports (M2 accuracy gate).
- Cold-start time, Dynamic Type at the largest sizes, a VoiceOver pass.
- Glasses `.hplevent` "Open in" from Files or a companion (M5).

## Deviations and decisions

- The reminder is a repeating daily reminder at a fixed time, not "post after the pipeline finds something" (§5.4 step 6). There is no background pipeline yet, and a fixed, content-free reminder is more honest. At most one per day either way.
- The backup-exclusion toggle (§12, open) isn't built. The default stays included, and the privacy copy discloses it.
- There is no model cache to wipe (no downloaded models yet). The Delete-all target list in `AppBootstrap` is where it goes when MLX lands.
- App lock (Face ID gate) is not built (optional in §10); the app-switcher shield is.
