# M5: Glasses bridge (Ray-Ban → HP Lifestyle)

Status: **landed (scaffold + full inbox path).** HP Lifestyle imports signed meal and lifestyle events from a paired glasses companion app. Meals arrive pending, you confirm them, and only confirmed meals reach the daily summary. No photos are ever imported. On-device checks with a real producer are still open (see the end).

Architecture refs: §5.3 (meal sequence), §8.2 (event API), §8.3 (transports), §8.4 (privacy), §11 (M5 row).

## 1. The producer: rayban-vlm-poc ("Glance"), not a guess

The reference producer is the user's own repo, [`mmaziesf/rayban-vlm-poc`](https://github.com/mmaziesf/rayban-vlm-poc) (read at `790afad`, 2026-10-11 02:02 PT). The facts that shaped the bridge:

| Glance fact | Where in Glance | Consequence for HPL |
|---|---|---|
| Phone companion app on Meta DAT 1.0.1. **Android is primary**; iOS (`ios/GlanceApp`) is an optional port (Glance M7) | README, `docs/MILESTONE_PLAN.md` | The producer may be on a **different OS** from HPL (iOS), so any same-device-only transport can't be the only one |
| VLM is **Gemma 4 on device** (LiteRT-LM). The Android release build has **no INTERNET permission** | README, `docs/M1C_REAL_VLM.md` | No HTTP/relay transport: it would break Glance's offline guarantee. Files it is |
| "Log this meal" is **single-shot**: one frame → `{"is_food":true,"name","kcal","protein_g"}` → one `MealEntry` | `GlanceCore/Meal.swift` (`Prompts.meal`, `MealParser`), `Ports.swift` (`MealEntry`) | New self-contained **`meal.logged`** event; no start/items/end session needed |
| `MealEntry { tsMs, name, kcal?, proteinG?, frameTimeMs, rawJson }`; bridge contract `entry { ts ISO-8601, frameId, name, kcal, protein_g }` | `Ports.swift`, `phone/bridge-contract.json` | Mapping below. No confidence → item `confidence` became optional |
| Meal log is an in-memory placeholder; Glance M4 plans Room `meals(id, ts, name, kcal, protein_g, frame_path, raw_json, model_ver)` | `MemoryMealLog.kt`, `MILESTONE_PLAN.md` M4 | The export hook belongs in Glance M4 (§6) |
| No pairing, export, or HPL code exists yet | whole repo | Producer-side work is listed in §6, not done (separate repo, needs the user's go-ahead) |

VisionClaw (Intent-Lab), the doc's original assumption, is different: an iOS app plus a **cloud** agent (Gemini Live / OpenAI realtime on Fly.io). Its multi-event session shape (`meal.start` / `meal.items` / `meal.end`) stays supported, so either producer works.

### Glance `MealEntry` → `hpl.event.v1` `meal.logged`

| Glance | hpl.event.v1 | Note |
|---|---|---|
| `ts` / `tsMs` | `occurred_at` (UTC, seconds) | |
| device zone | `tz` (IANA) | Glance doesn't store it; take it at export time |
| `name` | `payload.items[0].name` (≤80 chars) | |
| `kcal` | `payload.items[0].kcal_est` | shown as "about N kcal (estimate)" |
| `protein_g` | `payload.items[0].protein_g` | |
| (none) | `items[0].confidence` omitted | now optional |
| `frameId`, `frameTimeMs`, `rawJson`, frame/photo | **not sent** | frames and raw VLM output stay in Glance |
| model | `producer: {"name":"glance","version":…,"processing":"on_device"}` | `processing` is new, optional; the UI shows "analyzed on your phone" vs "in the cloud" |
| (none) | `event_id` = ULID(time = `tsMs`, entropy = first 80 bits of SHA-256(`"glance|{tsMs}|{frameId}|{name}"`)) | deterministic, so re-exporting the same entry dedupes in HPL. Or store a ULID in Glance's Room row |

Reference implementation: `scripts/hpl_event_sign.py glance ENTRY.json` (fixture: `Fixtures/glance/meal-entry.synthetic.json` → `Fixtures/events/07-glance-meal-logged.synthetic.json`).

## 2. Wire format: `.hplevent` files of signed events

An `.hplevent` file is UTF-8 JSON Lines. Each line is an `hpl.signed_event.v1` wrapper (`Spec/hpl.signed_event.v1.schema.json`):

```json
{"spec":"hpl.signed_event.v1","pairing_id":"<16 [0-9a-z]>","ts":1791756900,"sig":"<64 hex>","body":"<exact hpl.event.v1 JSON string>"}
```

`sig = hex(HMAC-SHA256(secret, "hpl.signed_event.v1\n" + pairing_id + "\n" + ts + "\n" + body))`

- The body is the producer's exact string, so there is no JSON canonicalization problem across Kotlin, Swift and Python.
- This replaces the §8.2 `X-HPL-Signature` / `X-HPL-Timestamp` headers, which only made sense for HTTP. If an HTTP transport is ever added, it can carry the same wrapper.

**HPL verification order (HPLBridge `EventInbox`):**
1. Not paused.
2. File ≤ 1 MB and ≤ 1,000 lines; body ≤ 16 KB.
3. Wrapper parses.
4. `pairing_id` is a current pairing with a secret in the Keychain.
5. Constant-time HMAC match.
6. Signature age ≤ 7 days and ≤ 5 min in the future, and `occurred_at` ≤ now + 5 min.
7. Only then is the body decoded and its schema checked.
8. Persistent dedupe on `event_id` (receipts in the store, survive relaunch).
9. Apply.

Verified lines are applied in `occurred_at` order, so out-of-order session events still assemble.

**Skew policy.** §8.2 says ±5 minutes. That is right for a live channel, but a file can sit in a share sheet or a synced folder. Replay protection comes from persistent `event_id` receipts, not from the timestamp window. So: **7-day maximum age + 5-minute future skew**.

## 3. Pairing

- Settings › Glasses meals › Pair a companion creates a 16-char id and a 32-byte secret from the system CSPRNG.
- It shows them once as a QR code and a share link: `hplpair://v1?id=<id>&k=<base64url secret>`.
- The secret is stored only in the Keychain (`KeychainPairingSecretStore`: this-device-only, after-first-unlock, not synced). Pairing metadata (label, date) goes in the store.
- **Pairing code:** the first 8 lowercase hex characters of SHA-256(secret), shown as `ae21 6c2e`. It appears in the pairing sheet and on each pairing row in Settings, and matches Glance's `HplPairing.fingerprint()` and `hpl_event_sign.py pair` → `secret_sha256[:8]`. Matching codes mean both sides hold the same key. The fixture pairing's code is `ae216c2e`. The code is stored with the pairing metadata; it isn't secret (32 bits of a hash). Older pairings recompute it from the Keychain.
- "Remove" (swipe) deletes both. Later files from that companion are rejected as "not from a paired companion".
- Producer side: scan the QR, or paste the link; store the id and secret in Android Keystore / iOS Keychain.

## 4. Transport decision

| Option (§8.3) | Verdict |
|---|---|
| **A. File / share sheet** | **Built.** Glance writes `.hplevent` and shares it. HPL gets it via "Open in HP Lifestyle" (`onOpenURL`, exported UTI `com.hpl.lifestyle.hplevent`) or Meals › Import (Files). Works Android→iPhone (AirDrop isn't available, but Drive/Files/Signal/email/a USB copy are) and iPhone→iPhone. No network on either side. |
| B. Local HTTP | Rejected: needs INTERNET in Glance's release build and a listener in HPL. |
| C. Same-device App Group / App Intent | Later, only if Glance's iOS port ships under the **same Apple team** as HPL. Could then drop files into a shared inbox folder automatically. |
| D. Relay | Rejected: cloud, against both apps' local-first goals. |

## 5. What HPL does with events

| Event | Result |
|---|---|
| `meal.logged` (Glance) | One **pending** glasses meal (items, tags, producer, processing) |
| `meal.start` / `meal.items` / `meal.end` (VisionClaw style) | One pending meal per `session_id`, assembled in any order. Items are capped at 50. Sessions without `meal.end` auto-close 90 min after start. New items on a confirmed meal send it back to pending |
| `meal.photo` | **Dropped.** Counted on the meal ("photo skipped") and reported in the import summary; bytes are never fetched or stored |
| `lifestyle.event` | Stored (`LifestyleLog`) |
| `voice.note` | Stored on device (`VoiceNoteLog`). **Never** in the summary, never sent to the LLM, never interpreted (including `intent: symptom`) |
| `ping` / unknown type | Receipt only (ignored) |

**Meals tab:**
- A "To confirm" list with Confirm / Edit (name + kcal) / Not a meal.
- A timeline of confirmed meals by day, with swipe-to-delete.
- Manual add (confirmed immediately; tags from the controlled list).
- Import, and a last-event / paused indicator.

**Daily summary** (`MealSummary`, `SummaryBuilder(meals:)`) includes **confirmed meals only**, as `{t_local, label, tags}`:
- `label` comes from local time: breakfast 05:00–10:59, lunch 11:00–15:59, dinner 17:00–21:59, otherwise snack.
- `late` is added at ≥21:00 or <04:00.
- `alcohol` / `caffeine` are added from a lifestyle event within ±90 min.
- Other tags are the producer's or user's, filtered to the shared `mealTag` vocabulary.

Item names, kcal, producer and free text never reach the summary, so they never reach the LLM or cloud. The existing `LATE_MEAL_ALCOHOL` rule can now fire on real data. Confirming, editing or rejecting a meal rebuilds Today.

**Privacy (§8.4):**
- Consent: `glasses-v1` copy in Settings. It covers where each companion runs its model.
- Pause toggle, last-event indicator, photos off.
- Nothing about events is logged; the PHI check still passes.

## 6. Proposed producer-side changes in rayban-vlm-poc (not made)

Glance is a separate repo, so I didn't touch it. A minimal path, ideally folded into Glance M4 (Room):

1. **Pairing screen:** scan `hplpair://v1?...` (or paste it); keep `id` + `secret` in Android Keystore-wrapped prefs (iOS: Keychain).
2. **Export:** a "Send meals to HP Lifestyle" action. For each unsent Room row, build `meal.logged` (mapping above), sign it, and write `glance-<date>.hplevent`. Hand it to the share sheet (`ACTION_SEND`, `application/x-hplevent`). Mark rows exported. Re-sending is harmless thanks to deterministic event ids.
3. **Contract test:** run `scripts/hpl_event_sign.py verify` (or port its five functions) against Glance's output in CI.

Kotlin signing sketch (untested, standard JDK only):

```kotlin
fun sign(pairingId: String, secret: ByteArray, ts: Long, body: String): String {
    val mac = javax.crypto.Mac.getInstance("HmacSHA256").apply { init(javax.crypto.spec.SecretKeySpec(secret, "HmacSHA256")) }
    val sig = mac.doFinal("hpl.signed_event.v1\n$pairingId\n$ts\n$body".toByteArray()).joinToString("") { "%02x".format(it) }
    return org.json.JSONObject(mapOf("spec" to "hpl.signed_event.v1", "pairing_id" to pairingId, "ts" to ts, "sig" to sig, "body" to body)).toString()
}
```

## 7. Tests

| Where | What |
|---|---|
| `HPLCore` `CryptoAndMealTests` | SHA-256 vectors, HMAC RFC 4231 cases 1/2/6, constant-time compare, base64url, tag vocabulary, `meal.logged` decode |
| `HPLBridge` `EventInboxTests` | Glance file → pending meal; re-import = duplicate; VisionClaw session + lifestyle + voice + unknown; tampered / unknown pairing / unsigned rejected; stale & future; paused; revoked; size limits |
| `HPLBridge` `MealAssemblerTests`, `SigningTests` | out-of-order sessions; photo dropped; missing session id; 90-min auto-close; re-confirm after new items; **Swift signatures == Python reference** on the signed fixtures; pairing URI parse |
| `HPLStore` `MealStoreTests` | repository contract (in-memory + SwiftData) and receipts/meals surviving a store reopen (macOS CI) |
| `HPLPipeline` `MealSummaryTests` | labels, confirmed-only, derived `late`/`alcohol`, no free text in summary JSON, `LATE_MEAL_ALCOHOL` fires |
| `HPLUI` `MealsModelTests` | consent gate, import notices, edit/confirm/reject/manual, pause, pair/revoke, **end-to-end: signed Glance file → pending → confirm → `DailySummary.meals[]`**, copy blocklist |
| CI spec job (`validate_specs.py`) | wrapper schema, Python HMAC verification of `Fixtures/signed/*.hplevent`, bodies against the event schema, `Fixtures/invalid/signed-*` must fail |

The fixture pairing (`fixturepair00001`, secret bytes 1…32) is **test-only** and public.

## 8. M5 exit criteria

| Criterion | Status |
|---|---|
| Meal from the producer appears as a pending MealLog | ✅ in tests with Glance-shaped and VisionClaw-shaped files. ⏳ real Glance export (§6 not built) |
| Duplicates ignored | ✅ persistent receipts |
| Invalid signature rejected | ✅ |
| Photos with faces dropped | ✅ stricter: **all** photos dropped. The face filter is not built because no photo path exists |
| Confirmed meals in `DailySummary.meals[]` | ✅ end-to-end test |

## 9. Not built / needs a device

- Producer side in Glance (§6). App Group / App Intent transport (C).
- Photo import with protected storage, 7-day TTL and Vision face filter (§8.4 opt-in). Out until there's a real need.
- Keychain store and QR rendering are Apple-only. CI compiles them, but they're unexercised; check on a device.
- Share-sheet → `onOpenURL` import must be checked on a device (exported UTI + document type in `project.yml`).
- Voice notes and lifestyle events have no list UI yet; they're stored and counted only.
