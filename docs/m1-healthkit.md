# M1: HealthKit daily aggregates

Status: **code complete and green in CI (Linux + macOS + iOS simulator). The exit criteria still need a real iPhone + Apple Watch with ≥ 30 days of data.** The simulator has no Watch data, so CI can't prove the "matches Health app" criterion.

## What landed

| Piece | Where |
|---|---|
| `LocalDay` (user-local day, DST-safe), `HealthMetric` (§4.3 minus clinical), `HealthAggregate`, repository protocols | `HPLCore` |
| `HealthDataSource` protocol + `HealthKitDataSource` (read-only auth per family, `HKStatisticsCollectionQuery` for per-day stats, anchored queries, observer + background delivery) | `HPLHealth` |
| `SleepAggregator`: night assigned to the day it ends; one source per night (Watch first) instead of summing overlapping sources; stage totals via interval union | `HPLHealth` |
| `HRVAggregator`: overnight SDNN median inside the recorded sleep window; labeled fallback window (22:00–10:00) when no sleep was recorded | `HPLHealth` |
| `HealthSyncEngine`: 90-day backfill in 14-day chunks (newest first), incremental sync = trailing 3 days + days touched by anchored feeds; deletions recompute 30 days; anchors advance only after a successful write | `HPLHealth` |
| SwiftData store (aggregates, sync anchors, consents) in `Application Support/HPL/` with `NSFileProtectionComplete`; consent migration from M0 UserDefaults | `HPLStore` |
| `SummaryBuilder`: aggregates → `hpl.daily_summary.v1` with `provenance: "device"`, 28-day baselines (need ≥ 7 days), completeness over 6 signals | `HPLPipeline` |
| Onboarding Apple Health step, Today "vs your 28-day typical" rows, "No data (or access not granted)" empty state, sync status, pull to refresh, foreground refresh, Settings status | `HPLUI`, `App/` |
| Entitlements (HealthKit, background delivery, default data protection) + `NSHealthShareUsageDescription` | `project.yml` |

Only per-day aggregates are stored. Raw HealthKit samples are read into memory for one aggregation pass and dropped. No health values are logged (CI grep and the SwiftLint `no_print` rule both pass).

## Exit criteria (§11) and status

| Criterion | Status |
|---|---|
| Steps within 1% of the Health app for 7 spot-checked days | **Needs device.** Steps use `HKStatisticsCollectionQuery` cumulative sum, the same de-duplication Health uses, so a match is expected. |
| Sleep total within 5 min of Health for 7 days | **Needs device.** Risk: the night boundary (`SleepAggregator.dayBoundaryHour = 18`) and source selection are best guesses at Health's rules. Tune here if spot checks disagree. |
| Incremental sync after a new workout without relaunch (or on next foreground) | Observer + background delivery registered at launch; foreground refresh always runs. **Needs device.** |
| Denied permissions show correct empty states | "No data (or access not granted)" + Open Health button; unit-tested at the model level. **Needs a device check.** |
| No PHI in logs (CI grep) | ✅ CI |
| 90-day anchored backfill, HealthAggregate per day, Today vs 28d baseline | ✅ Code + tests (fake HealthKit source) |

## Device validation checklist (Arash)

1. Clone the repo, run `brew install xcodegen && xcodegen generate`, set your Team under Signing & Capabilities, and run on your iPhone. HealthKit needs a real device to have Watch data.
2. Acknowledge the disclaimer → Connect Apple Health → allow all → wait for the 90-day progress bar.
3. For 7 different days, compare against the Health app: Steps (Health › Steps › D), Sleep "Time Asleep" for that night, and Resting HR. Note any mismatch along with the day and both values.
4. Record a short workout on the Watch, then lock the phone for ~15 minutes, then open the app. Today should update.
5. Settings › Health › Data Access & Devices › HP Lifestyle → turn everything off → pull to refresh on Today. Data already synced stays visible (it's stored), and days with no new data show the empty state.

## Known gaps / follow-ups

- Auth asks for all 5 families at once from one explicit screen. Per-family progressive prompts can come later.
- Background delivery hands the observer completion back immediately and syncs asynchronously (idempotent; the foreground refresh is the backstop).
- Time-zone travel: each aggregate records the `tz` it was computed in, but older days are not yet recomputed after a zone change.
- Workout `zone_minutes` aren't computed yet (needs per-workout HR samples); `avg_hr` is.
- "Delete all" + backup-exclusion toggle are M7.
