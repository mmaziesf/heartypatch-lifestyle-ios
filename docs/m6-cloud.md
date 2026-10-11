# M6: opt-in anonymized cloud analysis

Status: **landed with an on-device demo analyzer.** The full egress path (consent → anonymize → audit → preview + SHA-256 → approve → re-check → transport → response checks → local results + log) is built and tested. The app ships **without a cloud endpoint**, so the transport is `DemoCloudTransport`, which runs a small rules analyzer on the iPhone. Nothing leaves the device in this version. `HTTPSCloudTransport` (TLS 1.3, public-key pinning, ephemeral session) exists for when a stateless endpoint is stood up.

Personal wellness only. Results are lifestyle observations and nudges that pass the same `OutputGuard` as on-device notes. There is no lab interpretation and no clinician prompts from the cloud.

## Flow (architecture §5.5, §7.4)

```
Settings › Cloud analysis (off) ──consent sheet (CloudConsent v "cloud-v1")──▶ on
Run an analysis: window 28 | 56 days, meals on/off, common labs on/off (off by default)
  └─ EgressGate.prepare
       consent active?                         no → consentMissing
       Anonymizer.payload (typed, allowlist)   <14 days with data / mixed provenance → refused
       PayloadAudit on the exact bytes         unknown key / free string / > 16 KB → refused
       → PreparedJob { body, sha256, preview }  (nothing sent)
  └─ preview: readable sections + exact JSON + SHA-256 → Send | Cancel
  └─ EgressGate.send(job, approvedSHA256: preview.sha256)
       consent still active? hash == approved == job? audit again?
       transport.post(body, requestID)          (body is byte-identical to the preview)
       response ≤ 64 KB, hpl.cloud_insights.v1, same request_id, ≤ 5 insights
       each insight: observation|nudge, length limits, OutputGuard against the sent payload (evidence must resolve)
       → Recommendations (engine .cloud, prompt cloud-v1); evidence day indices mapped back to local dates on device
       → EgressRecord appended to the local log (sent or failed), including the exact payload JSON
```

Revoking consent in Settings drops any prepared job; the next `prepare` and any stale `send` throw `consentMissing`.

## What is sent (`Spec/hpl.cloud_payload.v1.schema.json`)

Built field by field from typed values; nothing is copied through. `PayloadAudit` then re-checks the encoded bytes independently: every key must be on the allowlist and every string must come from a closed vocabulary or a fixed shape (half-hour time, 5-year age band, lowercase UUID request id).

| Field | Transformation |
|---|---|
| `request_id` | Fresh random UUID per job. No account, device or user id. |
| days | Relative indices, 0 = last day of the window (yesterday), down to -27. No calendar dates. `dow` kept. |
| weekly `metrics` | median / p10 / p90 per week (≥ 3 days), rounded (sleep and exercise 5 min, HR/HRV 1, steps 100, kcal 10) and clamped to population ranges. |
| daily rows | Last 28 days only: sleep, RHR, HRV, steps, exercise (same rounding/clamps); bed/wake rounded to 30 min. |
| meals | Time rounded to 30 min; label from {breakfast, lunch, dinner, snack, drink, meal}, anything else becomes `meal`; tags only from the `MealTag` vocabulary. **Food names and notes are never sent.** |
| workouts | Type mapped to {running, cycling, strength, walking, yoga, swimming, hiking, hiit, other}; duration rounded to 5 min. |
| labs (opt-in per job) | Only ldl, hdl, cholesterol_total, non_hdl, triglycerides, glucose, hba1c in their canonical unit, rounded (5 mg/dL, 10 for TG, 0.1 % for A1c), with age bucketed (0-30 / 31-90 / 91-180 / 180+ days). Rare analytes, reference ranges, report flags and lab names are dropped. |
| profile | 5-year age band and sex-for-ranges only if already in that shape; otherwise dropped. |

Never sent: name, calendar dates, locations, food names, notes, voice notes, report text, lab or clinic names, device ids, HealthKit sample ids.

The consent copy says plainly that coarsened data could still potentially be linked by a determined party with other data.

## What comes back (`Spec/hpl.cloud_insights.v1.schema.json`)

`{schema, request_id, insights[≤5]: {kind: observation|nudge, title ≤80, body ≤400, evidence[1-4]: payload paths}}`. Anything else is discarded and logged as failed. Insights that fail `OutputGuard` (blocklist, untraceable numbers, evidence paths that don't resolve in the sent payload) are hidden and counted.

## Code

- `Packages/HPLCloud`: `CloudPayloadV1`, `Anonymizer` + `AnonymizationPolicy`, `PayloadAudit`, `EgressGate`, `CloudPreview`, `CloudInsightsV1` + `CloudResponseProcessor`, `CloudTransport` (`DemoCloudTransport`, `DemoCloudAnalyzer`), `HTTPSCloudTransport` (Apple only), `EgressLog` (`RecordStoreEgressLog`, kind `egress`), `SyntheticWindow`.
- `Packages/HPLUI`: `CloudModel` (consent, policy, phases idle → preparing → preview → sending → done/failed, history), `CloudCopy`, `CloudViews` (Settings section, consent sheet, analysis/preview/results/history).
- `HPLCore.CloudConsent` (copy version `cloud-v1`). `HPLStore.SwiftDataStore.records` exposes the keyed record store for the egress log.
- Without Apple Health connected, the analysis uses a **labeled synthetic window** (`provenance: synthetic_fixture`, and the preview says "synthetic example, not yours"). With Health connected, it builds the user's own `DailySummaryV1` for each day ending yesterday, on device.

## Exit criteria (§11 M6)

| Criterion | Evidence |
|---|---|
| No identifier leakage across 1,000 randomized profiles | `PropertyTests.noCanaryLeaksAcrossOneThousandRandomWindows` plants canary strings in every string-bearing field and checks the bytes. `CloudModelTests.previewThenSendLogsExactBytes` does the same end-to-end through the UI model. |
| Preview == sent, byte for byte | `EgressGateTests.previewEqualsSentBytesAndResultsMapBack` (transport records the body; SHA-256 matches). |
| Revoking consent blocks the next job | `EgressGateTests.revokingConsentBlocksTheNextSend`, `CloudModelTests.revokingConsentBlocksTheNextJob`. |
| Unreachable without opt-in | `EgressGateTests.unreachableWithoutConsent`, `CloudModelTests.offByDefaultAndUnreachableWithoutOptIn`. |
| Endpoint logs contain no bodies | **Open**: no endpoint exists yet. The client sends no identity headers or cookies (`httpsTransportRequiresTLSAndPinsAndSendsNoIdentity`). |
| Networking only in one file | `scripts/check_egress_boundary.sh` (CI spec job). |
| Schemas | `scripts/validate_specs.py` validates `Fixtures/cloud/*.synthetic.json` (golden, regenerated with `HPL_WRITE_GOLDEN=1 swift test` in `Packages/HPLCloud`) and rejects `Fixtures/invalid/cloud-*.json`. |

## Deviations

- **Payload cap is 16 KB, not 8 KB.** 28 daily rows with meals don't fit in 8 KB. Responses are capped at 64 KB.
- **No endpoint, no proxy, no App Attest.** The demo analyzer stands in; `EgressRecord.leftDevice` is `false` for every job in this version.
- Public-key pinning in `HTTPSCloudTransport` is unit-tested for configuration only, not against a live server.
- Cloud results are shown in the analysis screen and kept in the egress history; they are not yet merged into the Insights ledger (feedback, experiments).
- Rare labs are always dropped; there is no "include rare labs" toggle.
- Daily rows always cover the last 28 days, even for a 56-day window (weekly aggregates cover all 8 weeks).
